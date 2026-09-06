/// The golden projection — what a `.expected.json` file contains.
///
/// WHY A PROJECTION AND NOT THE RAW `EvidenceScore`
/// `EvidenceScore` carries a per-rep record for every rep and a `cyclesMs` array
/// per set. Dumping it whole gives a 900-line golden for a twenty-rep fixture,
/// which nobody diffs and everybody regenerates blindly — the point of a golden
/// is that a change in it is a change somebody has to *read*.
///
/// What is kept is everything a reviewer would want to check by hand against
/// api-contract.md, and everything the ledger persists:
///   the totals, because they are what the athlete sees and what gets awarded;
///   per set, the four factors of the RepScore formula plus the cap result, so
///     `reps x difficulty x formFactor x tempoFactor` can be re-multiplied on a
///     calculator;
///   per rep, `romScore` and `formFactor` as flat arrays, because a regression in
///     one rep of twenty is invisible in the set-level mean;
///   the full tempo and hold statistics, since those ARE the judgement;
///   the flags, with severity and scope, without their `detail` payloads — detail
///     carries raw numbers that duplicate the above and would double every diff.
///
/// WHY THE WRITER AND THE READER SHARE THIS FILE
/// `build_fixtures.ts` writes `.expected.json` through [projectFixture] and
/// `golden_test.ts` reads it back through the same function. One shape, one
/// rounding policy, no chance of the two drifting into a comparison that passes
/// because both sides dropped the same field.
///
/// A GOLDEN IS A REGRESSION LOCK, NOT A PROOF OF CORRECTNESS
/// These numbers come out of the implementation, so a golden can only tell you
/// the implementation stopped changing. That the implementation is RIGHT is
/// established separately, by `scoring_test.ts` asserting api-contract.md's
/// worked examples as literals. Generating goldens from the code and then testing
/// the code against them would otherwise be circular.

import type {
  EvidenceScore,
  ScoredSet,
} from "../../../supabase/functions/_shared/scoring/score.ts";
import { round } from "../../../supabase/functions/_shared/scoring/score.ts";
import type { Flag, Severity } from "../../../supabase/functions/_shared/flags.ts";
import type { TraceCheckResult } from "../../../supabase/functions/_shared/validation/trace.ts";
import type { Fixture } from "./fixtures.ts";

/** A flag with its scope but not its `detail`. */
export interface GoldenFlag {
  code: string;
  severity: Severity;
  /** `null` rather than absent, so a session-scoped flag is visible as one. */
  setIndex: number | null;
  repIndex: number | null;
}

export interface GoldenTempo {
  medianCycleMs: number | null;
  meanCycleMs: number | null;
  cycleCv: number | null;
  fatigueSlope: number | null;
  minGapMs: number | null;
  subFloorGaps: number;
  uniformityPenalty: number;
  fatiguePenalty: number;
  impossibleCadence: boolean;
  tempoFactor: number;
}

export interface GoldenHold {
  segmentsTotal: number;
  qualifyingSegments: number;
  qualifyingMs: number;
  discount: number;
  bandScore: number;
  confScore: number;
  formFactor: number;
  repEquivalents: number;
}

export interface GoldenSet {
  setIndex: number;
  movementId: string;
  measurementType: string;
  tier: number;
  difficulty: number;
  unlocked: boolean;
  repCount: number;
  holdMs: number;
  formFactor: number;
  tempoFactor: number;
  /** Before any cap. */
  repScore: number;
  /** After the per-set cap and tier gating — what reaches the ledger. */
  cappedScore: number;
  scored: boolean;
  /** Flat per-rep arrays, positional with `evidence.sets[i].reps`. */
  romScores: number[];
  repFormFactors: number[];
  tempo: GoldenTempo;
  hold: GoldenHold | null;
}

export interface GoldenTraceCheck {
  setIndex: number;
  /** Reps counted from `trace.primary` alone; null when there was no trace. */
  traceReps: number | null;
  repsChecked: number;
  repsInsufficient: number;
}

export interface GoldenGate {
  /** The contract's stable error code, e.g. TIMELINE_OUT_OF_WINDOW. */
  code: string;
  status: number;
}

export interface Golden {
  /** Copied from the fixture so the golden is self-describing in isolation. */
  about: string;
  /** The Class-1 gate outcome, or null when the submission was accepted. */
  gate: GoldenGate | null;
  /** Null exactly when `gate` is not null — a rejected submission is never scored. */
  score: {
    rawTotal: number;
    awardedTotal: number;
    xp: number;
    sets: GoldenSet[];
    /**
     * Every flag the route would persist, in the route's own order: all scoring
     * flags first, then all trace flags. `session-submit/index.ts` concatenates
     * `[...score.flags, ...traceFlags]`, and the golden has to match that or the
     * comparison becomes order-sensitive for no reason.
     */
    flags: GoldenFlag[];
  } | null;
  traceChecks: GoldenTraceCheck[];
}

export function projectSet(scored: ScoredSet): GoldenSet {
  return {
    setIndex: scored.setIndex,
    movementId: scored.movementId,
    measurementType: scored.measurementType,
    tier: scored.tier,
    difficulty: round(scored.difficulty, 4),
    unlocked: scored.unlocked,
    repCount: scored.repCount,
    holdMs: scored.holdMs,
    formFactor: round(scored.formFactor),
    tempoFactor: round(scored.tempoFactor),
    repScore: round(scored.repScore),
    cappedScore: round(scored.cappedScore),
    scored: scored.scored,
    romScores: scored.reps.map((r) => round(r.romScore)),
    repFormFactors: scored.reps.map((r) => round(r.formFactor)),
    tempo: {
      medianCycleMs: roundNullable(scored.tempo.medianCycleMs, 3),
      meanCycleMs: roundNullable(scored.tempo.meanCycleMs, 3),
      cycleCv: roundNullable(scored.tempo.cycleCv),
      fatigueSlope: roundNullable(scored.tempo.fatigueSlope),
      minGapMs: roundNullable(scored.tempo.minGapMs, 3),
      subFloorGaps: scored.tempo.subFloorGaps,
      uniformityPenalty: round(scored.tempo.uniformityPenalty),
      fatiguePenalty: round(scored.tempo.fatiguePenalty),
      impossibleCadence: scored.tempo.impossibleCadence,
      tempoFactor: round(scored.tempo.tempoFactor),
    },
    hold: scored.hold === null ? null : {
      segmentsTotal: scored.hold.segmentsTotal,
      qualifyingSegments: scored.hold.qualifyingSegments,
      qualifyingMs: scored.hold.qualifyingMs,
      discount: round(scored.hold.discount),
      bandScore: round(scored.hold.bandScore),
      confScore: round(scored.hold.confScore),
      formFactor: round(scored.hold.formFactor),
      repEquivalents: round(scored.hold.repEquivalents),
    },
  };
}

function roundNullable(value: number | null, places = 6): number | null {
  return value === null ? null : round(value, places);
}

export function projectFlags(flags: readonly Flag[]): GoldenFlag[] {
  return flags.map((f) => ({
    code: f.code,
    severity: f.severity,
    setIndex: f.setIndex ?? null,
    repIndex: f.repIndex ?? null,
  }));
}

export function projectTraceChecks(checks: readonly TraceCheckResult[]): GoldenTraceCheck[] {
  return checks.map((c, i) => ({
    setIndex: i,
    traceReps: c.traceReps,
    repsChecked: c.repsChecked,
    repsInsufficient: c.repsInsufficient,
  }));
}

export function projectAccepted(
  fixture: Fixture,
  score: EvidenceScore,
  flags: readonly Flag[],
  traceChecks: readonly TraceCheckResult[],
): Golden {
  return {
    about: fixture.about,
    gate: null,
    score: {
      rawTotal: round(score.rawTotal),
      awardedTotal: round(score.awardedTotal),
      xp: score.xp,
      sets: score.sets.map(projectSet),
      flags: projectFlags(flags),
    },
    traceChecks: projectTraceChecks(traceChecks),
  };
}

export function projectRejected(
  fixture: Fixture,
  gate: GoldenGate,
  traceChecks: readonly TraceCheckResult[] = [],
): Golden {
  return {
    about: fixture.about,
    gate,
    score: null,
    traceChecks: projectTraceChecks(traceChecks),
  };
}

/**
 * Serialises a golden the way it goes on disk.
 *
 * Two-space indent and a trailing newline, so `git diff` shows one changed number
 * per line instead of a single unreadable blob. Key order is declaration order,
 * which is why every projector above builds its object literal field by field
 * rather than spreading — a spread would let a renamed field silently reorder the
 * file and produce a whole-file diff.
 */
export function serialise(golden: unknown): string {
  return `${JSON.stringify(golden, null, 2)}\n`;
}
