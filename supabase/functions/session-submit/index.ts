/// POST /session/submit — consume a one-shot session and return every consequence
/// in one response (C4, I1, I2, I3, I13).
///
/// THE ORDER BELOW IS THE DESIGN. Each stage is placed where it is for a reason
/// that is easy to lose sight of when refactoring:
///
///   1. `Date.now()` FIRST. I3 compares the claimed rep timeline against the
///      server-observed window, and the closing edge of that window is the moment
///      the request arrived — not the moment we finished parsing 40 KB of JSON.
///      Taking the stamp later would silently widen the window by the parse time.
///   2. Parse. Class 1, rejects. A payload we cannot read cannot be scored.
///   3. Gates (`checkSubmitGates`). Class 1, rejects, and crucially runs against a
///      READ of the session row, not a mutation. A rejected submission must not
///      consume the one-shot: I2 means the athlete cannot retry, so burning a
///      session on a 409 would be a self-inflicted denial of service.
///   4. Catalogue + `assertResolvable`. Also before the consume, for the same
///      reason — an unknown movement id is a bad payload and must not cost a
///      session.
///   5. Trace cross-check. Class 2, flags, NEVER rejects (I13). Runs before the
///      consume only so that its flags are written in the same transaction as the
///      score; the check itself could not reject if it wanted to.
///   6. Consume. `UPDATE ... WHERE status = 'open'` — the entire concurrency
///      control for I2. Two racing submissions both reach here; Postgres
///      serialises them and exactly one matches the predicate.
///   7. Score. Pure recompute from measurements (I1). Nothing in the payload was
///      read as a score, and `parseEvidence` would have thrown if one was present.
///   8. Write. One transaction across six tables (migration 0005).
///   9. Consequences. The score is real; the territory half is REAL when
///      `territory` is live (resolved from the contributions ledger in
///      `resolveTerritory`), and the documented stub otherwise.

import { type Authed, requireUser } from "../_shared/auth.ts";
import { type Db, db } from "../_shared/db.ts";
import { assertResolvable } from "../_shared/catalogue.ts";
import { boardFor } from "../_shared/demo.ts";
import { parseEvidence } from "../_shared/evidence/schema.ts";
import { resolveThresholds } from "../_shared/evidence/thresholds.ts";
import { isLive } from "../_shared/env.ts";
import type { Flag } from "../_shared/flags.ts";
import { toFlagPayloads, toSetPayloads } from "../_shared/outcome.ts";
import { error, ErrorCode, HttpError, json, preflight, respond } from "../_shared/responses.ts";
import {
  clearOwnership,
  consumeSession,
  insertFlip,
  insertHexContribution,
  lifetimeScore,
  loadCatalogue,
  loadDailyCounter,
  loadLiveContributions,
  loadOwnership,
  loadSession,
  loadUnlocked,
  recordOutcome,
  upsertOwnership,
} from "../_shared/repo.ts";
import { scoreEvidence } from "../_shared/scoring/score.ts";
import type { Consequences, HexResultOut } from "../_shared/stubs/consequences.ts";
import { buildConsequences } from "../_shared/stubs/consequences.ts";
import { stubSubmit } from "../_shared/stubs/session-submit.ts";
import { detectFlip, minClaimPower, resolveHexPower, resolveOwner } from "../_shared/territory.ts";
import { MAX_GPS_ACCURACY_M } from "../_shared/validation/geo.ts";
import { checkSubmitGates, type SessionRow, utcDay } from "../_shared/validation/session.ts";
import { crossCheckTrace } from "../_shared/validation/trace.ts";

/// The territory write path (B-9), run AFTER `recordOutcome` so the session row is
/// already `submitted` and the `hex_contributions_live` view (0007) sees it.
///
/// GATED, in this order:
///   - D4: a start fix worse than the GPS gate, or a mocked fix, still SCORES (the
///     session and its RepScore stand) but earns NO territory. That is exactly D4's
///     "beyond this the session earns no territory credit" — the score/territory
///     split is deliberate, not an oversight.
///   - D2: below the claim threshold, nothing is written at all. A single drive-by
///     rep must not append a contribution that could never win a hex anyway.
///
/// NOT wrapped in the outcome transaction, on purpose: a territory write failing
/// must not roll back or lose an already-scored session, so the caller catches and
/// degrades to `hexResult: null` (a scored session with no capture) rather than
/// failing the submit. Territory is a consequence of the score, not part of it.
async function resolveTerritory(
  client: Db,
  user: Authed,
  session: SessionRow,
  awarded: number,
): Promise<HexResultOut | null> {
  if (session.start_accuracy_m > MAX_GPS_ACCURACY_M || session.start_is_mocked) return null;
  if (awarded < minClaimPower()) return null;

  const board = boardFor(user.isDemo);
  const h3 = session.start_h3;
  const nowMs = Date.now();

  // Append the immutable contribution first (frozen `power`, decay applied on read).
  await insertHexContribution(client, {
    userId: user.userId,
    sessionId: session.id,
    h3,
    power: awarded,
    board,
  });

  // Re-resolve the whole hex from the live ledger — now including the row above.
  const contributions = await loadLiveContributions(client, [h3], board);
  const powers = resolveHexPower(contributions.get(h3) ?? [], nowMs);
  const resolved = resolveOwner(powers, minClaimPower());
  const materialised = await loadOwnership(client, h3, board);

  // The pure flip decision; only the writes below touch the database.
  const decision = detectFlip(materialised, resolved);
  if (decision.changed) {
    if (resolved === null) await clearOwnership(client, h3, board);
    else {await upsertOwnership(client, {
        h3,
        board,
        ownerId: resolved.userId,
        ownerPower: resolved.power,
      });}
  }
  if (decision.flipped && resolved !== null) {
    await insertFlip(client, {
      h3,
      board,
      fromUserId: decision.fromUserId,
      toUserId: resolved.userId,
      atMs: nowMs,
    });
  }

  const yourPower = powers.get(user.userId) ?? 0;
  const captured = resolved !== null && resolved.userId === user.userId;
  return {
    h3,
    captured,
    // The hex's incumbent (winner) power, distinct from yourPower whenever the cell
    // is contested — the whole point of returning both (consequences.ts STUB note).
    power: resolved === null ? yourPower : resolved.power,
    yourPower,
  };
}

async function handleSubmit(req: Request, user: Authed): Promise<Consequences> {
  const client = db();

  // 1. The observed window closes now.
  const submitMs = Date.now();
  const day = utcDay(submitMs);

  // 2. Parse. Throws EvidenceError → 422 EVIDENCE_MALFORMED, including a JSON
  //    pointer to the offending field.
  const raw: unknown = await req.json().catch(() => null);
  const evidence = parseEvidence(raw);

  // 3. Class-1 gates against a non-mutating read.
  const row = await loadSession(client, evidence.sessionId);
  checkSubmitGates(row, evidence, user.userId, submitMs);
  // checkSubmitGates has already asserted the row exists and is owned by this
  // user; the non-null assertion keeps the rest of the function readable.
  const session = row!;

  // 4. Resolve the catalogue bound to the SESSION's version, not the payload's —
  //    the two were just proved equal, but scoring against the stored value means
  //    a future relaxation of that gate cannot silently change which thresholds
  //    apply.
  const catalogue = await loadCatalogue(client, session.movement_config_version);
  assertResolvable(catalogue, evidence);

  // 5. Class 2 — shadow flags. Never rejects, never changes the score.
  const traceFlags: Flag[] = [];
  evidence.sets.forEach((set, i) => {
    const thresholds = resolveThresholds(catalogue, set.movementId, set.calibration.restSignal);
    traceFlags.push(...crossCheckTrace(set, i, thresholds).flags);
  });

  // 6. Consume. If this returns false, someone won the race between step 3 and
  //    here — same answer as a plain double submission.
  const consumed = await consumeSession(
    client,
    session.id,
    user.userId,
    submitMs,
    evidence,
  );
  if (!consumed) {
    throw new HttpError(
      ErrorCode.SESSION_ALREADY_USED,
      409,
      `Session '${session.id}' was consumed by a concurrent submission. Sessions are one-shot.`,
    );
  }

  // Independent reads; no ordering between them, so they go out together. The
  // three round trips are the whole latency cost of the live path beyond scoring.
  const [unlocked, counter, priorXp] = await Promise.all([
    loadUnlocked(client, user.userId),
    loadDailyCounter(client, user.userId, day),
    lifetimeScore(client, user.userId),
  ]);

  // 7. Recompute. Every number in the response below originates here or in the
  //    catalogue — none in the payload.
  const score = scoreEvidence(evidence, {
    catalogue,
    unlockedMovements: unlocked,
    alreadyEarnedToday: counter.repScoreEarned,
  });

  // 8. One transaction: set_records, rep_events, pose_traces, score_ledger,
  //    session_flags, daily_counters.
  await recordOutcome(
    client,
    session.id,
    score.awardedTotal,
    day,
    toSetPayloads(evidence, score),
    toFlagPayloads([...score.flags, ...traceFlags]),
  );

  // 9. C4. Territory resolution uses the SERVER-RECORDED start context, never
  //    evidence.location — that is what makes the capture deterministic. The hex
  //    half is real when `territory` is live (B-9); otherwise `hexResultOverride`
  //    stays `undefined` and buildConsequences falls back to its documented stub.
  //    A territory FAILURE degrades to `null` (scored, no capture) — never fails the
  //    submit, because the score is already committed by recordOutcome above.
  let hexResult: HexResultOut | null | undefined;
  if (isLive("territory")) {
    try {
      hexResult = await resolveTerritory(client, user, session, score.awardedTotal);
    } catch (failure) {
      console.error(
        "territory resolution failed; returning the scored session without a capture",
        failure,
      );
      hexResult = null;
    }
  }

  return buildConsequences({
    h3: session.start_h3,
    spotId: session.spot_id,
    score,
    priorLifetimeXp: priorXp,
    hexResultOverride: hexResult,
  });
}

// Not async: this handler only dispatches, and `respond` already returns the
// promise. An `async` that never awaits is what require-await flags.
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    if (req.method !== "POST") {
      return error(ErrorCode.MALFORMED_REQUEST, "session/submit is POST only.", 405);
    }
    const user = await requireUser(req);
    if (!isLive("session-submit")) return json(stubSubmit());
    return json(await handleSubmit(req, user));
  });
});
