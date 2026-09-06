/// Range of motion — the *grade*, not the gate.
///
/// ROM is enforced in two places and conflating them is what makes the design
/// read as arbitrary (docs/api-contract.md §ROM):
///
///   1. The threshold is the GATE. A shallow squat never crosses `enterPeak`, so
///      it never changes state, so it is never a rep. Not counted-then-penalised
///      — it does not exist. That enforcement happens in Track A's state machine
///      and is free; nothing here needs to re-check it.
///   2. Depth beyond the threshold is the GRADE. That is this file.

export function clamp(value: number, lo: number, hi: number): number {
  const clamped = value < lo ? lo : value > hi ? hi : value;
  // `-0 === 0` is true, so this returns the literal `+0` for either zero.
  //
  // A negative zero reaches here legitimately: `romScore` divides by a negative
  // denominator for every decreasing movement, so a rep whose peakExtreme sits
  // exactly on enterPeak computes `0 / -30` = `-0`, and `-0 < lo` is false so
  // the clamp passes it straight through. Arithmetically harmless — but it
  // serialises to JSON as `0` and parses back as `+0`, which makes any
  // Object.is-based comparison (assert.deepStrictEqual on a golden, for one)
  // fail on two values that print identically. Normalising in the one function
  // every scoring path already calls means no caller has to remember to.
  return clamped === 0 ? 0 : clamped;
}

/**
 *     romScore = clamp( (peakExtreme - enterPeak) / (romTarget - enterPeak), 0, 1 )
 *
 * The signs cancel, so one formula covers both directions: a squat's peak is
 * numerically below its thresholds and a jumping jack's is above, and both come
 * out as a positive fraction.
 *
 * Worked examples from api-contract.md (rest 175 squat, rest 175 pull-up,
 * rest 0.35 jumping jack) are asserted as literals in scoring_test.ts.
 */
export function romScore(
  peakExtreme: number,
  enterPeak: number,
  romTarget: number,
): number {
  const denominator = romTarget - enterPeak;
  // A movement whose romTarget equals its enterPeak has no depth left to grade.
  // That is a seeding bug, and 0 is the safe reading — never a windfall.
  if (denominator === 0) return 0;
  return clamp((peakExtreme - enterPeak) / denominator, 0, 1);
}
