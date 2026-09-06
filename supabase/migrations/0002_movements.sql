-- Movement catalogue (B-4) — seeded from the requirements.md §4 variation tree,
-- then FROZEN. Changing a difficulty multiplier after Day 1 needs standup
-- (roles.md §5).
--
-- Ownership split on this table: B owns id / family / tier / difficulty; A owns
-- joint_config, which is why only the five v1 movements have one populated.
-- A's tuned configs land as updates to that column alone.
--
-- Note the count: docs/requirements.md and backend-scaffolding.md §4 both say
-- "fifteen movements", but the §4 variation tree as tabled has eighteen rows
-- (Jump has no T1 or T4). All eighteen are seeded — the tree is the source of
-- truth, not the prose count.

insert into movements
  (id, family, tier, measurement_type, difficulty, joint_config, placement_hint,
   hold_band_low, hold_band_high)
values
  -- Squat -------------------------------------------------------------------
  ('assisted_squat', 'squat', 1, 'repBodyweight', 0.7, '{}'::jsonb,
   'Phone on the floor, side view, 2 m back. Hold a doorframe for balance.',
   null, null),
  ('squat', 'squat', 2, 'repBodyweight', 1.0,
   '{"primary":"knee_angle","joints":["hip","knee","ankle"],"restApprox":175,"confirming":"hip_height_over_torso_length"}'::jsonb,
   'Phone on the floor, side view, 2 m back. Whole body in frame.',
   null, null),
  ('jump_squat', 'squat', 3, 'repBodyweight', 1.5, '{}'::jsonb,
   'Phone on the floor, side view, 2.5 m back — leave headroom for the jump.',
   null, null),
  ('pistol_squat', 'squat', 4, 'repBodyweight', 2.4, '{}'::jsonb,
   'Phone on the floor, side view, 2 m back.',
   null, null),

  -- Push --------------------------------------------------------------------
  ('knee_push_up', 'push', 1, 'repBodyweight', 0.7, '{}'::jsonb,
   'Phone side-on at floor level, 2 m back.',
   null, null),
  ('push_up', 'push', 2, 'repBodyweight', 1.0,
   '{"primary":"elbow_angle","joints":["shoulder","elbow","wrist"],"restApprox":165,"confirming":"torso_straight_160_to_185"}'::jsonb,
   'Phone side-on at floor level, 2 m back. The far arm is occluded — the '
   'pipeline takes the higher-confidence side per frame.',
   null, null),
  ('diamond_push_up', 'push', 3, 'repBodyweight', 1.4, '{}'::jsonb,
   'Phone side-on at floor level, 2 m back.',
   null, null),
  ('archer_push_up', 'push', 4, 'repBodyweight', 2.0, '{}'::jsonb,
   'Phone side-on at floor level, 2.5 m back.',
   null, null),

  -- Pull --------------------------------------------------------------------
  -- Dead hang is a holdTime movement: the bar is never detected, the wrists are.
  ('dead_hang', 'pull', 1, 'holdTime', 0.8,
   '{"primary":"elbow_angle","joints":["shoulder","elbow","wrist"],"restApprox":175}'::jsonb,
   'Phone 3 m back, raised toward chest height. A steep upward angle from the '
   'floor compresses the vertical axis (B17).',
   165, 185),
  ('pull_up', 'pull', 2, 'repBodyweight', 1.8,
   '{"primary":"elbow_angle","joints":["shoulder","elbow","wrist"],"restApprox":175,"confirming":"shoulder_wrist_dy_norm_below_0.25"}'::jsonb,
   'Phone 3 m back, raised toward chest height, full body in frame (B17). A '
   'steep upward angle from the floor compresses the vertical axis.',
   null, null),
  ('wide_grip_pull_up', 'pull', 3, 'repBodyweight', 2.2, '{}'::jsonb,
   'Phone 3 m back, raised toward chest height.',
   null, null),
  ('muscle_up', 'pull', 4, 'repBodyweight', 3.0, '{}'::jsonb,
   'Phone 3 m back, raised toward chest height.',
   null, null),

  -- Hold --------------------------------------------------------------------
  ('wall_sit', 'hold', 1, 'holdTime', 0.8,
   '{"primary":"knee_angle","joints":["hip","knee","ankle"],"restApprox":175}'::jsonb,
   'Phone side-on, 2 m back. Back against the wall, thighs parallel to floor.',
   80, 100),
  ('plank', 'hold', 2, 'holdTime', 1.0,
   '{"primary":"trunk_angle","joints":["shoulder","hip","ankle"],"restApprox":178}'::jsonb,
   'Phone side-on at floor level, 2.5 m back. The timer only runs while the '
   'trunk stays inside 160–185 degrees.',
   160, 185),
  ('side_plank', 'hold', 3, 'holdTime', 1.3, '{}'::jsonb,
   'Phone side-on at floor level, 2.5 m back.',
   160, 185),
  ('l_sit', 'hold', 4, 'holdTime', 2.2,
   '{"primary":"hip_angle","joints":["shoulder","hip","ankle"],"restApprox":170}'::jsonb,
   'Phone side-on, 2 m back. Hips at roughly 90 degrees.',
   80, 100),

  -- Jump --------------------------------------------------------------------
  ('jumping_jack', 'jump', 2, 'repBodyweight', 0.8,
   '{"primary":"ankle_sep_norm","joints":["ankle","shoulder"],"restApprox":0.35,"confirming":"wrists_above_shoulder_line"}'::jsonb,
   'Phone front-on, 2.5 m back, whole body in frame including both wrists at '
   'the top of the jack.',
   null, null),
  ('burpee', 'jump', 3, 'repBodyweight', 2.2, '{}'::jsonb,
   'Phone side-on, 3 m back — the movement covers a lot of floor.',
   null, null)
on conflict (id) do nothing;
