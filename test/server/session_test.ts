/// Session lifecycle gates — Class 1 validation, and I3's wall-clock mechanism.
///
/// These are the only rejections in the backend. Everything else that finds a
/// problem raises a shadow flag and scores the set anyway (I13), on the reasoning
/// that a false-positive lockout during a hackathon is worse than a cheat. That
/// makes the gate list load-bearing in a way the flag list is not: a gate that
/// fires wrongly stops the demo, and a gate that does not fire lets a submission
/// through that cannot be scored at all.
///
/// Three properties get most of the attention below:
///
///   - ORDER. The gates run in a fixed sequence and a payload that is wrong in
///     two ways must report the more fundamental one. Existence and ownership
///     come first so that nothing downstream can be probed without a live
///     session.
///   - OWNERSHIP IS NOT DISTINGUISHABLE FROM NONEXISTENCE. A session belonging to
///     someone else reports UNKNOWN_SESSION, because a separate "not yours"
///     error would let an attacker enumerate which UUIDs are live.
///   - NO CLIENT CLOCK IS COMPARED (I3). Every `*Ms` in Evidence is an offset from
///     the client's own session start, so the check compares two durations and a
///     spoofed epoch cancels out entirely.

import type { Evidence, EvidenceSet } from "../../supabase/functions/_shared/evidence/schema.ts";
import {
  checkStartGates,
  checkSubmitGates,
  GateError,
  parseStartRequest,
  SESSION_EXPIRY_MS,
  type SessionRow,
  utcDay,
} from "../../supabase/functions/_shared/validation/session.ts";
import {
  CONTEXT_MATCH_RADIUS_M,
  haversineM,
  impliedTravel,
  MAX_GPS_ACCURACY_M,
  MAX_TRAVEL_SPEED_KMH,
} from "../../supabase/functions/_shared/validation/geo.ts";
import {
  checkWallClock,
  WALLCLOCK_SLACK_MS,
} from "../../supabase/functions/_shared/validation/wallclock.ts";
import { CONFIG_VERSION, VENUE_H3 } from "./tools/fixtures.ts";
import { deepStrictEqual, ok, strictEqual, test } from "./_harness.ts";

const SESSION_ID = "00000000-0000-4000-8000-000000000001";
const USER = "11111111-1111-4111-8111-111111111111";
const OTHER_USER = "22222222-2222-4222-8222-222222222222";
/** A plausible epoch for "now" on demo day. Only the server ever sees it. */
const START_MS = 1_757_000_000_000;
/** The demo venue. The Evidence location matches it exactly unless a test says otherwise. */
const LAT = 51.5074;
const LNG = -0.1278;

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

function row(overrides: Partial<SessionRow> = {}): SessionRow {
  return {
    id: SESSION_ID,
    user_id: USER,
    status: "open",
    movement_config_version: CONFIG_VERSION,
    server_start_ms: START_MS,
    submitted_at_ms: null,
    expires_at_ms: START_MS + SESSION_EXPIRY_MS,
    start_lat: LAT,
    start_lng: LNG,
    start_accuracy_m: 8,
    start_is_mocked: false,
    start_h3: VENUE_H3,
    spot_id: null,
    board: "production",
    ...overrides,
  };
}

/** One squat set spanning `startedAtMs`..`endedAtMs` in client offsets. */
function set(
  startedAtMs: number,
  endedAtMs: number,
  extra: Partial<EvidenceSet> = {},
): EvidenceSet {
  return {
    movementId: "squat",
    measurementType: "repBodyweight",
    startedAtMs,
    endedAtMs,
    capture: { fpsMean: 29.4, framesTotal: 1764, framesDropped: 12, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 175 },
    reps: [
      {
        i: 0,
        tStartMs: startedAtMs + 1000,
        tEndMs: startedAtMs + 3000,
        restExtreme: 175,
        peakExtreme: 96,
        confMean: 0.9,
        confMin: 0.82,
      },
    ],
    holdSegments: [],
    ...extra,
  };
}

function evidence(overrides: Partial<Evidence> = {}): Evidence {
  return {
    sessionId: SESSION_ID,
    movementConfigVersion: CONFIG_VERSION,
    clientVersion: "0.1.0",
    location: { lat: LAT, lng: LNG, accuracyM: 8, isMocked: false },
    spotId: null,
    sets: [set(0, 60_000)],
    ...overrides,
  };
}

/** Two minutes of observed session — comfortably wider than the claimed 60 s. */
const SUBMIT_MS = START_MS + 120_000;

function submit(r: SessionRow | null, e: Evidence, userId = USER, nowMs = SUBMIT_MS): void {
  checkSubmitGates(r, e, userId, nowMs);
}

/** Returns the thrown GateError so both `code` and `status` can be asserted. */
function gateOf(fn: () => unknown, what: string): GateError {
  try {
    fn();
  } catch (error) {
    ok(error instanceof GateError, `${what}: expected a GateError, got ${String(error)}`);
    return error as GateError;
  }
  throw new Error(`${what}: expected a rejection, the gate passed`);
}

function rejects(
  fn: () => unknown,
  code: string,
  status: number,
  what: string,
): GateError {
  const error = gateOf(fn, what);
  strictEqual(error.code, code, `${what}: wrong code`);
  // The status is part of the contract, not decoration: a 404 that arrives as a
  // 500 makes the client retry a submission that will never succeed.
  strictEqual(error.status, status, `${what}: wrong status for ${code}`);
  return error;
}

// ---------------------------------------------------------------------------
// The happy path
// ---------------------------------------------------------------------------

test("checkSubmitGates · a clean submission passes every gate", () => {
  submit(row(), evidence());
});

test("checkSubmitGates · a submission right at the expiry edge still passes", () => {
  // `nowMs > expires_at_ms` is strict, so the last millisecond of the 4 h window
  // is still usable. An athlete who starts a set at 3:59 and finishes it must not
  // be rejected for the server's own bookkeeping.
  strictEqual(SESSION_EXPIRY_MS, 4 * 60 * 60 * 1000);
  const r = row();
  submit(r, evidence(), USER, r.expires_at_ms);
  rejects(
    () => submit(r, evidence(), USER, r.expires_at_ms + 1),
    "SESSION_EXPIRED",
    410,
    "one millisecond past the window",
  );
});

test("checkSubmitGates · a demo-board session accepts a mocked location", () => {
  // J7: demo context is decided server-side. The row's board is what says so, and
  // the gate only refuses a mocked fix against a PRODUCTION session. Refusing it
  // here too would make the demo phone unable to submit at all, since the venue
  // fix is substituted by the caller.
  submit(
    row({ board: "demo" }),
    evidence({
      location: { lat: LAT, lng: LNG, accuracyM: 8, isMocked: true },
    }),
  );
});

// ---------------------------------------------------------------------------
// Gate 1 — existence and ownership
// ---------------------------------------------------------------------------

test("checkSubmitGates · no session row is UNKNOWN_SESSION 404", () => {
  rejects(() => submit(null, evidence()), "UNKNOWN_SESSION", 404, "a null row");
});

test("checkSubmitGates · someone else's session is also UNKNOWN_SESSION, not 'not yours'", () => {
  // The single most important line in this file. A distinct ownership error would
  // turn the endpoint into a UUID oracle: submit against a random id, and a
  // "not yours" response confirms the id is live while a 404 confirms it is not.
  // Session ids are server-generated and unguessable in practice, but the
  // response must not leak the distinction even so.
  const error = rejects(
    () => submit(row({ user_id: OTHER_USER }), evidence()),
    "UNKNOWN_SESSION",
    404,
    "a session owned by another account",
  );
  // And the message must not name the real owner either.
  ok(!error.message.includes(OTHER_USER), "the message leaks the owning user id");
});

test("checkSubmitGates · the error message names the session, not the account", () => {
  const error = gateOf(() => submit(null, evidence()), "null row");
  ok(error.message.includes(SESSION_ID), "the message should echo the submitted session id");
});

// ---------------------------------------------------------------------------
// Gates 2–4 — one-shot and expiry (I2)
// ---------------------------------------------------------------------------

test("checkSubmitGates · a submitted session is SESSION_ALREADY_USED 409", () => {
  // I2: "A second submission against the same id — verbatim or edited — is
  // rejected." The whole append-only ledger depends on this; a replayable session
  // is a repeatable score.
  const r = row({ status: "submitted", submitted_at_ms: START_MS + 60_000 });
  rejects(() => submit(r, evidence()), "SESSION_ALREADY_USED", 409, "a consumed session");
});

test("checkSubmitGates · a voided session is also SESSION_ALREADY_USED", () => {
  // I12 voids rather than deletes, so a voided row is still present and still
  // consumed. Allowing a resubmit would be the one way to score against a
  // session a human had already ruled invalid.
  rejects(
    () => submit(row({ status: "voided" }), evidence()),
    "SESSION_ALREADY_USED",
    409,
    "a voided session",
  );
});

test("checkSubmitGates · a row marked expired is SESSION_EXPIRED 410", () => {
  // 410 Gone rather than 409: the resource existed and is permanently
  // unavailable, which is what tells the client to start a new session instead of
  // retrying.
  rejects(
    () => submit(row({ status: "expired" }), evidence()),
    "SESSION_EXPIRED",
    410,
    "a row the expiry sweeper already marked",
  );
});

test("checkSubmitGates · an open row past its expiry is SESSION_EXPIRED 410 too", () => {
  // The sweeper is a batch job and may not have run yet, so the gate checks the
  // timestamp itself. Without this second path a session would stay submittable
  // for however long the sweeper was behind — which on demo day is "all day".
  const r = row({ status: "open" });
  rejects(
    () => submit(r, evidence(), USER, r.expires_at_ms + 60_000),
    "SESSION_EXPIRED",
    410,
    "an unmarked row past its window",
  );
});

test("checkSubmitGates · consumption beats expiry when both are true", () => {
  // ORDER. A session submitted and then left past its window reports the
  // consumption, because "you already used this" is the more specific and more
  // actionable fact than "and it is also old".
  const r = row({ status: "submitted", submitted_at_ms: START_MS + 60_000 });
  rejects(
    () => submit(r, evidence(), USER, r.expires_at_ms + 1),
    "SESSION_ALREADY_USED",
    409,
    "submitted AND expired",
  );
});

test("checkSubmitGates · ownership beats every later gate", () => {
  // ORDER. Someone else's session that is ALSO expired, misconfigured, at the
  // wrong spot and outside the window still reports UNKNOWN_SESSION — otherwise
  // the differing message would leak that the row exists.
  const r = row({
    user_id: OTHER_USER,
    status: "expired",
    movement_config_version: "1999-01-01.1",
    spot_id: "some-other-spot",
    start_lat: 40.7128,
    start_lng: -74.006,
  });
  const e = evidence({ movementConfigVersion: CONFIG_VERSION, spotId: null });
  rejects(
    () => submit(r, e, USER, r.expires_at_ms + 1_000_000),
    "UNKNOWN_SESSION",
    404,
    "an invalid session owned by someone else",
  );
});

// ---------------------------------------------------------------------------
// Gate 5 — the sessionId in the Evidence must match the row
// ---------------------------------------------------------------------------

test("checkSubmitGates · Evidence naming a different session is UNKNOWN_SESSION 404", () => {
  // Not a distinct code, for the same reason as ownership: "this payload is about
  // a session that is not the one you are submitting" must be indistinguishable
  // from "no such session".
  rejects(
    () => submit(row(), evidence({ sessionId: "00000000-0000-4000-8000-000000000002" })),
    "UNKNOWN_SESSION",
    404,
    "a mismatched evidence sessionId",
  );
});

test("checkSubmitGates · the sessionId check precedes the config check", () => {
  // ORDER. Both are wrong here; the session identity is the more fundamental
  // problem, and reporting the config mismatch would confirm the row is live.
  rejects(
    () =>
      submit(
        row({ movement_config_version: "1999-01-01.1" }),
        evidence({ sessionId: "00000000-0000-4000-8000-000000000002" }),
      ),
    "UNKNOWN_SESSION",
    404,
    "wrong session AND wrong config version",
  );
});

// ---------------------------------------------------------------------------
// Gate 6 — the bound configuration version
// ---------------------------------------------------------------------------

test("checkSubmitGates · a config version mismatch is 409", () => {
  // Offsets are rest-relative and versioned, so thresholds from two versions are
  // not comparable. Scoring anyway would silently apply the wrong enterPeak to
  // every rep — a wrong score with no error anywhere.
  const error = rejects(
    () =>
      submit(
        row({ movement_config_version: "2026-08-30.1" }),
        evidence({ movementConfigVersion: "2026-01-01.9" }),
      ),
    "CONFIG_VERSION_MISMATCH",
    409,
    "evidence captured against a different version",
  );
  // Both versions are named, because this is a support question as often as a
  // bug: "which build is that phone on?"
  ok(error.message.includes("2026-01-01.9"), "the message should name the evidence version");
  ok(error.message.includes("2026-08-30.1"), "the message should name the session version");
});

test("checkSubmitGates · the fixtures bind to the version 0003 seeds", () => {
  // A mismatch between this constant and the migration means every live submit
  // fails CONFIG_VERSION_MISMATCH on the day the stubs are swapped for real
  // endpoints, and nothing in the demo would explain why.
  strictEqual(CONFIG_VERSION, "2026-08-30.1");
  submit(row(), evidence());
});

// ---------------------------------------------------------------------------
// Gate 7 — mocked location (I7)
// ---------------------------------------------------------------------------

test("checkSubmitGates · a mocked fix against a production session is 400", () => {
  // Defence in depth: mocked GPS was already refused at start, but the Evidence
  // carries its own location block and a production-board session must never
  // score one.
  rejects(
    () =>
      submit(row(), evidence({ location: { lat: LAT, lng: LNG, accuracyM: 8, isMocked: true } })),
    "MOCKED_LOCATION_REJECTED",
    400,
    "a mocked fix on the production board",
  );
});

test("checkSubmitGates · an unmocked fix passes on either board", () => {
  submit(row({ board: "production" }), evidence());
  submit(row({ board: "demo" }), evidence());
});

// ---------------------------------------------------------------------------
// Gates 8–9 — session context
// ---------------------------------------------------------------------------

test("checkSubmitGates · a spot mismatch is SESSION_CONTEXT_MISMATCH 409", () => {
  // Territory resolves from the SERVER-RECORDED start context, never from the
  // submitted location. Letting the Evidence pick the spot would make the spot
  // claim a client-controlled field.
  rejects(
    () => submit(row({ spot_id: null }), evidence({ spotId: "spot-gym-1" })),
    "SESSION_CONTEXT_MISMATCH",
    409,
    "evidence claims a spot the session did not open at",
  );
  rejects(
    () => submit(row({ spot_id: "spot-gym-1" }), evidence({ spotId: null })),
    "SESSION_CONTEXT_MISMATCH",
    409,
    "evidence drops a spot the session opened at",
  );
});

test("checkSubmitGates · matching spots pass, including both null", () => {
  submit(row({ spot_id: null }), evidence({ spotId: null }));
  submit(row({ spot_id: "spot-gym-1" }), evidence({ spotId: "spot-gym-1" }));
});

test("checkSubmitGates · drift beyond the match radius is SESSION_CONTEXT_MISMATCH 409", () => {
  strictEqual(CONTEXT_MATCH_RADIUS_M, 100, "the spot proximity radius, reused deliberately");
  // ~222 m north of the start fix.
  const far = evidence({ location: { lat: LAT + 0.002, lng: LNG, accuracyM: 8, isMocked: false } });
  ok(
    haversineM(LAT, LNG, LAT + 0.002, LNG) > CONTEXT_MATCH_RADIUS_M,
    "the test fix must be outside the radius",
  );
  const error = rejects(() => submit(row(), far), "SESSION_CONTEXT_MISMATCH", 409, "a drifted fix");
  ok(error.message.includes("m from the session-start fix"), "the message should say what drifted");
});

test("checkSubmitGates · ordinary GPS drift inside the radius passes", () => {
  // ~56 m. An athlete who walks out of frame mid-session, or a fix that settles
  // after the countdown, must still match — a radius tight enough to reject real
  // drift would reject the demo.
  const near = evidence({
    location: { lat: LAT + 0.0005, lng: LNG, accuracyM: 12, isMocked: false },
  });
  const drift = haversineM(LAT, LNG, LAT + 0.0005, LNG);
  ok(drift < CONTEXT_MATCH_RADIUS_M, `expected under 100 m, got ${drift.toFixed(1)}`);
  submit(row(), near);
});

test("checkSubmitGates · the spot check runs before the drift check", () => {
  // ORDER. Both fail here; the spot is named because it is the cheaper and more
  // definite comparison, and a distance computed against the wrong spot is
  // meaningless anyway.
  rejects(
    () =>
      submit(
        row({ spot_id: null }),
        evidence({
          spotId: "spot-gym-1",
          location: { lat: LAT + 0.05, lng: LNG, accuracyM: 8, isMocked: false },
        }),
      ),
    "SESSION_CONTEXT_MISMATCH",
    409,
    "wrong spot AND drifted",
  );
});

// ---------------------------------------------------------------------------
// Gate 10 — wall-clock containment (I3)
// ---------------------------------------------------------------------------

test("checkSubmitGates · a claimed timeline wider than the observed window is 400", () => {
  // The contract's own example: "A ten-minute workout submitted forty seconds
  // after the session opened is rejected."
  const e = evidence({ sets: [set(0, 600_000)] }); // claims ten minutes
  rejects(
    () => submit(row(), e, USER, START_MS + 40_000), // observed forty seconds
    "TIMELINE_OUT_OF_WINDOW",
    400,
    "ten claimed minutes inside forty observed seconds",
  );
});

test("checkSubmitGates · the wall clock runs last", () => {
  // ORDER, and structurally necessary: the check needs the submit stamp, which
  // the caller takes immediately before calling. Everything here is also
  // cheaper than a haversine, so running them first costs nothing.
  const r = row({ movement_config_version: "1999-01-01.1" });
  const e = evidence({ movementConfigVersion: CONFIG_VERSION, sets: [set(0, 600_000)] });
  rejects(
    () => submit(r, e, USER, START_MS + 40_000),
    "CONFIG_VERSION_MISMATCH",
    409,
    "bad config AND bad timeline",
  );
});

test("checkWallClock · the result is identical for any server start time", () => {
  // THE I3 PROPERTY. Evidence carries offsets from the client's own monotonic
  // t=0, so the comparison is duration-against-duration and the server's epoch
  // never meets a client value. Shifting the server clock by a century changes
  // nothing — which is exactly why a spoofed client epoch cannot help an
  // attacker: there is no client wall-clock value in the comparison to lie about.
  const sets = [set(0, 60_000), set(70_000, 130_000)];
  const results = [0, START_MS, Date.UTC(2126, 0, 1)].map((serverStartMs) =>
    checkWallClock(sets, serverStartMs, serverStartMs + 200_000)
  );
  deepStrictEqual(results[0], results[1]);
  deepStrictEqual(results[1], results[2]);
  strictEqual(results[0].ok, true);
});

test("checkWallClock · an epoch timestamp in a set offset is caught as out of window", () => {
  // The replay attack: a recorded payload resubmitted with its original absolute
  // timestamps. `startedAtMs` of 1.757e12 against a two-minute observed window
  // is a claimed span of fifty-five years, so it fails on the span check. The
  // parser accepts the number (a large offset is not a shape error) — rejecting
  // it is the gate's job, and this is why the two are separate layers.
  const e = evidence({ sets: [set(START_MS, START_MS + 60_000)] });
  const clock = checkWallClock(e.sets, START_MS, SUBMIT_MS);
  strictEqual(clock.ok, false);
  ok(clock.reason !== undefined && clock.reason.includes("claimed"), clock.reason);
  rejects(() => submit(row(), e), "TIMELINE_OUT_OF_WINDOW", 400, "a replayed absolute timestamp");
});

test("checkWallClock · slack absorbs clock asymmetry, and only that much", () => {
  strictEqual(WALLCLOCK_SLACK_MS, 5000);
  const sets = [set(0, 100_000)];
  const windowMs = 100_000 - WALLCLOCK_SLACK_MS;

  // Exactly at the slack: still honest, and rejecting it would fail a real
  // submission on a few hundred milliseconds of scheduling noise.
  strictEqual(checkWallClock(sets, START_MS, START_MS + windowMs).ok, true);
  // One past it: not.
  strictEqual(checkWallClock(sets, START_MS, START_MS + windowMs - 1).ok, false);
});

test("checkWallClock · a set starting before the session opened is caught", () => {
  // A negative offset beyond slack means the client's t=0 predates the server's
  // start stamp — either a bad monotonic base or a payload from another session.
  strictEqual(checkWallClock([set(-WALLCLOCK_SLACK_MS, 60_000)], START_MS, SUBMIT_MS).ok, true);
  const early = checkWallClock([set(-WALLCLOCK_SLACK_MS - 1, 60_000)], START_MS, SUBMIT_MS);
  strictEqual(early.ok, false);
  ok(
    early.reason !== undefined && early.reason.includes("before the session opened"),
    early.reason,
  );
});

test("checkWallClock · the span is the max over ALL sets, not the first", () => {
  // A multi-set session's sets are not necessarily in submission order in any
  // meaningful sense, and `Math.min`/`Math.max` over the whole list is what makes
  // the check independent of ordering. Using `sets[0]` would let a long set hide
  // behind a short first one.
  const sets = [set(0, 10_000), set(20_000, 200_000), set(30_000, 50_000)];
  const clock = checkWallClock(sets, START_MS, START_MS + 120_000);
  strictEqual(clock.claimedSpanMs, 200_000);
  strictEqual(clock.earliestStartMs, 0);
  strictEqual(clock.ok, false, "200 s claimed inside a 120 s observed window");
});

test("checkWallClock · an empty set list is trivially contained", () => {
  // parseEvidence rejects zero sets before this runs, but the function is pure
  // and callable on its own; `Math.max(...[])` is -Infinity, which would
  // otherwise make the containment check pass for the wrong reason.
  const clock = checkWallClock([], START_MS, SUBMIT_MS);
  strictEqual(clock.ok, true);
  strictEqual(clock.claimedSpanMs, 0);
  strictEqual(clock.observedWindowMs, 120_000);
});

test("checkWallClock · a negative observed window is refused rather than passing vacuously", () => {
  // Cannot happen with submit stamped on arrival, but if it did, every
  // containment comparison below would pass: any claimed span is inside a window
  // of negative length only if the check is inverted. An explicit guard beats
  // reasoning about that.
  const clock = checkWallClock([set(0, 1000)], SUBMIT_MS, START_MS);
  strictEqual(clock.ok, false);
  strictEqual(clock.reason, "server submit time precedes server start time");
});

test("checkWallClock · reports the observed window it used", () => {
  const clock = checkWallClock([set(0, 60_000)], START_MS, SUBMIT_MS);
  strictEqual(clock.observedWindowMs, 120_000);
  strictEqual(clock.claimedSpanMs, 60_000);
  strictEqual(clock.reason, undefined, "a passing check has no reason");
});

// ---------------------------------------------------------------------------
// utcDay — the daily budget key (I11)
// ---------------------------------------------------------------------------

test("utcDay · keys the daily counter in UTC, not local time", () => {
  // If this used the server's or the client's local zone the daily budget would
  // reset at a different instant for each athlete, and crossing a timezone
  // boundary would hand out a second budget in one day. UTC makes the reset
  // simultaneous for everyone.
  strictEqual(utcDay(0), "1970-01-01");
  strictEqual(utcDay(Date.UTC(2026, 8, 6, 23, 59, 59, 999)), "2026-09-06");
  strictEqual(utcDay(Date.UTC(2026, 8, 7, 0, 0, 0, 0)), "2026-09-07");
});

test("utcDay · is stable for every millisecond of one day", () => {
  const midnight = Date.UTC(2026, 8, 7);
  for (const offset of [0, 1, 43_200_000, 86_399_999]) {
    strictEqual(utcDay(midnight + offset), "2026-09-07", `offset ${offset}`);
  }
  strictEqual(utcDay(midnight + 86_400_000), "2026-09-08");
});

// ---------------------------------------------------------------------------
// checkStartGates — the gates that run before a session exists
// ---------------------------------------------------------------------------

test("checkStartGates · a clean start passes", () => {
  checkStartGates({ lat: LAT, lng: LNG, accuracyM: 8, isMocked: false }, false, null, START_MS);
});

test("checkStartGates · an out-of-range coordinate is MALFORMED_REQUEST 400", () => {
  // Range before plausibility: h3-js throws rather than wraps on an out-of-range
  // coordinate, and a NaN from a malformed fix would reach haversine first and
  // produce a nonsense distance instead of a clear error.
  for (
    const location of [
      { lat: 91, lng: LNG, accuracyM: 8, isMocked: false },
      { lat: -91, lng: LNG, accuracyM: 8, isMocked: false },
      { lat: LAT, lng: 181, accuracyM: 8, isMocked: false },
      { lat: LAT, lng: -181, accuracyM: 8, isMocked: false },
    ]
  ) {
    rejects(
      () => checkStartGates(location, false, null, START_MS),
      "MALFORMED_REQUEST",
      400,
      `coordinate ${location.lat}, ${location.lng}`,
    );
  }
  // The boundaries themselves are legal.
  checkStartGates({ lat: 90, lng: 180, accuracyM: 8, isMocked: false }, false, null, START_MS);
  checkStartGates({ lat: -90, lng: -180, accuracyM: 8, isMocked: false }, false, null, START_MS);
});

test("checkStartGates · a mocked fix is refused for a production account", () => {
  rejects(
    () =>
      checkStartGates({ lat: LAT, lng: LNG, accuracyM: 8, isMocked: true }, false, null, START_MS),
    "MOCKED_LOCATION_REJECTED",
    400,
    "a mocked fix from a non-demo account",
  );
});

test("checkStartGates · a demo account may present a mocked fix", () => {
  // J7, and note what the signature does NOT have: there is no way for the
  // REQUEST to ask for demo treatment. `isDemoAccount` comes from the server's own
  // allowlist lookup, so a production client cannot talk this gate into accepting
  // a spoofed coordinate by adding a field.
  checkStartGates({ lat: LAT, lng: LNG, accuracyM: 8, isMocked: true }, true, null, START_MS);
});

test("checkStartGates · accuracy beyond the D4 gate is refused", () => {
  strictEqual(MAX_GPS_ACCURACY_M, 50);
  checkStartGates(
    { lat: LAT, lng: LNG, accuracyM: MAX_GPS_ACCURACY_M, isMocked: false },
    false,
    null,
    START_MS,
  );
  const error = rejects(
    () =>
      checkStartGates(
        { lat: LAT, lng: LNG, accuracyM: 51, isMocked: false },
        false,
        null,
        START_MS,
      ),
    "GPS_TOO_INACCURATE",
    400,
    "a 51 m fix",
  );
  // The message tells the athlete what to DO, because this one is recoverable by
  // walking outside — unlike every other gate in this file.
  ok(error.message.includes("better sky view"), error.message);
});

test("checkStartGates · the mocked check precedes the accuracy check", () => {
  // ORDER. A mocked fix at 5000 m accuracy reports the mock, because a spoofed
  // coordinate is a deliberate act and a bad accuracy figure is a circumstance.
  rejects(
    () =>
      checkStartGates(
        { lat: LAT, lng: LNG, accuracyM: 5000, isMocked: true },
        false,
        null,
        START_MS,
      ),
    "MOCKED_LOCATION_REJECTED",
    400,
    "mocked AND inaccurate",
  );
});

test("checkStartGates · implied travel above the speed limit is IMPLAUSIBLE_TRAVEL", () => {
  // I7. London to New York in a minute.
  const previous = { lat: LAT, lng: LNG, atMs: START_MS - 60_000 };
  const error = rejects(
    () =>
      checkStartGates(
        { lat: 40.7128, lng: -74.006, accuracyM: 8, isMocked: false },
        false,
        previous,
        START_MS,
      ),
    "IMPLAUSIBLE_TRAVEL",
    400,
    "a transatlantic minute",
  );
  ok(error.message.includes("I7"), "the message should cite the invariant");
});

test("checkStartGates · a plausible previous session passes", () => {
  // Same place a minute later, which is the ordinary case: someone training twice
  // in one evening at the same park.
  checkStartGates(
    { lat: LAT, lng: LNG, accuracyM: 8, isMocked: false },
    false,
    { lat: LAT, lng: LNG, atMs: START_MS - 60_000 },
    START_MS,
  );
});

test("checkStartGates · travel is not checked when there is no previous session", () => {
  // A first-ever session has nothing to be implausible against. Requiring a
  // previous fix would make onboarding impossible.
  checkStartGates(
    { lat: 40.7128, lng: -74.006, accuracyM: 8, isMocked: false },
    false,
    null,
    START_MS,
  );
});

test("impliedTravel · a zero or negative interval is judged on distance alone", () => {
  // Two session events at the same instant in different places is exactly the
  // teleport I7 exists to catch, so `elapsedMs <= 0` must not become a division
  // by zero that yields Infinity and then compares true.
  strictEqual(MAX_TRAVEL_SPEED_KMH, 40);
  const samePlace = impliedTravel(LAT, LNG, LAT, LNG, 0);
  strictEqual(samePlace.ok, true);
  strictEqual(samePlace.speedKmh, null, "no interval, so no meaningful speed");

  const teleport = impliedTravel(LAT, LNG, LAT + 0.01, LNG, 0);
  strictEqual(teleport.ok, false);
  strictEqual(teleport.speedKmh, null);
});

test("impliedTravel · a short interval is judged on distance, a long one on speed", () => {
  // Under MIN_MEANINGFUL_ELAPSED_MS the speed estimate is dominated by GPS jitter
  // rather than movement: 10 m of drift in 5 s reads as 7.2 km/h, and rating that
  // against a 40 km/h limit would reject a phone sitting on a bench.
  const tenMetres = LAT + 10 / 111_195;
  const jittery = impliedTravel(LAT, LNG, tenMetres, LNG, 5_000);
  strictEqual(jittery.ok, true, "10 m of drift in 5 s is jitter, not travel");
  ok(jittery.speedKmh !== null && jittery.speedKmh > 0);

  // The same 10 m over an hour is still fine, and now rated on speed.
  strictEqual(impliedTravel(LAT, LNG, tenMetres, LNG, 3_600_000).ok, true);

  // A real journey over a long interval is rated on speed and passes: 40 km/h is
  // a cycle, not a car.
  const oneKm = LAT + 1000 / 111_195;
  const cycled = impliedTravel(LAT, LNG, oneKm, LNG, 5 * 60_000);
  strictEqual(cycled.ok, true);
  ok(
    cycled.speedKmh !== null && cycled.speedKmh <= MAX_TRAVEL_SPEED_KMH,
    `${cycled.speedKmh} km/h`,
  );
});

// ---------------------------------------------------------------------------
// parseStartRequest — the one request shape that is not Evidence
// ---------------------------------------------------------------------------

test("parseStartRequest · reads a well-formed body", () => {
  const parsed = parseStartRequest({
    location: { lat: LAT, lng: LNG, accuracyM: 8, isMocked: false },
    spotId: "spot-gym-1",
  });
  deepStrictEqual(parsed, {
    location: { lat: LAT, lng: LNG, accuracyM: 8, isMocked: false },
    spotId: "spot-gym-1",
  });
});

test("parseStartRequest · isMocked defaults to false, and only the boolean true counts", () => {
  // Making the field mandatory would turn an older build's request into a hard
  // failure for no security gain — the gate decides whether the value is
  // acceptable, not the parser.
  const omitted = parseStartRequest({ location: { lat: LAT, lng: LNG, accuracyM: 8 } });
  strictEqual(omitted.location.isMocked, false);

  // `=== true`, not truthiness: a string "true" or a 1 reads as false. That is
  // not a hole — `isMocked` is self-reported, so a forger sends `false` and no
  // parsing rule can catch them. The real defences are the accuracy, travel and
  // context checks, which do not depend on this field at all.
  for (const value of ["true", 1, null, {}, []]) {
    const parsed = parseStartRequest({
      location: { lat: LAT, lng: LNG, accuracyM: 8, isMocked: value },
    });
    strictEqual(parsed.location.isMocked, false, `isMocked: ${JSON.stringify(value)}`);
  }
});

test("parseStartRequest · spotId is null when absent, null, or an empty string", () => {
  strictEqual(parseStartRequest({ location: { lat: LAT, lng: LNG, accuracyM: 8 } }).spotId, null);
  strictEqual(
    parseStartRequest({ location: { lat: LAT, lng: LNG, accuracyM: 8 }, spotId: null }).spotId,
    null,
  );
  // An empty string is a client bug, not "no spot" — accepting it would create a
  // session bound to a spot id that matches nothing and never resolves.
  rejects(
    () => parseStartRequest({ location: { lat: LAT, lng: LNG, accuracyM: 8 }, spotId: "" }),
    "MALFORMED_REQUEST",
    400,
    "an empty spotId",
  );
  rejects(
    () => parseStartRequest({ location: { lat: LAT, lng: LNG, accuracyM: 8 }, spotId: 42 }),
    "MALFORMED_REQUEST",
    400,
    "a numeric spotId",
  );
});

test("parseStartRequest · rejects a body it cannot read", () => {
  for (const body of [null, undefined, 42, "start", [], true]) {
    rejects(
      () => parseStartRequest(body),
      "MALFORMED_REQUEST",
      400,
      `body ${JSON.stringify(body)}`,
    );
  }
  rejects(() => parseStartRequest({}), "MALFORMED_REQUEST", 400, "no location at all");
  rejects(() => parseStartRequest({ location: null }), "MALFORMED_REQUEST", 400, "a null location");
  rejects(
    () => parseStartRequest({ location: 42 }),
    "MALFORMED_REQUEST",
    400,
    "a numeric location",
  );
});

test("parseStartRequest · rejects a non-finite coordinate", () => {
  // NaN and Infinity both serialise to `null` in JSON, so what actually arrives
  // is a missing field — but a client constructing the body in memory can pass a
  // NaN straight through, and `haversineM` would return NaN, which fails every
  // comparison silently rather than loudly.
  for (const field of ["lat", "lng", "accuracyM"]) {
    for (const value of [Number.NaN, Infinity, "51.5", null]) {
      rejects(
        () => parseStartRequest({ location: { lat: LAT, lng: LNG, accuracyM: 8, [field]: value } }),
        "MALFORMED_REQUEST",
        400,
        `${field} = ${String(value)}`,
      );
    }
  }
});

test("parseStartRequest · the field name appears in the message", () => {
  // The client shows this to a developer with a console open on demo day.
  // "expected a finite number" alone does not say which of the three it was.
  const error = gateOf(
    () => parseStartRequest({ location: { lat: LAT, lng: "nope", accuracyM: 8 } }),
    "a string lng",
  );
  ok(error.message.includes("location.lng"), error.message);
});
