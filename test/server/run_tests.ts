/// The suite entrypoint. See `_harness.ts` for why this exists and why it names
/// its imports instead of globbing a directory.
///
///     node test/server/run_tests.ts          (deno task test:node)
///     deno run --allow-read test/server/run_tests.ts   (deno task test)
///
/// `--allow-read` because `catalogue_test.ts` reads the SQL migrations and
/// `golden_test.ts` reads the fixtures directory. Nothing here needs the network
/// or the environment.
///
/// DO NOT "FIX" THE TASKS BACK TO `deno test`
/// The suite registers into `_harness.ts`'s own registry and is driven by the
/// `runTests()` call at the bottom of this file. `deno test` does not know about
/// either: it would import every file below, discover zero `Deno.test` calls,
/// print "0 passed" and exit 0. A green suite that checks nothing is worse than a
/// red one, because it is the failure mode nobody looks at. `runTests()` throws on
/// an empty registry for the same reason.

import "./scoring_test.ts";
import "./thresholds_test.ts";
import "./catalogue_test.ts";
import "./schema_test.ts";
import "./rep_machine_test.ts";
import "./trace_test.ts";
import "./session_test.ts";
import "./golden_test.ts";

import { runTests } from "./_harness.ts";

runTests();
