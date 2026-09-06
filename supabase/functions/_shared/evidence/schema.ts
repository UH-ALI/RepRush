/// Evidence schema — the parser for the single interface all three tracks meet
/// at (docs/api-contract.md §evidence, roles.md §4 Seam 1).
///
/// B owns this shape. It is the only place the wire format is described in code;
/// everything downstream consumes the typed result and never touches `unknown`.
///
/// Runtime-agnostic on purpose: no Deno APIs, explicit `.ts` import specifiers.
/// The same modules run under `deno test`, under the deployed Edge Function, and
/// under plain Node for fixture generation.
///
/// TIMESTAMP CONVENTION (load-bearing, and previously unstated in the contract):
/// every `*Ms` field in Evidence is milliseconds since the client's session
/// start on a monotonic clock — NOT epoch. The server never trusts a client
/// clock (I3); it compares claimed elapsed durations against its own observed
/// `serverSubmitMs - serverStartMs` window.

/** Trace tolerance unit — selects 15 degrees or 0.15 for ratio signals. */
export type Unit = "deg" | "ratio";

/** Which way "more extreme" runs. `hold` movements have no state machine. */
export type Direction = "decreasing" | "increasing" | "hold";

export type MeasurementType = "repBodyweight" | "holdTime";

export interface EvidenceLocation {
  lat: number;
  lng: number;
  accuracyM: number;
  isMocked: boolean;
}

/** How good the observation was. Feeds no score term today; stored for tuning. */
export interface EvidenceCapture {
  fpsMean: number;
  framesTotal: number;
  framesDropped: number;
  modelVariant: string;
}

/** From the 3-2-1 countdown. The only place raw pixels may legally appear. */
export interface EvidenceCalibration {
  torsoLengthPx: number;
  shoulderWidthPx: number;
  restSignal: number;
}

export interface EvidenceRep {
  i: number;
  tStartMs: number;
  tEndMs: number;
  restExtreme: number;
  peakExtreme: number;
  confMean: number;
  confMin: number;
  concentricMs?: number;
  eccentricMs?: number;
  /** B18 kip — normalised by shoulder width, never pixels. */
  hipDriftNorm?: number;
  /** B16 pull-up confirmation — normalised by torso length, never pixels. */
  shoulderWristDyNorm?: number;
}

export interface EvidenceHoldSegment {
  tStartMs: number;
  tEndMs: number;
  meanSignal: number;
  confMean: number;
}

/** I8 — the ~5 Hz downsample the trace cross-check runs against. */
export interface EvidenceTrace {
  hz: number;
  t0Ms: number;
  primary: number[];
  confMean: number[];
}

export interface EvidenceSet {
  movementId: string;
  measurementType: MeasurementType;
  startedAtMs: number;
  endedAtMs: number;
  capture: EvidenceCapture;
  calibration: EvidenceCalibration;
  reps: EvidenceRep[];
  holdSegments: EvidenceHoldSegment[];
  /**
   /// Absent until Track A ships the emitter. The scorer must not fail without
   /// it — a missing trace is an `info`-severity flag, not a rejection, so this
   /// backend is deployable before Seam 1 closes.
   */
  trace?: EvidenceTrace;
  /** Reconciliation only. Never trusted as a count (api-contract.md:219). */
  clientRepCount?: number;
}

export interface Evidence {
  sessionId: string;
  movementConfigVersion: string;
  clientVersion?: string;
  /** Day 6, I5. Carried, never validated in this slice. */
  attestationToken?: string;
  location: EvidenceLocation;
  spotId: string | null;
  sets: EvidenceSet[];
}

/** Raised for any shape violation. `pointer` is a JSON pointer into the payload. */
export class EvidenceError extends Error {
  readonly pointer: string;

  constructor(pointer: string, message: string) {
    super(`${pointer}: ${message}`);
    this.name = "EvidenceError";
    this.pointer = pointer;
  }
}

// Fields that must never appear anywhere in the payload. The client sends
// evidence and the server recomputes everything above the measurements (I1) —
// api-contract.md:211 says to reject a PR that adds one, so the parser does.
const FORBIDDEN_SCORE_FIELDS = new Set([
  "score",
  "repScore",
  "xp",
  "formFactor",
  "romScore",
  "tempoFactor",
  "points",
]);

// Pixels are legal in `calibration` and nowhere else (§The normalisation rule):
// the same kip is half the pixels from twice as far.
const PIXEL_FIELD = /Px$/;

const MAX_SETS = 50;
const MAX_REPS_PER_SET = 500;
const MAX_TRACE_SAMPLES = 4000;

function fail(pointer: string, message: string): never {
  throw new EvidenceError(pointer, message);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function record(value: unknown, pointer: string): Record<string, unknown> {
  if (!isRecord(value)) fail(pointer, "expected an object");
  return value;
}

function num(obj: Record<string, unknown>, key: string, pointer: string): number {
  const v = obj[key];
  if (typeof v !== "number" || !Number.isFinite(v)) {
    fail(`${pointer}/${key}`, "expected a finite number");
  }
  return v;
}

function optNum(
  obj: Record<string, unknown>,
  key: string,
  pointer: string,
): number | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    fail(`${pointer}/${key}`, "expected a finite number");
  }
  return v;
}

function int(obj: Record<string, unknown>, key: string, pointer: string): number {
  const v = num(obj, key, pointer);
  if (!Number.isInteger(v)) fail(`${pointer}/${key}`, "expected an integer");
  return v;
}

function optInt(
  obj: Record<string, unknown>,
  key: string,
  pointer: string,
): number | undefined {
  const v = optNum(obj, key, pointer);
  if (v === undefined) return undefined;
  if (!Number.isInteger(v)) fail(`${pointer}/${key}`, "expected an integer");
  return v;
}

function str(obj: Record<string, unknown>, key: string, pointer: string): string {
  const v = obj[key];
  if (typeof v !== "string" || v.length === 0) {
    fail(`${pointer}/${key}`, "expected a non-empty string");
  }
  return v;
}

function optStr(
  obj: Record<string, unknown>,
  key: string,
  pointer: string,
): string | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") fail(`${pointer}/${key}`, "expected a string");
  return v;
}

function bool(obj: Record<string, unknown>, key: string, pointer: string): boolean {
  const v = obj[key];
  if (typeof v !== "boolean") fail(`${pointer}/${key}`, "expected a boolean");
  return v;
}

function arr(value: unknown, pointer: string): unknown[] {
  if (!Array.isArray(value)) fail(pointer, "expected an array");
  return value;
}

function inRange(
  v: number,
  lo: number,
  hi: number,
  pointer: string,
): number {
  if (v < lo || v > hi) fail(pointer, `expected a value in [${lo}, ${hi}], got ${v}`);
  return v;
}

/** Recursive scan for fields the client is never allowed to send (I1). */
function assertNoScoreFields(value: unknown, pointer: string): void {
  if (Array.isArray(value)) {
    value.forEach((item, i) => assertNoScoreFields(item, `${pointer}/${i}`));
    return;
  }
  if (!isRecord(value)) return;
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN_SCORE_FIELDS.has(key)) {
      fail(`${pointer}/${key}`, "the client never sends a score — the server recomputes it (I1)");
    }
    assertNoScoreFields(child, `${pointer}/${key}`);
  }
}

function parseLocation(value: unknown, pointer: string): EvidenceLocation {
  const o = record(value, pointer);
  return {
    lat: inRange(num(o, "lat", pointer), -90, 90, `${pointer}/lat`),
    lng: inRange(num(o, "lng", pointer), -180, 180, `${pointer}/lng`),
    accuracyM: inRange(num(o, "accuracyM", pointer), 0, 1e6, `${pointer}/accuracyM`),
    // Optional on the wire: an absent flag is treated as "not mocked" and the
    // server's own travel/accuracy checks still apply.
    isMocked: o["isMocked"] === undefined ? false : bool(o, "isMocked", pointer),
  };
}

function parseCapture(value: unknown, pointer: string): EvidenceCapture {
  const o = record(value, pointer);
  return {
    fpsMean: inRange(num(o, "fpsMean", pointer), 0, 240, `${pointer}/fpsMean`),
    framesTotal: int(o, "framesTotal", pointer),
    framesDropped: int(o, "framesDropped", pointer),
    modelVariant: optStr(o, "modelVariant", pointer) ?? "base",
  };
}

function parseCalibration(
  value: unknown,
  pointer: string,
): EvidenceCalibration {
  const o = record(value, pointer);
  return {
    // Scale references for every *Norm field — must be positive or the
    // normalisation divides by zero.
    torsoLengthPx: inRange(num(o, "torsoLengthPx", pointer), 1, 1e5, `${pointer}/torsoLengthPx`),
    shoulderWidthPx: inRange(
      num(o, "shoulderWidthPx", pointer),
      1,
      1e5,
      `${pointer}/shoulderWidthPx`,
    ),
    restSignal: num(o, "restSignal", pointer),
  };
}

function parseRep(value: unknown, pointer: string): EvidenceRep {
  const o = record(value, pointer);

  // No pixel field may appear in a rep record (§The normalisation rule). Checked
  // here rather than in the recursive scan because calibration legitimately
  // carries *Px keys.
  for (const key of Object.keys(o)) {
    if (PIXEL_FIELD.test(key)) {
      fail(
        `${pointer}/${key}`,
        "raw pixels belong in calibration only — normalise against a scale reference",
      );
    }
  }

  const tStartMs = int(o, "tStartMs", pointer);
  const tEndMs = int(o, "tEndMs", pointer);
  if (tEndMs <= tStartMs) {
    fail(`${pointer}/tEndMs`, `must be after tStartMs (${tStartMs})`);
  }

  return {
    i: int(o, "i", pointer),
    tStartMs,
    tEndMs,
    restExtreme: num(o, "restExtreme", pointer),
    peakExtreme: num(o, "peakExtreme", pointer),
    confMean: inRange(num(o, "confMean", pointer), 0, 1, `${pointer}/confMean`),
    confMin: inRange(num(o, "confMin", pointer), 0, 1, `${pointer}/confMin`),
    concentricMs: optInt(o, "concentricMs", pointer),
    eccentricMs: optInt(o, "eccentricMs", pointer),
    hipDriftNorm: optNum(o, "hipDriftNorm", pointer),
    shoulderWristDyNorm: optNum(o, "shoulderWristDyNorm", pointer),
  };
}

function parseHoldSegment(value: unknown, pointer: string): EvidenceHoldSegment {
  const o = record(value, pointer);
  for (const key of Object.keys(o)) {
    if (PIXEL_FIELD.test(key)) {
      fail(
        `${pointer}/${key}`,
        "raw pixels belong in calibration only — normalise against a scale reference",
      );
    }
  }
  const tStartMs = int(o, "tStartMs", pointer);
  const tEndMs = int(o, "tEndMs", pointer);
  if (tEndMs <= tStartMs) {
    fail(`${pointer}/tEndMs`, `must be after tStartMs (${tStartMs})`);
  }
  return {
    tStartMs,
    tEndMs,
    meanSignal: num(o, "meanSignal", pointer),
    confMean: inRange(num(o, "confMean", pointer), 0, 1, `${pointer}/confMean`),
  };
}

function parseTrace(value: unknown, pointer: string): EvidenceTrace {
  const o = record(value, pointer);
  const hz = inRange(num(o, "hz", pointer), 0.1, 60, `${pointer}/hz`);
  const t0Ms = int(o, "t0Ms", pointer);
  const primary = arr(o["primary"], `${pointer}/primary`);
  const confMean = arr(o["confMean"], `${pointer}/confMean`);

  if (primary.length === 0) fail(`${pointer}/primary`, "trace must not be empty");
  if (primary.length !== confMean.length) {
    fail(
      `${pointer}/confMean`,
      `length ${confMean.length} does not match primary length ${primary.length}`,
    );
  }
  if (primary.length > MAX_TRACE_SAMPLES) {
    fail(`${pointer}/primary`, `more than ${MAX_TRACE_SAMPLES} samples`);
  }
  for (let k = 0; k < primary.length; k++) {
    const v = primary[k];
    if (typeof v !== "number" || !Number.isFinite(v)) {
      fail(`${pointer}/primary/${k}`, "expected a finite number");
    }
    const c = confMean[k];
    if (typeof c !== "number" || !Number.isFinite(c) || c < 0 || c > 1) {
      fail(`${pointer}/confMean/${k}`, "expected a confidence in [0, 1]");
    }
  }
  return {
    hz,
    t0Ms,
    primary: primary as number[],
    confMean: confMean as number[],
  };
}

function parseSet(value: unknown, pointer: string): EvidenceSet {
  const o = record(value, pointer);
  const movementId = str(o, "movementId", pointer);

  const measurementType = o["measurementType"];
  if (measurementType !== "repBodyweight" && measurementType !== "holdTime") {
    fail(`${pointer}/measurementType`, "expected 'repBodyweight' or 'holdTime'");
  }

  const startedAtMs = int(o, "startedAtMs", pointer);
  const endedAtMs = int(o, "endedAtMs", pointer);
  if (startedAtMs < 0) fail(`${pointer}/startedAtMs`, "must not be negative");
  if (endedAtMs <= startedAtMs) {
    fail(`${pointer}/endedAtMs`, `must be after startedAtMs (${startedAtMs})`);
  }

  const repsRaw = arr(o["reps"] ?? [], `${pointer}/reps`);
  const holdsRaw = arr(o["holdSegments"] ?? [], `${pointer}/holdSegments`);

  // The two measurement types are mutually exclusive: a rep set has no hold
  // segments and vice versa. Scoring both from one set would double-count.
  if (measurementType === "repBodyweight" && holdsRaw.length > 0) {
    fail(`${pointer}/holdSegments`, "a repBodyweight set must not carry hold segments");
  }
  if (measurementType === "holdTime" && repsRaw.length > 0) {
    fail(`${pointer}/reps`, "a holdTime set must not carry reps");
  }
  if (repsRaw.length > MAX_REPS_PER_SET) {
    fail(`${pointer}/reps`, `more than ${MAX_REPS_PER_SET} reps in one set`);
  }

  const reps = repsRaw.map((r, i) => parseRep(r, `${pointer}/reps/${i}`));
  const holdSegments = holdsRaw.map((s, i) => parseHoldSegment(s, `${pointer}/holdSegments/${i}`));

  // Reps must be ordered and non-overlapping. Checked here because the tempo
  // statistics and the wall-clock gate both assume it.
  for (let i = 1; i < reps.length; i++) {
    if (reps[i].tStartMs < reps[i - 1].tEndMs) {
      fail(`${pointer}/reps/${i}/tStartMs`, "reps overlap or are out of order");
    }
  }
  if (reps.length > 0) {
    if (reps[0].tStartMs < startedAtMs || reps[reps.length - 1].tEndMs > endedAtMs) {
      fail(`${pointer}/reps`, "rep timeline falls outside the set window");
    }
  }
  for (const s of holdSegments) {
    if (s.tStartMs < startedAtMs || s.tEndMs > endedAtMs) {
      fail(`${pointer}/holdSegments`, "hold segment falls outside the set window");
    }
  }

  const clientRepCount = optInt(o, "clientRepCount", pointer);
  if (clientRepCount !== undefined && clientRepCount < 0) {
    fail(`${pointer}/clientRepCount`, "must not be negative");
  }

  return {
    movementId,
    measurementType,
    startedAtMs,
    endedAtMs,
    capture: parseCapture(o["capture"], `${pointer}/capture`),
    calibration: parseCalibration(o["calibration"], `${pointer}/calibration`),
    reps,
    holdSegments,
    trace: o["trace"] === undefined || o["trace"] === null
      ? undefined
      : parseTrace(o["trace"], `${pointer}/trace`),
    clientRepCount,
  };
}

/**
 * Parses an untrusted request body into [Evidence], or throws [EvidenceError]
 * with a JSON pointer naming the offending field.
 *
 * Every check here is a shape check. Plausibility — whether the numbers could
 * describe a real human — lives in `_shared/validation/` and never rejects.
 */
export function parseEvidence(raw: unknown): Evidence {
  assertNoScoreFields(raw, "");
  const o = record(raw, "");

  const sessionId = str(o, "sessionId", "");
  const movementConfigVersion = str(o, "movementConfigVersion", "");

  // Null is a legal spotId (training anywhere in a hex, not at a spot).
  const spotRaw = o["spotId"];
  const spotId = spotRaw === undefined || spotRaw === null
    ? null
    : typeof spotRaw === "string" && spotRaw.length > 0
    ? spotRaw
    : fail("/spotId", "expected a non-empty string or null");

  const setsRaw = arr(o["sets"], "/sets");
  if (setsRaw.length === 0) fail("/sets", "a session must carry at least one set");
  if (setsRaw.length > MAX_SETS) fail("/sets", `more than ${MAX_SETS} sets in one session`);

  const sets = setsRaw.map((s, i) => parseSet(s, `/sets/${i}`));

  // One session id, one config version — a mixed session cannot be scored
  // against a single resolved threshold set.
  return {
    sessionId,
    movementConfigVersion,
    clientVersion: optStr(o, "clientVersion", ""),
    attestationToken: optStr(o, "attestationToken", ""),
    location: parseLocation(o["location"], "/location"),
    spotId,
    sets,
  };
}
