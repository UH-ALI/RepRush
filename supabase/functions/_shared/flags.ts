/// Shadow-flag taxonomy (I13). Flags are written and never read back into a
/// response: during a hackathon a false positive that locks out a judge is far
/// worse than a cheater, so nothing here rejects, voids, or lowers a score on
/// its own. Correction is retroactive, via `void_session()`, once a human has
/// looked at what accumulated.
///
/// Severity is a triage hint for that human, not an enforcement level:
///   info          — expected gap, nothing to look at (a trace Track A has not
///                   shipped yet, a cap that legitimately applied)
///   warn          — plausible-but-notable; degrade standing on review
///   contradiction — two representations of the same set disagree. This is the
///                   class that earns the ledger its reversibility (I12)

export type Severity = "info" | "warn" | "contradiction";

export interface Flag {
  code: string;
  severity: Severity;
  /** Which set in `evidence.sets` this belongs to, when it is set-scoped. */
  setIndex?: number;
  /** Which rep within that set, when it is rep-scoped. */
  repIndex?: number;
  detail?: Record<string, unknown>;
}

export function flag(
  code: string,
  severity: Severity,
  detail?: Record<string, unknown>,
): Flag {
  return detail === undefined ? { code, severity } : { code, severity, detail };
}

// -- Scoring byproducts -----------------------------------------------------

/** B18 — excess hip displacement across a rep docked formFactor. */
export const KIP_DETECTED = "KIP_DETECTED";
/** B16 — the pull-up's independent second signal did not confirm the rep. */
export const PULLUP_UNCONFIRMED = "PULLUP_UNCONFIRMED";
/** clientRepCount disagrees with reps.length. Reconciliation only; never a count. */
export const CLIENT_COUNT_DIVERGENT = "CLIENT_COUNT_DIVERGENT";
/** I10 — the movement is not unlocked, so the set scores zero. */
export const MOVEMENT_NOT_UNLOCKED = "MOVEMENT_NOT_UNLOCKED";
/** Per-set cap applied. */
export const SET_CAPPED = "SET_CAPPED";
/** Per-day diminishing returns applied. */
export const DAILY_CAP_APPLIED = "DAILY_CAP_APPLIED";

// -- Tempo and cadence (I6, I9) ---------------------------------------------

/** Median rep cycle below the human floor — tempoFactor forced to 0.5. */
export const IMPOSSIBLE_CADENCE = "IMPOSSIBLE_CADENCE";
/** Near-zero tempo variance. Bots are metronomes; humans are not. */
export const TEMPO_UNIFORM = "TEMPO_UNIFORM";
/** No slowdown across a long set — humans fatigue. */
export const NO_FATIGUE_DRIFT = "NO_FATIGUE_DRIFT";
/** An inter-rep gap below the 0.4 s floor (I6). */
export const CADENCE_FLOOR = "CADENCE_FLOOR";

// -- Trace / summary cross-check (B-25) -------------------------------------

/** 5 Hz can only miss a peak, never overshoot it — so this is a contradiction. */
export const TRACE_PEAK_INCONSISTENT = "TRACE_PEAK_INCONSISTENT";
/** Claimed extreme and trace extreme disagree by more than tolerance. */
export const TRACE_PEAK_OUT_OF_TOLERANCE = "TRACE_PEAK_OUT_OF_TOLERANCE";
/** Threshold crossings in the trace are not within +/-1 of reps.length. */
export const TRACE_REP_COUNT_DIVERGENT = "TRACE_REP_COUNT_DIVERGENT";
/** Too few trace samples inside a rep window to assert anything about it. */
export const TRACE_INSUFFICIENT = "TRACE_INSUFFICIENT";
/** No trace on the wire. Expected until Track A ships the emitter. */
export const TRACE_MISSING = "TRACE_MISSING";

// -- Lifecycle --------------------------------------------------------------

/** Written by void_session(); the ledger row is flagged, never deleted. */
export const SESSION_VOIDED = "SESSION_VOIDED";
