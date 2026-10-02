/// Duel rules — one set each, same exercise, most verified reps wins. Pure,
/// like `challenges.ts`: no I/O and no clock (the caller passes `nowMs`), so the
/// whole state machine is unit-testable under plain Node.
///
/// WHAT IS STORED VS DERIVED (0009). The row holds the athletes' choices — who,
/// what, accepted or declined, and the two deadlines fixed when they were made.
/// Everything else is computed here on every read: whether a pending challenge
/// lapsed, whether the window is still open, each side's reps (their FIRST scored
/// set of the movement inside the window — one shot, like the sessions), the
/// result and the reward. Voiding a session drops its set from `duel_sets`, and
/// the next read simply sees a different answer.
///
/// The reward is capped XP claimed explicitly (G3), paid as a `challenge_claims`
/// row — never territory power (structural rule 4).

import { envOr } from "./env.ts";

/** XP for winning a duel. */
export const DUEL_WIN_XP = 100;
/** XP for posting a set and not winning — showing up is worth something. */
export const DUEL_FINISH_XP = 25;

const DEFAULT_WINDOW_S = 600;
const DEFAULT_RESPOND_S = 300;

function seconds(name: string, fallback: number): number {
  const parsed = Math.floor(Number(envOr(name, String(fallback))));
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

/** How long both athletes have to post a set once the duel is accepted. */
export function duelWindowMs(): number {
  return seconds("REPRUSH_DUEL_WINDOW_S", DEFAULT_WINDOW_S) * 1000;
}

/** How long a challenge waits for an answer. */
export function duelRespondMs(): number {
  return seconds("REPRUSH_DUEL_RESPOND_S", DEFAULT_RESPOND_S) * 1000;
}

/** The claim key in `challenge_claims`. */
export function duelClaimId(duelId: string): string {
  return `duel-${duelId}`;
}

export type StoredStatus = "pending" | "accepted" | "declined";
export type DuelStatus = "pending" | "active" | "finished" | "declined" | "expired";
export type DuelResult = "won" | "lost" | "draw";

/** A `duels` row with timestamps already in epoch ms. */
export interface DuelRow {
  id: string;
  challengerId: string;
  opponentId: string;
  movementId: string;
  status: StoredStatus;
  createdAtMs: number;
  respondByMs: number;
  acceptedAtMs: number | null;
  endsAtMs: number | null;
}

/** One scored set from `duel_sets`. */
export interface DuelSet {
  userId: string;
  movementId: string;
  repCount: number;
  submittedAtMs: number;
}

/** The wire shape of one duel, from the viewer's side. */
export interface DuelOut {
  id: string;
  movementId: string;
  opponentId: string;
  opponentHandle: string;
  incoming: boolean;
  status: DuelStatus;
  respondByMs: number;
  endsAtMs: number | null;
  myReps: number | null;
  theirReps: number | null;
  result: DuelResult | null;
  xpReward: number;
  claimed: boolean;
}

/**
 * [userId]'s one set for the duel: the earliest scored set of the duel's
 * movement submitted inside [acceptedAtMs, endsAtMs). Later sets never count,
 * even better ones — a duel is one shot.
 */
export function firstSetReps(
  sets: readonly DuelSet[],
  userId: string,
  movementId: string,
  acceptedAtMs: number,
  endsAtMs: number,
): number | null {
  let best: DuelSet | null = null;
  for (const s of sets) {
    if (s.userId !== userId || s.movementId !== movementId) continue;
    if (s.submittedAtMs < acceptedAtMs || s.submittedAtMs >= endsAtMs) continue;
    if (best === null || s.submittedAtMs < best.submittedAtMs) best = s;
  }
  return best === null ? null : best.repCount;
}

/** The duel as [viewerId] sees it at [nowMs]. */
export function viewDuel(
  row: DuelRow,
  viewerId: string,
  sets: readonly DuelSet[],
  nowMs: number,
  opponentHandle: string,
  claimed: boolean,
): DuelOut {
  const incoming = row.opponentId === viewerId;
  const otherId = incoming ? row.challengerId : row.opponentId;

  let status: DuelStatus;
  let myReps: number | null = null;
  let theirReps: number | null = null;
  if (row.status === "declined") {
    status = "declined";
  } else if (row.status === "pending") {
    status = nowMs >= row.respondByMs ? "expired" : "pending";
  } else {
    const start = row.acceptedAtMs ?? row.createdAtMs;
    const end = row.endsAtMs ?? start;
    myReps = firstSetReps(sets, viewerId, row.movementId, start, end);
    theirReps = firstSetReps(sets, otherId, row.movementId, start, end);
    status = (myReps !== null && theirReps !== null) || nowMs >= end ? "finished" : "active";
  }

  let result: DuelResult | null = null;
  if (status === "finished") {
    const mine = myReps ?? 0;
    const theirs = theirReps ?? 0;
    result = mine > theirs ? "won" : mine < theirs ? "lost" : "draw";
  }

  return {
    id: row.id,
    movementId: row.movementId,
    opponentId: otherId,
    opponentHandle,
    incoming,
    status,
    respondByMs: row.respondByMs,
    endsAtMs: row.endsAtMs,
    myReps,
    theirReps,
    result,
    xpReward: myReps === null ? 0 : result === "won" ? DUEL_WIN_XP : DUEL_FINISH_XP,
    claimed,
  };
}

/** True while a duel still blocks a new one between the same two athletes. */
export function isOpen(out: DuelOut): boolean {
  return out.status === "pending" || out.status === "active";
}

/** True when the claim may be paid. */
export function canClaim(out: DuelOut): boolean {
  return out.status === "finished" && !out.claimed && out.xpReward > 0;
}
