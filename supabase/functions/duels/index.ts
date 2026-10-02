/// GET /duels · POST /duels · POST /duels/:id/accept|decline|claim.
///
/// One set each, same exercise, most verified reps wins. One deployed function,
/// dispatched on the path tail like `territory`. ALWAYS LIVE, like `challenges`:
/// reads are derivations over verified sets and every write is one guarded
/// statement, so there is no risky path worth a LIVE_ENDPOINTS flag.
///
/// PRESENCE IS THE GATE. A challenge is only accepted between two athletes who
/// are both visible right now, on the same board, within `NEARBY_RING_K` rings of
/// each other — so a duel is always with someone you could walk over to. After
/// that, the duel lives on its own; going hidden mid-duel does not cancel it.
///
/// Scores come from `duel_sets` (0009) — scored sets in submitted sessions, on
/// the server's submit clock — through the pure rules in `_shared/duels.ts`.
/// Nothing the client counted is read. The reward is a `challenge_claims` row,
/// i.e. capped XP that GET /me already adds up; territory never sees it.

import { type Authed, requireUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { boardFor } from "../_shared/demo.ts";
import {
  canClaim,
  duelClaimId,
  type DuelOut,
  duelRespondMs,
  duelWindowMs,
  isOpen,
  viewDuel,
} from "../_shared/duels.ts";
import { hexRing } from "../_shared/h3.ts";
import { isFresh, NEARBY_RING_K } from "../_shared/presence.ts";
import {
  answerDuel,
  claimedTemplates,
  duelSets,
  insertClaim,
  insertDuel,
  loadDuel,
  loadHandles,
  loadPresence,
  movementExists,
  recentDuels,
  type StoredDuel,
} from "../_shared/repo.ts";
import { error, ErrorCode, HttpError, json, preflight, respond } from "../_shared/responses.ts";

/** How far back the list reaches: today's rivalries, not an archive. */
const LIST_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Each duel as [user] sees it now — sets, handles and claims read in bulk. */
async function view(user: Authed, duels: readonly StoredDuel[]): Promise<DuelOut[]> {
  const client = db();
  const nowMs = Date.now();
  const others = duels.map((d) => d.challengerId === user.userId ? d.opponentId : d.challengerId);
  const [handles, claimed, sets] = await Promise.all([
    loadHandles(client, [...new Set(others)]),
    claimedTemplates(client, user.userId, duels.map((d) => duelClaimId(d.id))),
    Promise.all(
      duels.map((d) =>
        d.status === "accepted" && d.acceptedAtMs !== null && d.endsAtMs !== null
          ? duelSets(
            client,
            d.board,
            [d.challengerId, d.opponentId],
            d.movementId,
            d.acceptedAtMs,
            d.endsAtMs,
          )
          : Promise.resolve([])
      ),
    ),
  ]);
  return duels.map((d, i) =>
    viewDuel(
      d,
      user.userId,
      sets[i],
      nowMs,
      handles.get(others[i]) ?? "athlete",
      claimed.has(duelClaimId(d.id)),
    )
  );
}

async function handleList(user: Authed): Promise<DuelOut[]> {
  return await view(user, await recentDuels(db(), user.userId, Date.now() - LIST_WINDOW_MS));
}

async function handleChallenge(req: Request, user: Authed): Promise<DuelOut> {
  const raw = (await req.json().catch(() => null)) as Record<string, unknown> | null;
  const opponentId = raw?.["opponentId"];
  const movementId = raw?.["movementId"];
  if (typeof opponentId !== "string" || typeof movementId !== "string") {
    throw new HttpError(
      ErrorCode.MALFORMED_REQUEST,
      400,
      "Expected { opponentId: string, movementId: string }.",
    );
  }
  if (opponentId === user.userId) {
    throw new HttpError(ErrorCode.NOT_NEARBY, 409, "You cannot duel yourself.");
  }

  const client = db();
  const nowMs = Date.now();
  const board = boardFor(user.isDemo);
  const [mine, theirs, known] = await Promise.all([
    loadPresence(client, user.userId),
    loadPresence(client, opponentId),
    movementExists(client, movementId),
  ]);
  if (!known) {
    throw new HttpError(ErrorCode.MALFORMED_REQUEST, 400, `Unknown movement: ${movementId}.`);
  }
  if (mine === null || mine.board !== board || !isFresh(mine.updatedAtMs, nowMs)) {
    throw new HttpError(ErrorCode.NOT_VISIBLE, 409, "Go visible before challenging anyone.");
  }
  if (
    theirs === null || theirs.board !== board || !isFresh(theirs.updatedAtMs, nowMs) ||
    !hexRing(mine.h3, NEARBY_RING_K).includes(theirs.h3)
  ) {
    throw new HttpError(ErrorCode.NOT_NEARBY, 409, "That athlete is not visible near you.");
  }

  // One open duel per pair. Advisory — two simultaneous challenges between the
  // same pair can both land, which costs nothing worse than two duels.
  const open = (await view(user, await recentDuels(client, user.userId, nowMs - LIST_WINDOW_MS)))
    .some((d) => d.opponentId === opponentId && isOpen(d));
  if (open) {
    throw new HttpError(
      ErrorCode.DUEL_ALREADY_OPEN,
      409,
      "A duel with this athlete is already open.",
    );
  }

  const duel = await insertDuel(client, {
    board,
    challengerId: user.userId,
    opponentId,
    movementId,
    respondByMs: nowMs + duelRespondMs(),
  });
  return (await view(user, [duel]))[0];
}

async function participantDuel(user: Authed, id: string): Promise<StoredDuel> {
  const duel = await loadDuel(db(), id);
  if (duel === null || (duel.challengerId !== user.userId && duel.opponentId !== user.userId)) {
    throw new HttpError(ErrorCode.UNKNOWN_DUEL, 404, "No such duel.");
  }
  return duel;
}

async function handleAnswer(user: Authed, id: string, accept: boolean): Promise<DuelOut> {
  const duel = await participantDuel(user, id);
  if (duel.opponentId !== user.userId) {
    throw new HttpError(ErrorCode.UNKNOWN_DUEL, 404, "Only the challenged athlete can answer.");
  }
  const nowMs = Date.now();
  const answered = await answerDuel(
    db(),
    id,
    accept ? { accept: true, acceptedAtMs: nowMs, endsAtMs: nowMs + duelWindowMs() } : {
      accept: false,
    },
    nowMs,
  );
  if (answered === null) {
    throw new HttpError(
      ErrorCode.DUEL_CLOSED,
      409,
      "This challenge was already answered or lapsed.",
    );
  }
  return (await view(user, [answered]))[0];
}

async function handleClaim(
  user: Authed,
  id: string,
): Promise<{ claimed: true; xpAwarded: number }> {
  const out = (await view(user, [await participantDuel(user, id)]))[0];
  if (out.claimed) {
    throw new HttpError(ErrorCode.ALREADY_CLAIMED, 409, "Duel reward already claimed.");
  }
  if (!canClaim(out)) {
    throw new HttpError(
      ErrorCode.DUEL_CLOSED,
      409,
      out.status === "finished" ? "No set posted, so no reward." : "The duel is not over yet.",
    );
  }
  // The claim's primary key is the real double-claim guard.
  const inserted = await insertClaim(db(), {
    userId: user.userId,
    templateId: duelClaimId(id),
    xp: out.xpReward,
  });
  if (!inserted) {
    throw new HttpError(ErrorCode.ALREADY_CLAIMED, 409, "Duel reward already claimed.");
  }
  return { claimed: true, xpAwarded: out.xpReward };
}

/** The path tail after the `duels` function name: [], [id, action]. */
function routeParts(pathname: string): string[] {
  const parts = pathname.split("/").filter((s) => s.length > 0);
  const idx = parts.indexOf("duels");
  return idx >= 0 ? parts.slice(idx + 1) : parts;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Not async: dispatches only, `respond` returns the promise (see movements/index.ts).
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    const user = await requireUser(req);
    const parts = routeParts(new URL(req.url).pathname);

    if (parts.length === 0 && req.method === "GET") return json(await handleList(user));
    if (parts.length === 0 && req.method === "POST") return json(await handleChallenge(req, user));
    if (parts.length === 2 && req.method === "POST") {
      const [id, action] = parts;
      if (!UUID.test(id)) throw new HttpError(ErrorCode.UNKNOWN_DUEL, 404, "No such duel.");
      if (action === "accept") return json(await handleAnswer(user, id, true));
      if (action === "decline") return json(await handleAnswer(user, id, false));
      if (action === "claim") return json(await handleClaim(user, id));
    }

    return error(
      ErrorCode.MALFORMED_REQUEST,
      `Unknown duels route: ${req.method} /${parts.join("/")}.`,
      404,
    );
  });
});
