-- Versioned threshold offsets (api-contract.md §Versioned calibration).
--
-- The version string MUST match DemoVenue.movementConfigVersion in
-- lib/core/api/stub/stub_repositories.dart so the client stub and the server
-- agree on the day the repositories are swapped from stub to live.
--
-- Offsets are applied to each set's own calibration.restSignal:
--     threshold = restSignal + offset
-- They are never absolute angles (A-19). A tuned set is a NEW version row with
-- active = true, never an edit of this one — the partial unique index in
-- 0001_core.sql guarantees only one version is active at a time.

-- The five v1 movements, verbatim from the api-contract.md offset table, plus
-- dead_hang. These are Day-2 starting values: A owns the numbers and reports
-- tuned values back, which becomes version 2026-08-30.2.
--
-- dead_hang is NOT in the contract's table, and it must be listed here rather
-- than left to the backfill below. It is a holdTime movement sitting in the
-- `pull` family, and the backfill inherits the family's configured base — which
-- for `pull` is pull_up, a repBodyweight movement with direction 'decreasing'.
-- An INSERT ... SELECT cannot see its own rows, so the backfill would hand
-- dead_hang real rep thresholds and a rep direction. `_shared/validation/trace.ts`
-- keys its "holds have no state machine" bail-out off that direction, so an
-- honest dead hang with a trace would be run through the rep-shaped cross-check
-- against an empty rep list and come out with a fabricated
-- TRACE_REP_COUNT_DIVERGENT contradiction. Tier 1, unlocked at signup, very
-- likely in the demo.
insert into movement_config_versions (version, active)
values ('2026-08-30.1', true)
on conflict (version) do update set active = true;

insert into movement_config_offsets
  (version, movement_id, enter_peak_offset, enter_rest_offset, rom_target_offset, unit, direction)
values
  ('2026-08-30.1', 'squat',        -65.0, -25.0,  -95.0, 'deg', 'decreasing'),
  ('2026-08-30.1', 'push_up',      -55.0, -20.0,  -80.0, 'deg', 'decreasing'),
  ('2026-08-30.1', 'pull_up',      -85.0, -25.0, -120.0, 'deg', 'decreasing'),
  ('2026-08-30.1', 'jumping_jack',  0.85,  0.25,   1.25, 'ratio', 'increasing'),
  -- Hold mechanics have no state machine and no offsets: the in-form band lives
  -- on movements.hold_band_low/high and accrual is a per-frame predicate. The
  -- zeros here are placeholders so the resolve step never finds a missing row,
  -- and direction 'hold' is what tells the trace cross-check to stand down.
  ('2026-08-30.1', 'plank',         0.0,   0.0,    0.0,  'deg', 'hold'),
  ('2026-08-30.1', 'dead_hang',     0.0,   0.0,    0.0,  'deg', 'hold')
on conflict (version, movement_id) do nothing;

-- Everything above T2 in the tree is "content, not engineering" — each is a
-- joint-angle config on machinery that already exists (requirements.md §4).
-- Until A supplies real numbers, each inherits its family's configured base
-- movement so no movement is unscorable. A replaces these rows; nobody scores
-- a T3/T4 movement in the demo without 50 verified reps behind the unlock
-- anyway (I10).
--
-- Restricted to repBodyweight. Inheriting a family base only means anything for a
-- movement that has a rep state machine to configure; for a holdTime movement it
-- would copy a `direction` that contradicts its measurement type (dead_hang,
-- above). Hold movements get explicit placeholder rows in the next statement
-- instead, so a new holdTime movement added without one fails
-- CONFIG_MISSING_OFFSETS loudly rather than silently inheriting rep semantics.
insert into movement_config_offsets
  (version, movement_id, enter_peak_offset, enter_rest_offset, rom_target_offset, unit, direction)
select
  v.version,
  m.id,
  base.enter_peak_offset,
  base.enter_rest_offset,
  base.rom_target_offset,
  base.unit,
  base.direction
from movements m
cross join movement_config_versions v
join lateral (
  -- The family's configured base: its T2 row if one exists, else any row in the
  -- family that already has offsets in this version.
  select o.enter_peak_offset, o.enter_rest_offset, o.rom_target_offset, o.unit, o.direction
  from movements b
  join movement_config_offsets o
    on o.movement_id = b.id and o.version = v.version
  where b.family = m.family
  order by (b.tier = 2) desc, b.tier asc
  limit 1
) base on true
where v.version = '2026-08-30.1'
  and m.measurement_type = 'repBodyweight'
  and not exists (
    select 1 from movement_config_offsets e
    where e.version = v.version and e.movement_id = m.id
  )
on conflict (version, movement_id) do nothing;

-- Every holdTime movement not already listed above: placeholder offsets with
-- direction 'hold', so `resolveThresholds` always finds a row and the trace
-- cross-check always knows to stand down. Their real gate is the in-form band on
-- movements.hold_band_low/high, which is a movement property and not versioned.
insert into movement_config_offsets
  (version, movement_id, enter_peak_offset, enter_rest_offset, rom_target_offset, unit, direction)
select v.version, m.id, 0.0, 0.0, 0.0, 'deg', 'hold'
from movements m
cross join movement_config_versions v
where v.version = '2026-08-30.1'
  and m.measurement_type = 'holdTime'
  and not exists (
    select 1 from movement_config_offsets e
    where e.version = v.version and e.movement_id = m.id
  )
on conflict (version, movement_id) do nothing;
