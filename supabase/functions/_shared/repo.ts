/// Every SQL statement in the backend lives here, and nowhere else.
///
/// Two reasons for the concentration. The obvious one is auditability: the RLS
/// posture in 0001 is deny-all, so the service role is the only writer and this
/// file is the complete list of writes — reading it end to end is reading the
/// whole mutation surface of the product. The less obvious one is that it keeps
/// the routes thin enough to review on a phone in a venue.
///
/// Deno-only: it needs the service-role client from `./db.ts`.

import { buildCatalogue, type MovementDbRow, num, type OffsetDbRow } from "./catalogue.ts";
import type { Db } from "./db.ts";
import type { Board } from "./demo.ts";
import type { Catalogue } from "./evidence/thresholds.ts";
import type { Evidence } from "./evidence/schema.ts";
import { ErrorCode, HttpError } from "./responses.ts";
import { MAX_SESSIONS_PER_DAY } from "./scoring/caps.ts";
import type { Contribution, MaterialisedOwner } from "./territory.ts";
import type { FlagPayload, SetPayload } from "./outcome.ts";
import { SESSION_EXPIRY_MS, type SessionRow } from "./validation/session.ts";

/** Turns a PostgREST failure into a 500 with the real reason in the log. */
function failDb(what: string, error: { message: string } | null): never {
  console.error(`${what} failed`, error?.message ?? "unknown");
  // The SQL error is never echoed to the client: it names tables and columns.
  throw new HttpError(ErrorCode.INTERNAL, 500, `${what} failed.`);
}

// ---------------------------------------------------------------------------
// Catalogue
// ---------------------------------------------------------------------------

/** The one version with `active = true`. The unique partial index in 0001 guarantees at most one. */
export async function activeConfigVersion(client: Db): Promise<string> {
  const { data, error } = await client
    .from("movement_config_versions")
    .select("version")
    .eq("active", true)
    .maybeSingle();
  if (error) failDb("reading the active config version", error);
  if (data === null) {
    // Not a client error and not recoverable at runtime: 0003 seeds one. Reaching
    // this means a migration was rolled back by hand.
    throw new HttpError(
      ErrorCode.SCORING_FAILED,
      500,
      "No active movement_config_version. Run migration 0003.",
    );
  }
  return data.version as string;
}

/**
 * The whole movement catalogue. Version-independent: `movements` holds identity,
 * tier and difficulty, while thresholds live in `movement_config_offsets` keyed by
 * version. GET /movements needs only this.
 */
export async function loadMovements(client: Db): Promise<MovementDbRow[]> {
  const { data, error } = await client
    .from("movements")
    .select("id, family, tier, measurement_type, difficulty, hold_band_low, hold_band_high")
    .order("family")
    .order("tier")
    .order("id");
  if (error) failDb("reading movements", error);
  return (data ?? []) as MovementDbRow[];
}

/**
 * Loads the catalogue bound to one version.
 *
 * Two queries rather than a join because PostgREST embedding would return the
 * offsets nested under each movement, and flattening that is more code than a
 * second round trip costs. The catalogue is small (18 movements) and Edge
 * Function isolates are warm, so this is not on a hot path worth caching —
 * revisit only if session-submit latency shows it.
 */
export async function loadCatalogue(client: Db, version: string): Promise<Catalogue> {
  const movements = await loadMovements(client);

  const offsets = await client
    .from("movement_config_offsets")
    .select(
      "movement_id, enter_peak_offset, enter_rest_offset, rom_target_offset, unit, direction",
    )
    .eq("version", version);
  if (offsets.error) failDb(`reading offsets for version ${version}`, offsets.error);

  return buildCatalogue(version, movements, (offsets.data ?? []) as OffsetDbRow[]);
}

// ---------------------------------------------------------------------------
// Per-user state
// ---------------------------------------------------------------------------

/** Movement ids this account has unlocked. Drives the I10 tier gate. */
export async function loadUnlocked(client: Db, userId: string): Promise<ReadonlySet<string>> {
  const { data, error } = await client
    .from("unlocked_movements")
    .select("movement_id")
    .eq("user_id", userId);
  if (error) failDb("reading unlocked movements", error);
  return new Set(((data ?? []) as { movement_id: string }[]).map((row) => row.movement_id));
}

export interface DailyCounter {
  sessionsStarted: number;
  repScoreEarned: number;
}

/** The UTC-day budget row (I11). Absent row means a clean day, not an error. */
export async function loadDailyCounter(
  client: Db,
  userId: string,
  day: string,
): Promise<DailyCounter> {
  const { data, error } = await client
    .from("daily_counters")
    .select("sessions_started, rep_score_earned")
    .eq("user_id", userId)
    .eq("day", day)
    .maybeSingle();
  if (error) failDb("reading the daily counter", error);
  if (data === null) return { sessionsStarted: 0, repScoreEarned: 0 };
  return {
    sessionsStarted: num(data.sessions_started, "sessions_started"),
    // numeric → string over PostgREST; `num` is the one place that knows.
    repScoreEarned: num(data.rep_score_earned, "rep_score_earned"),
  };
}

/**
 * Claims a slot in the day's session budget. Read-then-write, so two concurrent
 * starts could both pass at the boundary and produce 21 — accepted: this is a
 * resource limit, not a correctness invariant, and making it atomic would need
 * another plpgsql function for a rounding error of one session.
 */
export async function claimSessionSlot(
  client: Db,
  userId: string,
  day: string,
): Promise<void> {
  const counter = await loadDailyCounter(client, userId, day);
  if (counter.sessionsStarted >= MAX_SESSIONS_PER_DAY) {
    throw new HttpError(
      ErrorCode.RATE_LIMITED,
      429,
      `Daily session limit of ${MAX_SESSIONS_PER_DAY} reached (I11). Resets at 00:00 UTC.`,
    );
  }
  const { error } = await client
    .from("daily_counters")
    .upsert(
      { user_id: userId, day, sessions_started: counter.sessionsStarted + 1, rep_score_earned: 0 },
      { onConflict: "user_id,day" },
    );
  if (error) failDb("claiming a session slot", error);
}

/**
 * Lifetime RepScore, read through the `user_lifetime_score` view.
 *
 * The view filters `where not voided`, so a voided session drops out of the total
 * with no correction step anywhere — that is the whole mechanism behind I12.
 */
export async function lifetimeScore(client: Db, userId: string): Promise<number> {
  const { data, error } = await client
    .from("user_lifetime_score")
    .select("lifetime_score")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) failDb("reading the lifetime score", error);
  return data === null ? 0 : num(data.lifetime_score, "lifetime_score");
}

/**
 * Per-movement rep totals, backing `repsTowardNextTier` in GET /movements.
 *
 * Read through the `user_movement_reps` view so a voided session drops out with
 * no correction step, exactly as `lifetimeScore` does.
 */
export async function repsByMovement(
  client: Db,
  userId: string,
): Promise<ReadonlyMap<string, number>> {
  const { data, error } = await client
    .from("user_movement_reps")
    .select("movement_id, reps")
    .eq("user_id", userId);
  if (error) failDb("reading per-movement rep totals", error);
  const rows = (data ?? []) as { movement_id: string; reps: number | string }[];
  return new Map(rows.map((row) => [row.movement_id, num(row.reps, "reps")]));
}

/**
 * The start fix of this account's most recent session, for the I7 travel gate.
 * Null for a first session, which the gate treats as "nothing to compare".
 */
export async function previousFix(
  client: Db,
  userId: string,
): Promise<{ lat: number; lng: number; atMs: number } | null> {
  const { data, error } = await client
    .from("workout_sessions")
    .select("start_lat, start_lng, server_start_ms")
    .eq("user_id", userId)
    .order("server_start_ms", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) failDb("reading the previous session fix", error);
  if (data === null) return null;
  return {
    lat: num(data.start_lat, "start_lat"),
    lng: num(data.start_lng, "start_lng"),
    atMs: num(data.server_start_ms, "server_start_ms"),
  };
}

/** Device binding (A3). Upsert, so a re-install on the same device is a no-op. */
export async function bindDevice(
  client: Db,
  userId: string,
  platform: string,
): Promise<void> {
  // No stable device id in this slice — the client does not send one yet — so
  // the row is keyed on (user, platform) via the conflict target. That is enough
  // for attestation_state to have somewhere to live when B-19 lands.
  const { error } = await client.from("devices").upsert({
    user_id: userId,
    platform,
    last_seen_at: new Date().toISOString(),
  });
  if (error) failDb("binding the device", error);
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

export interface NewSession {
  userId: string;
  movementConfigVersion: string;
  serverStartMs: number;
  lat: number;
  lng: number;
  accuracyM: number;
  isMocked: boolean;
  h3: string;
  spotId: string | null;
  board: "production" | "demo";
}

/** Inserts an `open` session and returns the row the caller echoes to the client. */
export async function createSession(client: Db, input: NewSession): Promise<SessionRow> {
  const { data, error } = await client
    .from("workout_sessions")
    .insert({
      user_id: input.userId,
      status: "open",
      movement_config_version: input.movementConfigVersion,
      server_start_ms: input.serverStartMs,
      expires_at_ms: input.serverStartMs + SESSION_EXPIRY_MS,
      start_lat: input.lat,
      start_lng: input.lng,
      start_accuracy_m: input.accuracyM,
      start_is_mocked: input.isMocked,
      start_h3: input.h3,
      spot_id: input.spotId,
      board: input.board,
    })
    .select()
    .single();
  if (error) failDb("creating the session", error);
  return mapSession(data);
}

/**
 * Reads a session WITHOUT consuming it. Used to run the gates first, so a
 * rejection never burns a one-shot session.
 */
export async function loadSession(
  client: Db,
  sessionId: string,
): Promise<SessionRow | null> {
  const { data, error } = await client
    .from("workout_sessions")
    .select()
    .eq("id", sessionId)
    .maybeSingle();
  if (error) failDb("reading the session", error);
  return data === null ? null : mapSession(data);
}

/**
 * The one-shot consume (I2) — and the only place session status moves to
 * `submitted`.
 *
 * `WHERE status = 'open'` in the UPDATE is the entire concurrency control. Two
 * submissions racing on the same id both pass `loadSession`, but Postgres
 * serialises the updates and only the first matches the predicate; the second
 * returns zero rows and is reported as `SESSION_ALREADY_USED`. No transaction, no
 * row lock hint, no application-level flag. Storing the verbatim Evidence in the
 * same statement means there is no window where a session is consumed but its
 * payload is not yet on disk.
 */
export async function consumeSession(
  client: Db,
  sessionId: string,
  userId: string,
  submittedAtMs: number,
  evidence: Evidence,
): Promise<boolean> {
  const { data, error } = await client
    .from("workout_sessions")
    .update({ status: "submitted", submitted_at_ms: submittedAtMs, evidence })
    .eq("id", sessionId)
    .eq("user_id", userId)
    .eq("status", "open")
    .select("id");
  if (error) failDb("consuming the session", error);
  return (data ?? []).length > 0;
}

/**
 * The atomic outcome write. Delegates to `record_session_outcome()` (0005) so all
 * six tables land in one transaction; see that migration for why the transaction
 * boundary is in SQL and not here.
 */
export async function recordOutcome(
  client: Db,
  sessionId: string,
  points: number,
  day: string,
  sets: SetPayload[],
  flags: FlagPayload[],
): Promise<void> {
  const { error } = await client.rpc("record_session_outcome", {
    p_session: sessionId,
    p_points: points,
    p_day: day,
    p_sets: sets,
    p_flags: flags,
  });
  if (error) failDb("recording the session outcome", error);
}

// ---------------------------------------------------------------------------
// Territory (B-9) — the append-only contributions ledger and its ownership cache
// ---------------------------------------------------------------------------

/**
 * Appends one immutable contribution. `power` is the awarded RepScore, frozen
 * here; decay is applied on read (`_shared/territory.ts`), never written back.
 * `hex_contributions.session_id` is UNIQUE (0007), so a double submit cannot
 * double-award territory any more than it can double-award the ledger.
 */
export async function insertHexContribution(
  client: Db,
  input: { userId: string; sessionId: string; h3: string; power: number; board: Board },
): Promise<void> {
  const { error } = await client.from("hex_contributions").insert({
    user_id: input.userId,
    session_id: input.sessionId,
    h3: input.h3,
    power: input.power,
    board: input.board,
  });
  if (error) failDb("inserting the hex contribution", error);
}

/** A `hex_contributions_live` row as PostgREST returns it. */
interface LiveContributionRow {
  user_id: string;
  h3: string;
  power: number | string;
  earned_at: string;
}

/**
 * The LIVE contributions for a set of hexes on one board, grouped by hex.
 *
 * Reads the `hex_contributions_live` VIEW (0007), not the bare table: the view
 * filters `s.status = 'submitted'`, so a voided session's contribution is already
 * gone by the time this returns — the I12 mechanism, identical to `lifetimeScore`.
 * `earned_at` (timestamptz) is converted to epoch ms here so `_shared/territory.ts`
 * stays a pure numeric function with no date parsing.
 */
export async function loadLiveContributions(
  client: Db,
  h3s: readonly string[],
  board: Board,
): Promise<Map<string, Contribution[]>> {
  const byHex = new Map<string, Contribution[]>();
  if (h3s.length === 0) return byHex;
  const { data, error } = await client
    .from("hex_contributions_live")
    .select("user_id, h3, power, earned_at")
    .eq("board", board)
    .in("h3", [...h3s]);
  if (error) failDb("reading live hex contributions", error);
  for (const row of (data ?? []) as LiveContributionRow[]) {
    const contribution: Contribution = {
      userId: row.user_id,
      power: num(row.power, "power"),
      earnedAtMs: Date.parse(row.earned_at),
    };
    const list = byHex.get(row.h3);
    if (list === undefined) byHex.set(row.h3, [contribution]);
    else list.push(contribution);
  }
  return byHex;
}

/** The materialised holder of one hex, or null when the cache has no row for it. */
export async function loadOwnership(
  client: Db,
  h3: string,
  board: Board,
): Promise<MaterialisedOwner | null> {
  const { data, error } = await client
    .from("hex_ownership")
    .select("owner_id, owner_power")
    .eq("h3", h3)
    .eq("board", board)
    .maybeSingle();
  if (error) failDb("reading hex ownership", error);
  if (data === null) return null;
  return {
    ownerId: data.owner_id as string,
    ownerPower: num(data.owner_power, "owner_power"),
  };
}

/** Writes the ownership cache row for a hex (PK `(h3, board)`, 0007). */
export async function upsertOwnership(
  client: Db,
  input: { h3: string; board: Board; ownerId: string; ownerPower: number },
): Promise<void> {
  const { error } = await client.from("hex_ownership").upsert(
    {
      h3: input.h3,
      board: input.board,
      owner_id: input.ownerId,
      owner_power: input.ownerPower,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "h3,board" },
  );
  if (error) failDb("upserting hex ownership", error);
}

/** Drops the cache row when a holder decayed below the claim threshold. */
export async function clearOwnership(client: Db, h3: string, board: Board): Promise<void> {
  const { error } = await client.from("hex_ownership").delete().eq("h3", h3).eq("board", board);
  if (error) failDb("clearing hex ownership", error);
}

/** Appends a holder-change audit row (D6 "recent flips"). Append-only (0007). */
export async function insertFlip(
  client: Db,
  input: { h3: string; board: Board; fromUserId: string | null; toUserId: string; atMs: number },
): Promise<void> {
  const { error } = await client.from("hex_flips").insert({
    h3: input.h3,
    board: input.board,
    from_user_id: input.fromUserId,
    to_user_id: input.toUserId,
    at_ms: input.atMs,
  });
  if (error) failDb("inserting the hex flip", error);
}

/** Batch handle lookup, so a bbox of many cells costs one profiles round trip. */
export async function loadHandles(
  client: Db,
  userIds: readonly string[],
): Promise<Map<string, string>> {
  const handles = new Map<string, string>();
  if (userIds.length === 0) return handles;
  const { data, error } = await client.from("profiles").select("id, handle").in("id", [...userIds]);
  if (error) failDb("reading handles", error);
  for (const row of (data ?? []) as { id: string; handle: string }[]) {
    handles.set(row.id, row.handle);
  }
  return handles;
}

export interface FlipView {
  handle: string;
  atMs: number;
}

/** The most recent holder changes for one hex, newest-first (D6). */
export async function recentFlips(
  client: Db,
  h3: string,
  board: Board,
  limit = 5,
): Promise<FlipView[]> {
  const { data, error } = await client
    .from("hex_flips")
    .select("to_user_id, at_ms")
    .eq("h3", h3)
    .eq("board", board)
    .order("at_ms", { ascending: false })
    .limit(limit);
  if (error) failDb("reading recent flips", error);
  const rows = (data ?? []) as { to_user_id: string; at_ms: number | string }[];
  const handles = await loadHandles(client, rows.map((r) => r.to_user_id));
  return rows.map((r) => ({
    handle: handles.get(r.to_user_id) ?? "unknown",
    atMs: num(r.at_ms, "at_ms"),
  }));
}

export interface LeaderboardEntry {
  handle: string;
  hexesHeld: number;
}

/**
 * The territory leaderboard (D7): holders ranked by hexes held, most first.
 *
 * Reads the `hex_ownership` CACHE, not the ledger — that is the whole reason the
 * cache exists (0007 header): counting `owner_id` rows is O(claimed hexes) with no
 * decay maths and no join to contributions. Grouping is done here rather than in
 * SQL because PostgREST has no GROUP BY and a view for it would be a fourth
 * migration object for a bounded, hackathon-scale row count. The cache can lag a
 * holder who decayed below threshold with no new session to re-resolve the cell;
 * that self-corrects on the next submit in the cell, which is the documented
 * cache-vs-truth trade-off.
 */
export async function leaderboardRows(client: Db, board: Board): Promise<LeaderboardEntry[]> {
  const { data, error } = await client.from("hex_ownership").select("owner_id").eq("board", board);
  if (error) failDb("reading the leaderboard", error);
  const rows = (data ?? []) as { owner_id: string }[];
  const counts = new Map<string, number>();
  for (const row of rows) counts.set(row.owner_id, (counts.get(row.owner_id) ?? 0) + 1);
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const handles = await loadHandles(client, ranked.map(([id]) => id));
  return ranked.map(([id, hexesHeld]) => ({
    handle: handles.get(id) ?? "unknown",
    hexesHeld,
  }));
}

// ---------------------------------------------------------------------------
// Row mapping
// ---------------------------------------------------------------------------

/** A `workout_sessions` row as PostgREST returns it. */
interface SessionDbRow {
  id: string;
  user_id: string;
  status: string;
  movement_config_version: string;
  server_start_ms: number | string;
  submitted_at_ms: number | string | null;
  expires_at_ms: number | string;
  start_lat: number | string;
  start_lng: number | string;
  start_accuracy_m: number | string;
  start_is_mocked: boolean;
  start_h3: string;
  spot_id: string | null;
  board: string;
}

/**
 * PostgREST row → the typed [SessionRow] the gates read.
 *
 * Every numeric goes through `num` even though these columns are
 * `double precision` and `bigint` (which do arrive as numbers): the coercion is
 * cheap, and a future column type change then fails here with the column name in
 * the message instead of producing NaN in a comparison three layers down.
 */
function mapSession(row: SessionDbRow): SessionRow {
  const status = row.status;
  if (
    status !== "open" && status !== "submitted" && status !== "expired" && status !== "voided"
  ) {
    throw new HttpError(
      ErrorCode.INTERNAL,
      500,
      `session ${row.id} has unknown status '${status}'`,
    );
  }
  return {
    id: row.id,
    user_id: row.user_id,
    status,
    movement_config_version: row.movement_config_version,
    server_start_ms: num(row.server_start_ms, "server_start_ms"),
    submitted_at_ms: row.submitted_at_ms === null
      ? null
      : num(row.submitted_at_ms, "submitted_at_ms"),
    expires_at_ms: num(row.expires_at_ms, "expires_at_ms"),
    start_lat: num(row.start_lat, "start_lat"),
    start_lng: num(row.start_lng, "start_lng"),
    start_accuracy_m: num(row.start_accuracy_m, "start_accuracy_m"),
    start_is_mocked: row.start_is_mocked === true,
    start_h3: row.start_h3,
    spot_id: row.spot_id ?? null,
    board: row.board === "demo" ? "demo" : "production",
  };
}
