/// The movement catalogue as PostgREST would return it, transcribed from
/// `supabase/migrations/0002_movements.sql` and `0003_config_versions.sql`.
///
/// WHY A SECOND TRANSCRIPTION IS NOT REDUNDANT
/// The scorer needs a [Catalogue], and building one normally needs a database.
/// There is no database in the fixture pipeline — no Deno, no Docker — so the
/// rows have to exist as data somewhere. They exist here.
///
/// The obvious worry is that this drifts from the SQL. It is pinned:
/// `catalogue_test.ts` parses the two migrations with a targeted regex and
/// asserts every row below against them, and fails loudly if the SQL changes
/// shape enough that the parse is no longer trustworthy. So a tuned offset in a
/// new migration breaks a test instead of silently invalidating ten goldens.
///
/// NUMERICS ARE STRINGS ON PURPOSE
/// `movements.difficulty` and all three offset columns are `numeric`, and
/// supabase-js returns every `numeric` as a string. Writing them as strings here
/// means the fixture pipeline runs through `_shared/catalogue.ts`'s `num()`
/// coercion exactly as production does — if that coercion regresses, the goldens
/// move, rather than the fixtures quietly sidestepping the bug.

import {
  buildCatalogue,
  type MovementDbRow,
  type OffsetDbRow,
} from "../../../supabase/functions/_shared/catalogue.ts";
import type { Catalogue } from "../../../supabase/functions/_shared/evidence/thresholds.ts";
import { CONFIG_VERSION } from "./fixtures.ts";

/** 0002, all eighteen rows. `joint_config` and `placement_hint` are not read by
 *  the scorer, so they are absent from [MovementDbRow] and omitted here. */
export const MOVEMENT_ROWS: readonly MovementDbRow[] = [
  // Squat -------------------------------------------------------------------
  {
    id: "assisted_squat",
    family: "squat",
    tier: 1,
    measurement_type: "repBodyweight",
    difficulty: "0.7",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "squat",
    family: "squat",
    tier: 2,
    measurement_type: "repBodyweight",
    difficulty: "1.0",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "jump_squat",
    family: "squat",
    tier: 3,
    measurement_type: "repBodyweight",
    difficulty: "1.5",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "pistol_squat",
    family: "squat",
    tier: 4,
    measurement_type: "repBodyweight",
    difficulty: "2.4",
    hold_band_low: null,
    hold_band_high: null,
  },
  // Push --------------------------------------------------------------------
  {
    id: "knee_push_up",
    family: "push",
    tier: 1,
    measurement_type: "repBodyweight",
    difficulty: "0.7",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "push_up",
    family: "push",
    tier: 2,
    measurement_type: "repBodyweight",
    difficulty: "1.0",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "diamond_push_up",
    family: "push",
    tier: 3,
    measurement_type: "repBodyweight",
    difficulty: "1.4",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "archer_push_up",
    family: "push",
    tier: 4,
    measurement_type: "repBodyweight",
    difficulty: "2.0",
    hold_band_low: null,
    hold_band_high: null,
  },
  // Pull --------------------------------------------------------------------
  {
    id: "dead_hang",
    family: "pull",
    tier: 1,
    measurement_type: "holdTime",
    difficulty: "0.8",
    hold_band_low: "165",
    hold_band_high: "185",
  },
  {
    id: "pull_up",
    family: "pull",
    tier: 2,
    measurement_type: "repBodyweight",
    difficulty: "1.8",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "wide_grip_pull_up",
    family: "pull",
    tier: 3,
    measurement_type: "repBodyweight",
    difficulty: "2.2",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "muscle_up",
    family: "pull",
    tier: 4,
    measurement_type: "repBodyweight",
    difficulty: "3.0",
    hold_band_low: null,
    hold_band_high: null,
  },
  // Hold --------------------------------------------------------------------
  {
    id: "wall_sit",
    family: "hold",
    tier: 1,
    measurement_type: "holdTime",
    difficulty: "0.8",
    hold_band_low: "80",
    hold_band_high: "100",
  },
  {
    id: "plank",
    family: "hold",
    tier: 2,
    measurement_type: "holdTime",
    difficulty: "1.0",
    hold_band_low: "160",
    hold_band_high: "185",
  },
  {
    id: "side_plank",
    family: "hold",
    tier: 3,
    measurement_type: "holdTime",
    difficulty: "1.3",
    hold_band_low: "160",
    hold_band_high: "185",
  },
  {
    id: "l_sit",
    family: "hold",
    tier: 4,
    measurement_type: "holdTime",
    difficulty: "2.2",
    hold_band_low: "80",
    hold_band_high: "100",
  },
  // Jump --------------------------------------------------------------------
  {
    id: "jumping_jack",
    family: "jump",
    tier: 2,
    measurement_type: "repBodyweight",
    difficulty: "0.8",
    hold_band_low: null,
    hold_band_high: null,
  },
  {
    id: "burpee",
    family: "jump",
    tier: 3,
    measurement_type: "repBodyweight",
    difficulty: "2.2",
    hold_band_low: null,
    hold_band_high: null,
  },
];

/**
 * 0003: the six explicitly-listed rows, then the twelve the lateral join
 * backfills.
 *
 * `dead_hang` is listed explicitly rather than inherited. It is a holdTime
 * movement in the `pull` family, and an `INSERT ... SELECT` cannot see its own
 * rows, so the backfill would have handed it `pull_up`'s thresholds with
 * `direction: 'decreasing'` — a rep direction on a movement that has no rep state
 * machine. 0003 now restricts the backfill to `repBodyweight` and gives every
 * holdTime movement an explicit `direction: 'hold'` placeholder.
 *
 * The remaining backfill gives every unconfigured rep movement its family's
 * configured base — the tier-2 row if the family has one, else the lowest tier
 * that already has offsets. Written out explicitly rather than derived, because
 * deriving it here would mean re-implementing the SQL in TypeScript and then
 * "checking" that implementation against itself.
 *
 * Rows are grouped so the boundary between explicit and inherited is visible.
 */
export const OFFSET_ROWS: readonly OffsetDbRow[] = [
  // -- Listed explicitly in 0003 ---------------------------------------------
  // squat / push_up / pull_up / jumping_jack are api-contract.md's offset table;
  // plank and dead_hang are holdTime placeholders carrying direction 'hold'.
  {
    movement_id: "squat",
    enter_peak_offset: "-65.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-95.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "push_up",
    enter_peak_offset: "-55.0",
    enter_rest_offset: "-20.0",
    rom_target_offset: "-80.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "pull_up",
    enter_peak_offset: "-85.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-120.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "jumping_jack",
    enter_peak_offset: "0.85",
    enter_rest_offset: "0.25",
    rom_target_offset: "1.25",
    unit: "ratio",
    direction: "increasing",
  },
  {
    movement_id: "plank",
    enter_peak_offset: "0.0",
    enter_rest_offset: "0.0",
    rom_target_offset: "0.0",
    unit: "deg",
    direction: "hold",
  },
  {
    movement_id: "dead_hang",
    enter_peak_offset: "0.0",
    enter_rest_offset: "0.0",
    rom_target_offset: "0.0",
    unit: "deg",
    direction: "hold",
  },

  // -- Inherited from `squat` (family base = tier 2) --------------------------
  {
    movement_id: "assisted_squat",
    enter_peak_offset: "-65.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-95.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "jump_squat",
    enter_peak_offset: "-65.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-95.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "pistol_squat",
    enter_peak_offset: "-65.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-95.0",
    unit: "deg",
    direction: "decreasing",
  },

  // -- Inherited from `push_up` ----------------------------------------------
  {
    movement_id: "knee_push_up",
    enter_peak_offset: "-55.0",
    enter_rest_offset: "-20.0",
    rom_target_offset: "-80.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "diamond_push_up",
    enter_peak_offset: "-55.0",
    enter_rest_offset: "-20.0",
    rom_target_offset: "-80.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "archer_push_up",
    enter_peak_offset: "-55.0",
    enter_rest_offset: "-20.0",
    rom_target_offset: "-80.0",
    unit: "deg",
    direction: "decreasing",
  },

  // -- Inherited from `pull_up`: the lateral join orders by (tier = 2) desc, so
  //    pull_up is the family base for every other rep movement in `pull`.
  {
    movement_id: "wide_grip_pull_up",
    enter_peak_offset: "-85.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-120.0",
    unit: "deg",
    direction: "decreasing",
  },
  {
    movement_id: "muscle_up",
    enter_peak_offset: "-85.0",
    enter_rest_offset: "-25.0",
    rom_target_offset: "-120.0",
    unit: "deg",
    direction: "decreasing",
  },

  // -- Hold placeholders for the rest of the `hold` family, inherited from
  //    `plank`. Hold mechanics ignore offsets entirely; these exist so the
  //    resolve step never finds a missing row and so the trace cross-check knows
  //    to stand down.
  {
    movement_id: "wall_sit",
    enter_peak_offset: "0.0",
    enter_rest_offset: "0.0",
    rom_target_offset: "0.0",
    unit: "deg",
    direction: "hold",
  },
  {
    movement_id: "side_plank",
    enter_peak_offset: "0.0",
    enter_rest_offset: "0.0",
    rom_target_offset: "0.0",
    unit: "deg",
    direction: "hold",
  },
  {
    movement_id: "l_sit",
    enter_peak_offset: "0.0",
    enter_rest_offset: "0.0",
    rom_target_offset: "0.0",
    unit: "deg",
    direction: "hold",
  },

  // -- Inherited from `jumping_jack` -----------------------------------------
  {
    movement_id: "burpee",
    enter_peak_offset: "0.85",
    enter_rest_offset: "0.25",
    rom_target_offset: "1.25",
    unit: "ratio",
    direction: "increasing",
  },
];

/** The catalogue every fixture is scored against. */
export function testCatalogue(): Catalogue {
  return buildCatalogue(CONFIG_VERSION, MOVEMENT_ROWS, OFFSET_ROWS);
}
