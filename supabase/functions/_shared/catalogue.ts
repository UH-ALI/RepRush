/// Turns database rows into the [Catalogue] the scorer consumes.
///
/// Split from the query on purpose: `_shared/repo.ts` owns SQL and needs Deno,
/// this file owns shape coercion and is pure, so the golden-fixture suite can
/// build a catalogue from a literal object instead of a database.
///
/// The coercion matters more than it looks. `movements.difficulty` is `numeric`,
/// and supabase-js returns every `numeric` as a **string** — so an uncoerced row
/// would put `"1.0" * 12` into the scoring formula and silently produce the right
/// answer in JS while failing every type check. Everything numeric is funnelled
/// through [num] here, once.

import type { Direction, Evidence, MeasurementType, Unit } from "./evidence/schema.ts";
import {
  type Catalogue,
  CatalogueError,
  type MovementRow,
  type OffsetRow,
} from "./evidence/thresholds.ts";

/** A `movements` row as PostgREST returns it. */
export interface MovementDbRow {
  id: string;
  family: string;
  tier: number;
  measurement_type: string;
  difficulty: number | string;
  hold_band_low: number | string | null;
  hold_band_high: number | string | null;
}

/** A `movement_config_offsets` row as PostgREST returns it. */
export interface OffsetDbRow {
  movement_id: string;
  enter_peak_offset: number | string;
  enter_rest_offset: number | string;
  rom_target_offset: number | string;
  unit: string;
  direction: string;
}

/**
 * Coerces a PostgREST numeric. `numeric` columns arrive as strings and
 * `double precision` columns as numbers; both are legal inputs here.
 */
export function num(value: number | string | null | undefined, field: string): number {
  if (value === null || value === undefined) {
    throw new CatalogueError("CATALOGUE_MALFORMED", `${field} is null`);
  }
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) {
    throw new CatalogueError("CATALOGUE_MALFORMED", `${field} is not a finite number: ${value}`);
  }
  return n;
}

function measurementType(raw: string, id: string): MeasurementType {
  if (raw === "repBodyweight" || raw === "holdTime") return raw;
  throw new CatalogueError(
    "CATALOGUE_MALFORMED",
    `movement '${id}' has measurement_type '${raw}'`,
  );
}

function unit(raw: string, id: string): Unit {
  if (raw === "deg" || raw === "ratio") return raw;
  throw new CatalogueError("CATALOGUE_MALFORMED", `offsets for '${id}' have unit '${raw}'`);
}

function direction(raw: string, id: string): Direction {
  if (raw === "decreasing" || raw === "increasing" || raw === "hold") return raw;
  throw new CatalogueError(
    "CATALOGUE_MALFORMED",
    `offsets for '${id}' have direction '${raw}'`,
  );
}

export function toMovementRow(row: MovementDbRow): MovementRow {
  const low = row.hold_band_low === null ? null : num(row.hold_band_low, `${row.id}.hold_band_low`);
  const high = row.hold_band_high === null
    ? null
    : num(row.hold_band_high, `${row.id}.hold_band_high`);
  return {
    id: row.id,
    family: row.family,
    tier: num(row.tier, `${row.id}.tier`),
    measurementType: measurementType(row.measurement_type, row.id),
    difficulty: num(row.difficulty, `${row.id}.difficulty`),
    holdBandLow: low,
    holdBandHigh: high,
  };
}

export function toOffsetRow(row: OffsetDbRow): OffsetRow {
  return {
    movementId: row.movement_id,
    enterPeakOffset: num(row.enter_peak_offset, `${row.movement_id}.enter_peak_offset`),
    enterRestOffset: num(row.enter_rest_offset, `${row.movement_id}.enter_rest_offset`),
    romTargetOffset: num(row.rom_target_offset, `${row.movement_id}.rom_target_offset`),
    unit: unit(row.unit, row.movement_id),
    direction: direction(row.direction, row.movement_id),
  };
}

/** Assembles the catalogue. `version` is the one bound to the session. */
export function buildCatalogue(
  version: string,
  movements: readonly MovementDbRow[],
  offsets: readonly OffsetDbRow[],
): Catalogue {
  const movementMap = new Map<string, MovementRow>();
  for (const row of movements) movementMap.set(row.id, toMovementRow(row));

  const offsetMap = new Map<string, OffsetRow>();
  for (const row of offsets) {
    if (!movementMap.has(row.movement_id)) {
      // An offset for a movement that does not exist is a migration bug. Fail
      // here rather than carrying a row the scorer can never reach.
      throw new CatalogueError(
        "CATALOGUE_MALFORMED",
        `offsets reference unknown movement '${row.movement_id}'`,
      );
    }
    offsetMap.set(row.movement_id, toOffsetRow(row));
  }

  return { version, movements: movementMap, offsets: offsetMap };
}

/**
 * Pre-flight check that every set in the payload can be resolved.
 *
 * This runs BEFORE the session is consumed. Without it, an unknown movement id
 * would throw out of [scoreEvidence] after the one-shot flip, burning the
 * athlete's session on a payload that was never going to score — the exact
 * failure mode I13 exists to avoid.
 */
export function assertResolvable(catalogue: Catalogue, evidence: Evidence): void {
  for (const set of evidence.sets) {
    if (!catalogue.movements.has(set.movementId)) {
      throw new CatalogueError(
        "UNKNOWN_MOVEMENT",
        `no movement '${set.movementId}' in the catalogue`,
      );
    }
    if (!catalogue.offsets.has(set.movementId)) {
      // Distinct code: this is a seeding gap on our side, not a bad payload.
      // 0003 backfills every movement, so reaching this means a new movement
      // was added without offsets.
      throw new CatalogueError(
        "CONFIG_MISSING_OFFSETS",
        `movement '${set.movementId}' has no offsets in config version '${catalogue.version}'`,
      );
    }
    const movement = catalogue.movements.get(set.movementId)!;
    if (movement.measurementType !== set.measurementType) {
      throw new CatalogueError(
        "MEASUREMENT_TYPE_MISMATCH",
        `movement '${set.movementId}' is ${movement.measurementType} but the set claims ` +
          `${set.measurementType}`,
      );
    }
  }
}
