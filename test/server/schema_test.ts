/// `parseEvidence` — the shape gate, and the enforcement point for I1.
///
/// I1 says the client never sends a score. That is not a convention the server
/// hopes the client follows; it is a rejection, and api-contract.md:211 says to
/// reject a PR that adds a score field. These tests are what makes that
/// sentence true rather than aspirational.
///
/// Every assertion here is a SHAPE check. Plausibility — whether the numbers
/// could describe a real human — lives in `_shared/validation/` and never
/// rejects (I13). Keeping the two apart is what makes the 4xx/flag split
/// coherent, so a test that found a plausibility judgement in here would be
/// reporting a real design break.

import { EvidenceError, parseEvidence } from "../../supabase/functions/_shared/evidence/schema.ts";
import { CONFIG_VERSION } from "./tools/fixtures.ts";
import { deepStrictEqual, ok, strictEqual, test, throws } from "./_harness.ts";

/** A minimal payload that parses. Mutated by each test, never shared. */
function valid(): Record<string, unknown> {
  return {
    sessionId: "00000000-0000-4000-8000-000000000001",
    movementConfigVersion: CONFIG_VERSION,
    clientVersion: "0.1.0",
    location: { lat: 51.5074, lng: -0.1278, accuracyM: 8, isMocked: false },
    spotId: null,
    sets: [
      {
        movementId: "squat",
        measurementType: "repBodyweight",
        startedAtMs: 0,
        endedAtMs: 10000,
        capture: { fpsMean: 29.4, framesTotal: 294, framesDropped: 6, modelVariant: "base" },
        calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 175 },
        reps: [
          {
            i: 0,
            tStartMs: 500,
            tEndMs: 2500,
            restExtreme: 175,
            peakExtreme: 82,
            confMean: 0.9,
            confMin: 0.82,
            concentricMs: 900,
            eccentricMs: 1100,
          },
        ],
        holdSegments: [],
      },
    ],
  };
}

function rep(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    i: 0,
    tStartMs: 500,
    tEndMs: 2500,
    restExtreme: 175,
    peakExtreme: 82,
    confMean: 0.9,
    confMin: 0.82,
    ...extra,
  };
}

/** Asserts the payload is rejected and the pointer names the offending field. */
function rejected(payload: unknown, pointerContains: string, what: string): void {
  let caught: unknown = null;
  throws(() => {
    caught = parseEvidence(payload);
  }, EvidenceError);
  // Re-throw to read the pointer: `throws` does not hand back the error.
  try {
    parseEvidence(payload);
    ok(false, `${what}: expected a rejection, payload parsed`);
  } catch (error) {
    ok(error instanceof EvidenceError, `${what}: expected an EvidenceError`);
    const pointer = (error as EvidenceError).pointer;
    ok(
      pointer.includes(pointerContains),
      `${what}: pointer '${pointer}' does not mention '${pointerContains}'`,
    );
    void caught;
  }
}

test("parseEvidence · a valid payload round-trips unchanged", () => {
  const payload = valid();
  const parsed = parseEvidence(payload);
  strictEqual(parsed.sessionId, payload.sessionId);
  strictEqual(parsed.movementConfigVersion, CONFIG_VERSION);
  strictEqual(parsed.spotId, null);
  strictEqual(parsed.sets.length, 1);
  strictEqual(parsed.sets[0].reps.length, 1);
  strictEqual(parsed.sets[0].holdSegments.length, 0);
  strictEqual(parsed.sets[0].trace, undefined);
  strictEqual(parsed.location.isMocked, false);
  // deepStrictEqual against the input would also assert absence of every
  // optional field, which is the sharper check.
  deepStrictEqual(parsed.sets[0].reps[0].concentricMs, 900);
});

// ---------------------------------------------------------------------------
// I1 — the client never sends a score
// ---------------------------------------------------------------------------

const FORBIDDEN = ["score", "repScore", "xp", "formFactor", "romScore", "tempoFactor", "points"];

for (const field of FORBIDDEN) {
  test(`parseEvidence · I1 rejects '${field}' at the root of the payload`, () => {
    const payload = valid();
    payload[field] = 42;
    rejected(payload, `/${field}`, `'${field}' at root`);
  });

  test(`parseEvidence · I1 rejects '${field}' nested inside a rep`, () => {
    // The recursive scan is what makes the rule enforceable: a score hidden two
    // levels down is just as much a violation as one at the root, and a shallow
    // check would let a client "helpfully" precompute romScore per rep.
    const payload = valid();
    (payload.sets as Record<string, unknown>[])[0] = {
      ...(payload.sets as Record<string, unknown>[])[0],
      reps: [rep({ [field]: 0.9 })],
    };
    rejected(payload, `/sets/0/reps/0/${field}`, `'${field}' inside a rep`);
  });
}

test("parseEvidence · I1 rejects a score field inside an array element", () => {
  const payload = valid();
  payload["sets"] = [{ ...(valid().sets as Record<string, unknown>[])[0], score: 1 }];
  rejected(payload, "/sets/0/score", "score inside the sets array");
});

test("parseEvidence · I1 runs before every other check", () => {
  // A payload that is wrong in two ways must report the score field, because
  // "you are not allowed to compute this" is a more fundamental problem than
  // "and your lat is out of range". Order is a contract, not an accident.
  const payload = valid();
  payload["score"] = 100;
  (payload.location as Record<string, unknown>).lat = 999;
  rejected(payload, "/score", "score must win over the location range check");
});

// ---------------------------------------------------------------------------
// The normalisation rule — api-contract.md:141-151
// ---------------------------------------------------------------------------

test("parseEvidence · a *Px field in a rep is rejected", () => {
  // "Any measurement in pixels is meaningless across distances — the same kip is
  // half the pixels from twice as far."
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    reps: [rep({ hipDriftPx: 41 })],
  };
  rejected(payload, "/sets/0/reps/0/hipDriftPx", "pixel field in a rep");
});

test("parseEvidence · a *Px field in a hold segment is rejected", () => {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    movementId: "plank",
    measurementType: "holdTime",
    reps: [],
    holdSegments: [{
      tStartMs: 500,
      tEndMs: 20500,
      meanSignal: 173,
      confMean: 0.9,
      trunkAnglePx: 30,
    }],
  };
  rejected(payload, "/sets/0/holdSegments/0/trunkAnglePx", "pixel field in a hold segment");
});

test("parseEvidence · *Px fields are legal in calibration, which is where scale lives", () => {
  // The rule is not "no pixels anywhere" — it is "pixels live in calibration
  // only". Rejecting them there too would make the rule unimplementable.
  const parsed = parseEvidence(valid());
  strictEqual(parsed.sets[0].calibration.torsoLengthPx, 420);
  strictEqual(parsed.sets[0].calibration.shoulderWidthPx, 260);
});

test("parseEvidence · calibration scale references must be positive", () => {
  // Every *Norm field is divided by one of these, so zero is a division by zero
  // and a negative is a sign flip that would invert a kip dock.
  for (const field of ["torsoLengthPx", "shoulderWidthPx"]) {
    const payload = valid();
    (payload.sets as Record<string, unknown>[])[0] = {
      ...(payload.sets as Record<string, unknown>[])[0],
      calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 175, [field]: 0 },
    };
    rejected(payload, `/sets/0/calibration/${field}`, `${field} of zero`);
  }
});

// ---------------------------------------------------------------------------
// Mutual exclusion of the two measurement types
// ---------------------------------------------------------------------------

test("parseEvidence · a repBodyweight set must not carry hold segments", () => {
  // Scoring both from one set would double-count the same minute of work.
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    holdSegments: [{ tStartMs: 500, tEndMs: 20500, meanSignal: 173, confMean: 0.9 }],
  };
  rejected(payload, "/sets/0/holdSegments", "rep set with hold segments");
});

test("parseEvidence · a holdTime set must not carry reps", () => {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    movementId: "plank",
    measurementType: "holdTime",
    holdSegments: [{ tStartMs: 500, tEndMs: 20500, meanSignal: 173, confMean: 0.9 }],
  };
  rejected(payload, "/sets/0/reps", "hold set with reps");
});

test("parseEvidence · a holdTime set with neither reps nor segments parses", () => {
  // An abandoned hold is legal evidence and scores nothing. Rejecting it would
  // make a client that records a zero-second plank unable to submit at all.
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    movementId: "plank",
    measurementType: "holdTime",
    reps: [],
    holdSegments: [],
  };
  const parsed = parseEvidence(payload);
  strictEqual(parsed.sets[0].measurementType, "holdTime");
  strictEqual(parsed.sets[0].reps.length, 0);
});

test("parseEvidence · measurementType is a closed set", () => {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    measurementType: "weighted",
  };
  rejected(payload, "/sets/0/measurementType", "an unknown measurement type");
});

// ---------------------------------------------------------------------------
// Timelines
// ---------------------------------------------------------------------------

test("parseEvidence · reps must be ordered and non-overlapping", () => {
  // The tempo statistics and the wall-clock gate both walk reps assuming this,
  // and `crossCheckTrace` uses a single forward cursor over the samples because
  // of it. An unordered list would not merely score wrong, it would under-count
  // the trace cross-check.
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    reps: [rep({ i: 0, tStartMs: 3000, tEndMs: 5000 }), rep({ i: 1, tStartMs: 500, tEndMs: 2500 })],
  };
  rejected(payload, "/sets/0/reps/1/tStartMs", "out-of-order reps");
});

test("parseEvidence · adjacent reps may touch but not overlap", () => {
  // `tStartMs < previous.tEndMs` is the failure condition, so equality is legal:
  // a zero-gap set is a cadence problem for I6 to flag, not a shape problem.
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    reps: [rep({ i: 0, tStartMs: 500, tEndMs: 2500 }), rep({ i: 1, tStartMs: 2500, tEndMs: 4500 })],
  };
  const parsed = parseEvidence(payload);
  strictEqual(parsed.sets[0].reps.length, 2);
});

test("parseEvidence · a rep may not fall outside the set window", () => {
  for (
    const [reps, what] of [
      [[rep({ tStartMs: -100, tEndMs: 2000 })], "starting before the window"],
      [[rep({ tStartMs: 500, tEndMs: 99999 })], "ending after the window"],
    ] as [Record<string, unknown>[], string][]
  ) {
    const payload = valid();
    (payload.sets as Record<string, unknown>[])[0] = {
      ...(payload.sets as Record<string, unknown>[])[0],
      reps,
    };
    rejected(payload, "/sets/0/reps", `a rep ${what}`);
  }
});

test("parseEvidence · a hold segment may not fall outside the set window", () => {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    movementId: "plank",
    measurementType: "holdTime",
    reps: [],
    holdSegments: [{ tStartMs: 500, tEndMs: 99999, meanSignal: 173, confMean: 0.9 }],
  };
  rejected(payload, "/sets/0/holdSegments", "a hold segment past the window");
});

test("parseEvidence · timestamps are offsets on a monotonic clock, never epoch", () => {
  // The convention that makes I3 work: because every *Ms is an offset from
  // client session start, a spoofed device epoch cancels out of the wall-clock
  // containment check entirely. A negative offset is the only impossible one.
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    startedAtMs: -1,
  };
  rejected(payload, "/sets/0/startedAtMs", "a negative set start");

  // An epoch-millisecond timestamp is ~1.78e12 and parses fine as a shape — it
  // is caught by the wall-clock gate, not here. This asserts the division of
  // labour rather than a rejection.
  const epoch = valid();
  (epoch.sets as Record<string, unknown>[])[0] = {
    ...(epoch.sets as Record<string, unknown>[])[0],
    startedAtMs: 1_780_000_000_000,
    endedAtMs: 1_780_000_010_000,
    reps: [rep({ tStartMs: 1_780_000_000_500, tEndMs: 1_780_000_002_500 })],
  };
  const parsed = parseEvidence(epoch);
  strictEqual(parsed.sets[0].startedAtMs, 1_780_000_000_000);
});

test("parseEvidence · endedAtMs must be after startedAtMs, and rep ends after starts", () => {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    endedAtMs: 0,
  };
  rejected(payload, "/sets/0/endedAtMs", "a zero-length set window");

  const rep2 = valid();
  (rep2.sets as Record<string, unknown>[])[0] = {
    ...(rep2.sets as Record<string, unknown>[])[0],
    reps: [rep({ tStartMs: 2500, tEndMs: 2500 })],
  };
  rejected(rep2, "/sets/0/reps/0/tEndMs", "a zero-length rep");
});

test("parseEvidence · timestamps must be integers", () => {
  // A fractional cycle would otherwise surface as a tempo statistic that cannot
  // be reproduced from the persisted integers.
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    reps: [rep({ tEndMs: 2500.5 })],
  };
  rejected(payload, "/sets/0/reps/0/tEndMs", "a fractional timestamp");
});

// ---------------------------------------------------------------------------
// Ranges and limits
// ---------------------------------------------------------------------------

test("parseEvidence · bounds that exist to keep one payload from exhausting the server", () => {
  const tooManySets = valid();
  tooManySets["sets"] = new Array(51).fill((valid().sets as Record<string, unknown>[])[0]);
  rejected(tooManySets, "/sets", "51 sets");

  const noSets = valid();
  noSets["sets"] = [];
  rejected(noSets, "/sets", "an empty session");

  const tooManyReps = valid();
  const reps = Array.from(
    { length: 501 },
    (_, i) => rep({ i, tStartMs: i * 10, tEndMs: i * 10 + 5 }),
  );
  (tooManyReps.sets as Record<string, unknown>[])[0] = {
    ...(tooManyReps.sets as Record<string, unknown>[])[0],
    endedAtMs: 1e9,
    reps,
  };
  rejected(tooManyReps, "/sets/0/reps", "501 reps in one set");
});

test("parseEvidence · 500 reps is legal, because a genuine long set must score", () => {
  const payload = valid();
  const reps = Array.from(
    { length: 500 },
    (_, i) => rep({ i, tStartMs: i * 100, tEndMs: i * 100 + 50 }),
  );
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    endedAtMs: 1e9,
    reps,
  };
  strictEqual(parseEvidence(payload).sets[0].reps.length, 500);
});

test("parseEvidence · confidence is a probability and must sit in [0, 1]", () => {
  for (const confMean of [-0.1, 1.1]) {
    const payload = valid();
    (payload.sets as Record<string, unknown>[])[0] = {
      ...(payload.sets as Record<string, unknown>[])[0],
      reps: [rep({ confMean })],
    };
    rejected(payload, "/sets/0/reps/0/confMean", `confMean ${confMean}`);
  }
});

test("parseEvidence · location ranges, and an absent isMocked reads as false", () => {
  const payload = valid();
  (payload.location as Record<string, unknown>).lat = 91;
  rejected(payload, "/location/lat", "lat above 90");

  const payload2 = valid();
  (payload2.location as Record<string, unknown>).lng = -181;
  rejected(payload2, "/location/lng", "lng below -180");

  // Optional on the wire: a client that predates the field must not be rejected,
  // and "not mocked" is the only safe default.
  const payload3 = valid();
  delete (payload3.location as Record<string, unknown>).isMocked;
  strictEqual(parseEvidence(payload3).location.isMocked, false);

  // A mocked fix parses. Whether it may SCORE is the gate's decision (I7/J7),
  // not the parser's — conflating them would put a plausibility judgement here.
  const payload4 = valid();
  (payload4.location as Record<string, unknown>).isMocked = true;
  strictEqual(parseEvidence(payload4).location.isMocked, true);
});

test("parseEvidence · fpsMean is bounded, modelVariant defaults to 'base'", () => {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    capture: { fpsMean: 1000, framesTotal: 10, framesDropped: 0 },
  };
  rejected(payload, "/sets/0/capture/fpsMean", "an impossible frame rate");

  const payload2 = valid();
  (payload2.sets as Record<string, unknown>[])[0] = {
    ...(payload2.sets as Record<string, unknown>[])[0],
    capture: { fpsMean: 30, framesTotal: 300, framesDropped: 0 },
  };
  strictEqual(parseEvidence(payload2).sets[0].capture.modelVariant, "base");
});

test("parseEvidence · spotId accepts null and a non-empty string, rejects ''", () => {
  // Null is the normal case: training in a hex rather than at a named spot.
  strictEqual(parseEvidence(valid()).spotId, null);

  const withSpot = valid();
  withSpot["spotId"] = "spot_123";
  strictEqual(parseEvidence(withSpot).spotId, "spot_123");

  const empty = valid();
  empty["spotId"] = "";
  rejected(empty, "/spotId", "an empty spotId");
});

test("parseEvidence · clientRepCount may disagree with reps.length, but not be negative", () => {
  // A mismatch is a WARN flag, never a corrected count and never a rejection:
  // reps.length is authoritative and the client's own tally is reconciliation
  // only. Rejecting here would turn a UI bug into a lost session.
  const mismatch = valid();
  (mismatch.sets as Record<string, unknown>[])[0] = {
    ...(mismatch.sets as Record<string, unknown>[])[0],
    clientRepCount: 12,
  };
  strictEqual(parseEvidence(mismatch).sets[0].clientRepCount, 12);

  const negative = valid();
  (negative.sets as Record<string, unknown>[])[0] = {
    ...(negative.sets as Record<string, unknown>[])[0],
    clientRepCount: -1,
  };
  rejected(negative, "/sets/0/clientRepCount", "a negative clientRepCount");

  // And absent is legal — Track A does not emit it yet.
  strictEqual(parseEvidence(valid()).sets[0].clientRepCount, undefined);
});

// ---------------------------------------------------------------------------
// The trace — I8
// ---------------------------------------------------------------------------

function withTrace(trace: Record<string, unknown> | null): Record<string, unknown> {
  const payload = valid();
  (payload.sets as Record<string, unknown>[])[0] = {
    ...(payload.sets as Record<string, unknown>[])[0],
    trace,
  };
  return payload;
}

test("parseEvidence · a well-formed trace parses, and null reads as absent", () => {
  const parsed = parseEvidence(
    withTrace({ hz: 5, t0Ms: 0, primary: [175, 120, 175], confMean: [0.9, 0.9, 0.9] }),
  );
  strictEqual(parsed.sets[0].trace?.hz, 5);
  deepStrictEqual(parsed.sets[0].trace?.primary, [175, 120, 175]);

  // Track A does not emit a trace yet, so both spellings of "none" must parse.
  strictEqual(parseEvidence(withTrace(null)).sets[0].trace, undefined);
  strictEqual(parseEvidence(valid()).sets[0].trace, undefined);
});

test("parseEvidence · primary and confMean are parallel arrays of equal length", () => {
  // The trace is stored as two arrays rather than an array of objects because it
  // is roughly 10x smaller on the wire (I8). That saving is only sound if the
  // two cannot desynchronise, which is exactly this check.
  rejected(
    withTrace({ hz: 5, t0Ms: 0, primary: [175, 120, 175], confMean: [0.9, 0.9] }),
    "/sets/0/trace/confMean",
    "a shorter confMean array",
  );
  rejected(
    withTrace({ hz: 5, t0Ms: 0, primary: [175, 120], confMean: [0.9, 0.9, 0.9] }),
    "/sets/0/trace/confMean",
    "a longer confMean array",
  );
  rejected(
    withTrace({ hz: 5, t0Ms: 0, primary: [], confMean: [] }),
    "/sets/0/trace/primary",
    "an empty trace",
  );
});

test("parseEvidence · trace hz is bounded to a plausible sample rate", () => {
  rejected(
    withTrace({ hz: 0, t0Ms: 0, primary: [175], confMean: [0.9] }),
    "/sets/0/trace/hz",
    "hz of zero",
  );
  rejected(
    withTrace({ hz: 1000, t0Ms: 0, primary: [175], confMean: [0.9] }),
    "/sets/0/trace/hz",
    "hz of 1000",
  );
  // 60 Hz is the ceiling and is legal; the contract asks for ~5.
  strictEqual(
    parseEvidence(withTrace({ hz: 60, t0Ms: 0, primary: [175], confMean: [0.9] })).sets[0].trace
      ?.hz,
    60,
  );
});

test("parseEvidence · trace samples are bounded and must be finite", () => {
  const big = {
    hz: 5,
    t0Ms: 0,
    primary: new Array(4001).fill(175),
    confMean: new Array(4001).fill(0.9),
  };
  rejected(withTrace(big), "/sets/0/trace/primary", "more than MAX_TRACE_SAMPLES samples");

  rejected(
    withTrace({ hz: 5, t0Ms: 0, primary: [175, Number.NaN], confMean: [0.9, 0.9] }),
    "/sets/0/trace/primary/1",
    "a NaN sample",
  );
  rejected(
    withTrace({ hz: 5, t0Ms: 0, primary: [175, 120], confMean: [0.9, 1.5] }),
    "/sets/0/trace/confMean/1",
    "a confidence above 1",
  );
});

// ---------------------------------------------------------------------------
// The error itself
// ---------------------------------------------------------------------------

test("EvidenceError · carries a JSON pointer and prefixes it to the message", () => {
  // The pointer is what makes a rejection debuggable from a log line alone. A
  // 400 that says "invalid" is indistinguishable from a client bug.
  try {
    parseEvidence({ ...valid(), sessionId: "" });
    ok(false, "expected a rejection");
  } catch (error) {
    ok(error instanceof EvidenceError, "expected an EvidenceError");
    strictEqual((error as EvidenceError).pointer, "/sessionId");
    ok(
      (error as Error).message.startsWith("/sessionId"),
      "the message should start with the pointer",
    );
    strictEqual((error as Error).name, "EvidenceError");
  }
});

test("parseEvidence · a non-object body is rejected rather than throwing a TypeError", () => {
  // The route passes `await req.json()` straight in, so this receives whatever a
  // client sent — including `null`, `"[]"` and a bare number.
  for (const body of [null, undefined, 42, "evidence", [], true]) {
    throws(() => parseEvidence(body), EvidenceError, `body ${JSON.stringify(body)}`);
  }
});
