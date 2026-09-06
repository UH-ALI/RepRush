/// Wall-clock containment (I3, B-8).
///
/// "The server records start and submit times itself; the claimed rep timeline
/// must fit inside that observed window. A ten-minute workout submitted forty
/// seconds after the session opened is rejected. No client clock is ever
/// trusted."
///
/// The mechanism that makes "no client clock is trusted" true: every `*Ms` field
/// in Evidence is an OFFSET from the client's session start on a monotonic clock,
/// never an epoch timestamp. So the check is a comparison of two DURATIONS —
/// claimed elapsed versus observed elapsed — and an arbitrary or spoofed client
/// epoch cancels out entirely. There is no client-supplied wall-clock value in
/// the comparison to lie about.

import type { EvidenceSet } from "../evidence/schema.ts";

/**
 * Slack for the asymmetry between the two clocks. The client starts counting
/// slightly before its own t=0 is stamped and the server stamps submit slightly
/// after the last frame is processed; without slack, an honest submission fails
/// on a few hundred milliseconds of scheduling noise.
 *
 * Five seconds is generous against that noise and irrelevant against the attack
 * — nobody forges a ten-minute set with five seconds of slack.
 */
export const WALLCLOCK_SLACK_MS = 5000;

export interface WallClockResult {
  ok: boolean;
  /** max(endedAtMs) across sets, i.e. the claimed session duration. */
  claimedSpanMs: number;
  /** serverSubmitMs - serverStartMs. */
  observedWindowMs: number;
  /** The earliest claimed offset; negative beyond slack means a bad t=0. */
  earliestStartMs: number;
  reason?: string;
}

export function checkWallClock(
  sets: EvidenceSet[],
  serverStartMs: number,
  serverSubmitMs: number,
): WallClockResult {
  const observedWindowMs = serverSubmitMs - serverStartMs;

  // The server's own two stamps must be ordered. They always are in practice —
  // submit is stamped on arrival — but a negative window would make every
  // containment check below pass vacuously, so it is worth an explicit guard.
  if (observedWindowMs < 0) {
    return {
      ok: false,
      claimedSpanMs: 0,
      observedWindowMs,
      earliestStartMs: 0,
      reason: "server submit time precedes server start time",
    };
  }

  if (sets.length === 0) {
    return { ok: true, claimedSpanMs: 0, observedWindowMs, earliestStartMs: 0 };
  }

  const earliestStartMs = Math.min(...sets.map((s) => s.startedAtMs));
  const claimedSpanMs = Math.max(...sets.map((s) => s.endedAtMs));

  if (earliestStartMs < -WALLCLOCK_SLACK_MS) {
    return {
      ok: false,
      claimedSpanMs,
      observedWindowMs,
      earliestStartMs,
      reason: `set starts ${-earliestStartMs} ms before the session opened`,
    };
  }

  if (claimedSpanMs > observedWindowMs + WALLCLOCK_SLACK_MS) {
    return {
      ok: false,
      claimedSpanMs,
      observedWindowMs,
      earliestStartMs,
      reason: `claimed ${claimedSpanMs} ms of work inside a ${observedWindowMs} ms observed window`,
    };
  }

  return { ok: true, claimedSpanMs, observedWindowMs, earliestStartMs };
}
