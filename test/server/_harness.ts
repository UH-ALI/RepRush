/// A test harness with no framework behind it.
///
/// WHY NOT `Deno.test`, AND WHY NOT `node:test`
/// The deployment target is a Supabase Edge Function, so the obvious choice is
/// `Deno.test`. Deno is not installed on this machine, and neither is the
/// Supabase CLI, so a Deno-only suite would be a suite nobody can run — which
/// for a scoring engine is the same as no suite at all. `node:test` runs here
/// today but is not something `deno test` discovers, so it would silently rot
/// the moment the team installs Deno and starts using `deno task test`.
///
/// This harness is thirty lines and depends on nothing but `node:assert`, which
/// both runtimes implement. `node test/server/run_tests.ts` works now;
/// `deno run test/server/run_tests.ts` works later, with no edits.
///
/// WHY A SINGLE ENTRYPOINT RATHER THAN GLOBBING
/// Test files register by import side effect, so `run_tests.ts` has to name
/// them. That is a small maintenance cost and a real benefit: adding a file and
/// forgetting to import it fails as a missing line in the report, not as a test
/// that quietly stopped existing.

// `node:assert/strict` rather than a hand-rolled deep-equal. Both runtimes
// implement it. The local TS server reports it unresolved because neither Deno's
// type bundle nor `@types/node` is installed here — the same tooling gap
// `build_fixtures.ts` documents for `node:fs`, not a broken import.
import { deepStrictEqual, notStrictEqual, ok, strictEqual, throws } from "node:assert/strict";

export { deepStrictEqual, notStrictEqual, ok, strictEqual, throws };

interface Registered {
  name: string;
  fn: () => void;
}

const registry: Registered[] = [];

/** Registers a test. Called at import time; run by [runTests]. */
export function test(name: string, fn: () => void): void {
  registry.push({ name, fn });
}

/**
 * Asserts two floats are within `tolerance`.
 *
 * Not `strictEqual` with a rounded value: rounding before comparing hides which
 * side moved, and half the assertions here are against numbers a document
 * quotes to two decimal places while the implementation computes them to
 * fifteen. `near` puts the actual delta in the failure message, so a broken
 * formula reports how broken it is.
 */
export function near(
  actual: number,
  expected: number,
  tolerance: number,
  what?: string,
): void {
  const delta = Math.abs(actual - expected);
  ok(
    delta <= tolerance,
    `${what ?? "value"}: got ${actual}, expected ${expected} ` +
      `(delta ${delta}, tolerance ${tolerance})`,
  );
}

/**
 * Asserts `fn` throws an error carrying `code`.
 *
 * Every rejection in this backend is a typed error with a stable machine
 * code — `HttpError`, `GateError`, `CatalogueError`, `EvidenceError` — and the
 * code is what the client branches on. Asserting only "it threw" would let a
 * 404 become a 500 without failing anything, so this reads the code back off
 * the thrown object by name rather than by class, which keeps one helper
 * working across all four error types.
 */
export function throwsCode(fn: () => unknown, code: string, what?: string): void {
  let caught: unknown = null;
  let didThrow = false;
  try {
    fn();
  } catch (error) {
    didThrow = true;
    caught = error;
  }
  ok(didThrow, `${what ?? code}: expected a throw, got none`);
  const actual = (caught as { code?: unknown })?.code;
  strictEqual(actual, code, `${what ?? code}: wrong error code`);
}

/** Runs everything registered and throws at the end if anything failed. */
export function runTests(): void {
  // An empty registry means the imports in run_tests.ts stopped resolving, or the
  // file was invoked some other way. Either would otherwise print
  // "0 passed, 0 failed" and exit 0 — the false green that this whole harness
  // exists to avoid.
  if (registry.length === 0) {
    throw new Error(
      "no tests were registered — run_tests.ts imports nothing, or it was not the entrypoint",
    );
  }

  const failures: string[] = [];
  let passed = 0;

  for (const { name, fn } of registry) {
    try {
      fn();
      passed += 1;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      failures.push(`  FAIL  ${name}\n        ${message.split("\n").join("\n        ")}`);
    }
  }

  console.log(`${passed} passed, ${failures.length} failed, ${registry.length} total`);

  if (failures.length > 0) {
    console.log("");
    console.log(failures.join("\n"));
    // Throwing rather than `process.exitCode = 1`: both runtimes turn an
    // uncaught exception into a non-zero exit, and this one also prints the
    // count in the last line of output where a CI log will show it.
    throw new Error(`${failures.length} test(s) failed`);
  }
}
