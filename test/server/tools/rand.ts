/// Deterministic pseudo-jitter.
///
/// Every fixture must produce byte-identical JSON on every run, on Node and on
/// Deno, or the goldens churn for no reason and stop being reviewable. So no
/// `Math.random`, and no `Math.sin` hashing either — `Math.sin` is accurate to
/// roughly the last bit and "roughly" is exactly the kind of thing that differs
/// between two V8 builds. This is integer arithmetic only: bit-identical
/// everywhere integers are 32-bit, which is everywhere JS runs.

/**
 * A fixed, well-spread value in `[-span, +span]` for each `(i, seed)` pair.
 *
 * Not a random number generator and not meant to be one — there is no stream and
 * no state, just a hash. Asking it for `i = 0..19` with a given seed yields the
 * same twenty numbers forever, which is the whole requirement.
 */
export function wobble(i: number, seed: number, span: number): number {
  // `| 0` on the sum: the two products individually fit an int32 but their sum
  // does not, and leaving it a float would put the ToInt32 coercion inside the
  // shift operators below where nobody would think to look for it.
  let h = (Math.imul(i, 374761393) + Math.imul(seed, 668265263)) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  // `>>> 0` before the divide: the shift result is a signed int32 and a negative
  // numerator would map the whole second half of the range onto [-span, 0).
  return ((h >>> 0) / 4294967296) * 2 * span - span;
}

/** Rounds to `places` decimals — for readable JSON, never for intermediate maths. */
export function fix(value: number, places: number): number {
  const f = 10 ** places;
  return Math.round(value * f) / f;
}
