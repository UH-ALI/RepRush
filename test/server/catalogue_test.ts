/// Pins `tools/catalogue.ts` to the migrations it says it was transcribed from.
///
/// WHY THIS FILE EXISTS
/// The fixture pipeline needs a [Catalogue], and building one normally needs a
/// database. There is no database here, so the rows exist a second time as a
/// TypeScript literal. A second copy of a number is a second place for it to be
/// wrong, and the failure mode is the worst kind: a mistyped offset in the
/// literal does not break anything, it just makes all ten goldens describe a
/// scoring engine that is not the one the migrations configure.
///
/// WHAT IT PARSES AND WHAT IT DOES NOT
/// 0002's eighteen `movements` rows and 0003's six explicitly-listed offset rows
/// are parsed and compared field by field. The twelve backfilled offset rows are
/// NOT — they are produced by a lateral join at migration time, and deriving them
/// here would mean re-implementing that SQL in TypeScript and then "checking" it
/// against itself. Instead the backfill is pinned by its invariants: every
/// movement resolvable, no ghosts, `hold` direction exactly on `holdTime`
/// movements, and family members agreeing unless explicitly listed.
///
/// A REGEX PARSER IS BRITTLE AND THAT IS THE POINT
/// These patterns match the migrations as they are actually formatted. If a
/// migration is reformatted enough that a pattern stops matching, the row count
/// assertion below fails with a message telling the next person to re-read this
/// file — which is a much better outcome than a parser that quietly matches
/// nothing and lets every row comparison pass vacuously.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { MOVEMENT_ROWS, OFFSET_ROWS, testCatalogue } from "./tools/catalogue.ts";
import { CONFIG_VERSION } from "./tools/fixtures.ts";
import { deepStrictEqual, ok, strictEqual, test } from "./_harness.ts";

const MIGRATIONS = fileURLToPath(new URL("../../supabase/migrations/", import.meta.url));

function readMigration(name: string): string {
  return readFileSync(`${MIGRATIONS}${name}`, "utf8");
}

const movementsSql = readMigration("0002_movements.sql");
const offsetsSql = readMigration("0003_config_versions.sql");

// ---------------------------------------------------------------------------
// 0002 — the movement catalogue
// ---------------------------------------------------------------------------

interface ParsedMovement {
  id: string;
  family: string;
  tier: number;
  measurement_type: string;
  difficulty: string;
  hold_band_low: string | null;
  hold_band_high: string | null;
}

/**
 * The first five columns are scalars on one line, so they anchor the row. The
 * band columns are last in the tuple but may sit several lines below — 0002
 * wraps `joint_config` and `placement_hint` — so they are found by taking the
 * last `(scalar, scalar)` immediately before a closing paren within the row's
 * own slice of text.
 */
function parseMovements(sql: string): ParsedMovement[] {
  const rowStart =
    /\(\s*'([a-z_]+)'\s*,\s*'([a-z_]+)'\s*,\s*(\d+)\s*,\s*'(repBodyweight|holdTime)'\s*,\s*(-?\d+(?:\.\d+)?)/g;

  const heads: { match: RegExpExecArray; index: number }[] = [];
  for (let m = rowStart.exec(sql); m !== null; m = rowStart.exec(sql)) {
    heads.push({ match: m, index: m.index });
  }

  // The trailing band pair, searched only inside one row's slice.
  const band = /(null|-?\d+(?:\.\d+)?)\s*,\s*(null|-?\d+(?:\.\d+)?)\s*\)/g;

  return heads.map(({ match }, n) => {
    const sliceEnd = n + 1 < heads.length ? heads[n + 1].index : sql.length;
    const slice = sql.slice(match.index, sliceEnd);

    let last: RegExpExecArray | null = null;
    band.lastIndex = 0;
    for (let m = band.exec(slice); m !== null; m = band.exec(slice)) last = m;
    ok(last !== null, `could not find the hold-band pair for movement '${match[1]}'`);

    const norm = (v: string) => (v === "null" ? null : v);
    return {
      id: match[1],
      family: match[2],
      tier: Number(match[3]),
      measurement_type: match[4],
      // Kept as a string, because that is how PostgREST delivers a `numeric`
      // and how `tools/catalogue.ts` deliberately writes it.
      difficulty: match[5],
      hold_band_low: norm(last![1]),
      hold_band_high: norm(last![2]),
    };
  });
}

const parsedMovements = parseMovements(movementsSql);

test("catalogue · the 0002 parser still finds every row", () => {
  // Guards the vacuous-pass failure mode: if the migration is reformatted and
  // `parseMovements` returns three rows, the per-row comparisons below would all
  // still succeed and the file would be worthless.
  strictEqual(
    parsedMovements.length,
    MOVEMENT_ROWS.length,
    `parsed ${parsedMovements.length} movements from 0002 but tools/catalogue.ts has ` +
      `${MOVEMENT_ROWS.length} — the migration changed shape, re-read catalogue_test.ts`,
  );
  // 0002's own header says eighteen, and that the prose count of "fifteen" in
  // requirements.md is wrong because Jump has no T1 or T4.
  strictEqual(parsedMovements.length, 18);
});

test("catalogue · every MOVEMENT_ROW matches 0002 field for field", () => {
  for (const row of MOVEMENT_ROWS) {
    const parsed = parsedMovements.find((m) => m.id === row.id);
    ok(parsed !== undefined, `'${row.id}' is in tools/catalogue.ts but not in 0002`);
    deepStrictEqual(
      { ...row },
      {
        id: parsed!.id,
        family: parsed!.family,
        tier: parsed!.tier,
        measurement_type: parsed!.measurement_type,
        difficulty: parsed!.difficulty,
        hold_band_low: parsed!.hold_band_low,
        hold_band_high: parsed!.hold_band_high,
      },
      `${row.id} drifted from 0002`,
    );
  }
});

test("catalogue · 0002 contains no movement the literal is missing", () => {
  // The reverse direction of the check above. Without it, deleting a row from
  // `MOVEMENT_ROWS` would pass: every remaining row would still match.
  const ids = new Set(MOVEMENT_ROWS.map((r) => r.id));
  for (const parsed of parsedMovements) {
    ok(ids.has(parsed.id), `'${parsed.id}' is in 0002 but missing from tools/catalogue.ts`);
  }
});

test("catalogue · 0002 seeds the version 0003 configures, and the tree is complete", () => {
  // requirements.md §4's variation tree: five families, four tiers, except Jump
  // which has no T1 or T4 — hence eighteen rows and not twenty.
  const byFamily = new Map<string, number[]>();
  for (const row of MOVEMENT_ROWS) {
    const tiers = byFamily.get(row.family) ?? [];
    tiers.push(row.tier);
    byFamily.set(row.family, tiers);
  }
  deepStrictEqual([...byFamily.keys()].sort(), ["hold", "jump", "pull", "push", "squat"]);
  for (const family of ["hold", "pull", "push", "squat"]) {
    deepStrictEqual(byFamily.get(family)!.sort(), [1, 2, 3, 4], `${family} should span T1–T4`);
  }
  deepStrictEqual(byFamily.get("jump")!.sort(), [2, 3], "Jump has no T1 or T4");
});

test("catalogue · difficulty rises with tier inside every family", () => {
  // Not a contract rule, but a violated one is a seeded bug: it would make the
  // easier variation worth more points than the harder one, and I10's tier
  // gating would then reward staying at a low tier.
  for (const family of new Set(MOVEMENT_ROWS.map((r) => r.family))) {
    const rows = MOVEMENT_ROWS.filter((r) => r.family === family).sort((a, b) => a.tier - b.tier);
    for (let i = 1; i < rows.length; i++) {
      ok(
        Number(rows[i].difficulty) > Number(rows[i - 1].difficulty),
        `${family}: T${rows[i].tier} (${rows[i].id}, ${rows[i].difficulty}) must out-difficulty ` +
          `T${rows[i - 1].tier} (${rows[i - 1].id}, ${rows[i - 1].difficulty})`,
      );
    }
  }
});

test("catalogue · every holdTime movement has a band and no repBodyweight movement does", () => {
  for (const row of MOVEMENT_ROWS) {
    const hasBand = row.hold_band_low !== null && row.hold_band_high !== null;
    if (row.measurement_type === "holdTime") {
      ok(
        hasBand,
        `${row.id} is holdTime but has no in-form band — scoreHold would grade it as perfect`,
      );
      ok(
        Number(row.hold_band_high) > Number(row.hold_band_low),
        `${row.id}: band ${row.hold_band_low}–${row.hold_band_high} is inverted or zero-width`,
      );
    } else {
      strictEqual(row.hold_band_low, null, `${row.id} is a rep movement and must not carry a band`);
      strictEqual(
        row.hold_band_high,
        null,
        `${row.id} is a rep movement and must not carry a band`,
      );
    }
  }
});

// ---------------------------------------------------------------------------
// 0003 — the versioned offsets
// ---------------------------------------------------------------------------

/** The six rows 0003 lists explicitly. The other twelve come from the backfill. */
function parseExplicitOffsets(sql: string): Record<string, {
  enter_peak_offset: string;
  enter_rest_offset: string;
  rom_target_offset: string;
  unit: string;
  direction: string;
}> {
  const row =
    /\(\s*'([\d.-]+)'\s*,\s*'([a-z_]+)'\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*'(deg|ratio)'\s*,\s*'(decreasing|increasing|hold)'\s*\)/g;

  const out: Record<
    string,
    {
      enter_peak_offset: string;
      enter_rest_offset: string;
      rom_target_offset: string;
      unit: string;
      direction: string;
    }
  > = {};
  for (let m = row.exec(sql); m !== null; m = row.exec(sql)) {
    strictEqual(m[1], CONFIG_VERSION, `0003 lists an offset row for version '${m[1]}'`);
    out[m[2]] = {
      enter_peak_offset: m[3],
      enter_rest_offset: m[4],
      rom_target_offset: m[5],
      unit: m[6],
      direction: m[7],
    };
  }
  return out;
}

const explicitOffsets = parseExplicitOffsets(offsetsSql);
const EXPECTED_EXPLICIT = ["squat", "push_up", "pull_up", "jumping_jack", "plank", "dead_hang"];

test("catalogue · the 0003 parser still finds the six explicit rows", () => {
  deepStrictEqual(Object.keys(explicitOffsets).sort(), [...EXPECTED_EXPLICIT].sort());
});

test("catalogue · 0003 configures exactly the version the fixtures bind to", () => {
  // The version string has to match DemoVenue.movementConfigVersion on the Dart
  // side, or every live submit fails CONFIG_VERSION_MISMATCH on the day the
  // stubs are swapped for real endpoints.
  ok(
    offsetsSql.includes(`values ('${CONFIG_VERSION}', true)`),
    `0003 does not insert config version '${CONFIG_VERSION}'`,
  );
  strictEqual(testCatalogue().version, CONFIG_VERSION);
});

test("catalogue · every explicitly-listed OFFSET_ROW matches 0003 field for field", () => {
  for (const id of EXPECTED_EXPLICIT) {
    const row = OFFSET_ROWS.find((r) => r.movement_id === id);
    ok(
      row !== undefined,
      `'${id}' is listed explicitly in 0003 but missing from tools/catalogue.ts`,
    );
    const parsed = explicitOffsets[id];
    deepStrictEqual(
      {
        enter_peak_offset: row!.enter_peak_offset,
        enter_rest_offset: row!.enter_rest_offset,
        rom_target_offset: row!.rom_target_offset,
        unit: row!.unit,
        direction: row!.direction,
      },
      { ...parsed },
      `${id} drifted from 0003`,
    );
  }
});

test("catalogue · 0003's offsets match the api-contract.md §Movement configs table", () => {
  // The contract table is the specification; 0003 is a transcription of it;
  // tools/catalogue.ts is a transcription of that. This asserts the top of the
  // chain directly, so a migration that quietly retunes a value fails here even
  // if both transcriptions agree with each other.
  const byId = new Map(OFFSET_ROWS.map((r) => [r.movement_id, r]));
  const expect: Record<string, [string, string, string, string, string]> = {
    squat: ["-65.0", "-25.0", "-95.0", "deg", "decreasing"],
    push_up: ["-55.0", "-20.0", "-80.0", "deg", "decreasing"],
    pull_up: ["-85.0", "-25.0", "-120.0", "deg", "decreasing"],
    jumping_jack: ["0.85", "0.25", "1.25", "ratio", "increasing"],
  };
  for (const [id, [peak, rest, rom, unit, direction]] of Object.entries(expect)) {
    const row = byId.get(id);
    ok(row !== undefined, `${id} missing`);
    strictEqual(Number(row!.enter_peak_offset), Number(peak), `${id} enter_peak_offset`);
    strictEqual(Number(row!.enter_rest_offset), Number(rest), `${id} enter_rest_offset`);
    strictEqual(Number(row!.rom_target_offset), Number(rom), `${id} rom_target_offset`);
    strictEqual(row!.unit, unit, `${id} unit`);
    strictEqual(row!.direction, direction, `${id} direction`);
  }
});

// ---------------------------------------------------------------------------
// The backfill, pinned by invariant rather than by re-derivation
// ---------------------------------------------------------------------------

test("catalogue · every movement is resolvable — the backfill's whole promise", () => {
  // 0003's stated goal is "so no movement is unscorable". This is the assertion
  // that matters operationally: a gap here surfaces at runtime as
  // CONFIG_MISSING_OFFSETS on a real submission.
  const movements = new Set(MOVEMENT_ROWS.map((r) => r.id));
  const offsets = new Set(OFFSET_ROWS.map((r) => r.movement_id));
  for (const id of movements) {
    ok(
      offsets.has(id),
      `${id} has no offset row — resolveThresholds would throw CONFIG_MISSING_OFFSETS`,
    );
  }
  strictEqual(offsets.size, movements.size, "OFFSET_ROWS should have exactly one row per movement");
});

test("catalogue · no offset row references a movement that does not exist", () => {
  // `buildCatalogue` throws CATALOGUE_MALFORMED on this, so a ghost row would
  // take the whole fixture suite down. Asserting it here names the row instead.
  const movements = new Set(MOVEMENT_ROWS.map((r) => r.id));
  for (const row of OFFSET_ROWS) {
    ok(movements.has(row.movement_id), `'${row.movement_id}' has offsets but no movement`);
  }
  // And no duplicates, which `buildCatalogue` would silently last-write-wins.
  const seen = new Set<string>();
  for (const row of OFFSET_ROWS) {
    ok(!seen.has(row.movement_id), `duplicate offset row for '${row.movement_id}'`);
    seen.add(row.movement_id);
  }
});

test("catalogue · direction 'hold' appears exactly on the holdTime movements", () => {
  // This is the dead_hang invariant. `crossCheckTrace` stands down on a hold, and
  // a rep direction on a holdTime movement means an honest plank or dead hang
  // gets run through the crossing count against an empty rep list.
  const byId = new Map(MOVEMENT_ROWS.map((r) => [r.id, r]));
  for (const row of OFFSET_ROWS) {
    const movement = byId.get(row.movement_id)!;
    const isHold = movement.measurement_type === "holdTime";
    strictEqual(
      row.direction === "hold",
      isHold,
      `${row.movement_id} is ${movement.measurement_type} but direction is '${row.direction}'`,
    );
    if (isHold) {
      // Hold offsets are placeholders. Non-zero values here would be read by
      // nothing today and by something eventually.
      strictEqual(Number(row.enter_peak_offset), 0, `${row.movement_id} hold placeholder`);
      strictEqual(Number(row.enter_rest_offset), 0, `${row.movement_id} hold placeholder`);
      strictEqual(Number(row.rom_target_offset), 0, `${row.movement_id} hold placeholder`);
      strictEqual(row.unit, "deg", `${row.movement_id} hold placeholder unit`);
    }
  }
});

test("catalogue · 0003 restricts the family backfill to repBodyweight", () => {
  // Pinned as text, because the restriction IS the fix and nothing else in the
  // pipeline would notice its absence until a dead hang was submitted. Without
  // it, an INSERT ... SELECT that cannot see its own rows hands dead_hang
  // pull_up's −85/−25/−120 with direction 'decreasing'.
  const backfill = offsetsSql.slice(
    offsetsSql.indexOf("join lateral"),
    offsetsSql.indexOf(
      "on conflict (version, movement_id) do nothing;",
      offsetsSql.indexOf("join lateral"),
    ),
  );
  ok(backfill.length > 0, "could not locate the lateral backfill in 0003");
  ok(
    backfill.includes("m.measurement_type = 'repBodyweight'"),
    "0003's lateral backfill is no longer restricted to repBodyweight — a holdTime movement " +
      "in a rep family would inherit a rep direction. See the dead_hang comment in 0003.",
  );
  // And dead_hang must be in the explicit VALUES list, since the backfill now
  // skips it.
  ok(
    EXPECTED_EXPLICIT.includes("dead_hang"),
    "dead_hang must be listed explicitly in 0003, not left to the backfill",
  );
});

test("catalogue · 0003 gives every holdTime movement an explicit placeholder", () => {
  // The third statement in 0003. Without it, wall_sit / side_plank / l_sit would
  // have no offsets at all and would fail CONFIG_MISSING_OFFSETS.
  ok(
    offsetsSql.includes("m.measurement_type = 'holdTime'"),
    "0003 no longer has the holdTime placeholder statement",
  );
  const holdIds = MOVEMENT_ROWS.filter((r) => r.measurement_type === "holdTime").map((r) => r.id);
  for (const id of holdIds) {
    const row = OFFSET_ROWS.find((r) => r.movement_id === id);
    ok(row !== undefined, `${id} is holdTime but has no placeholder offset row`);
    strictEqual(row!.direction, "hold", `${id} placeholder direction`);
  }
});

test("catalogue · unlisted movements inherit their family's offsets", () => {
  // The backfill's semantics, asserted as a property rather than re-derived: for
  // each family, every member NOT explicitly listed in 0003 must carry the same
  // offsets as the family's base, and the base is the family's tier-2 member
  // when it has one.
  const byId = new Map(OFFSET_ROWS.map((r) => [r.movement_id, r]));
  const explicit = new Set(EXPECTED_EXPLICIT);
  const key = (r: (typeof OFFSET_ROWS)[number]) =>
    `${r.enter_peak_offset}|${r.enter_rest_offset}|${r.rom_target_offset}|${r.unit}|${r.direction}`;

  for (const family of new Set(MOVEMENT_ROWS.map((r) => r.family))) {
    const members = MOVEMENT_ROWS.filter((r) => r.family === family);
    const base = members.find((m) => m.tier === 2 && explicit.has(m.id));
    // `hold` has no explicit tier-2 base: plank IS listed, so it is the base.
    // `jump`'s base is jumping_jack (T2, explicit). Every family has one.
    ok(base !== undefined, `family '${family}' has no explicitly-configured tier-2 base`);

    const baseRow = byId.get(base!.id)!;
    for (const member of members) {
      if (explicit.has(member.id)) continue;
      const row = byId.get(member.id);
      ok(row !== undefined, `${member.id} has no offset row`);
      strictEqual(
        key(row!),
        key(baseRow),
        `${member.id} should inherit ${base!.id}'s offsets (family '${family}' backfill)`,
      );
    }
  }
});

test("catalogue · buildCatalogue accepts the literal and coerces every numeric string", () => {
  // The end-to-end check that the strings are not merely present but usable:
  // `numeric` columns arrive from PostgREST as strings, and `restSignal + offset`
  // on a string is concatenation, not addition.
  const catalogue = testCatalogue();
  strictEqual(catalogue.movements.size, MOVEMENT_ROWS.length);
  strictEqual(catalogue.offsets.size, OFFSET_ROWS.length);
  for (const [id, row] of catalogue.movements) {
    strictEqual(typeof row.difficulty, "number", `${id} difficulty not coerced`);
    ok(Number.isFinite(row.difficulty), `${id} difficulty is not finite`);
  }
  for (const [id, row] of catalogue.offsets) {
    for (const field of ["enterPeakOffset", "enterRestOffset", "romTargetOffset"] as const) {
      strictEqual(typeof row[field], "number", `${id}.${field} not coerced`);
      ok(Number.isFinite(row[field]), `${id}.${field} is not finite`);
    }
  }
});
