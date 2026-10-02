-- Nearby play — opt-in presence and duels (POST /presence, /duels/*).
--
-- PRESENCE IS A HEX, NEVER A FIX (N7). A heartbeat carries a GPS fix, the
-- `presence` function resolves it to a res-8 cell, and only the cell is written.
-- One row per athlete, overwritten by each heartbeat: there is no history to
-- leak, and a row older than the TTL in `_shared/presence.ts` is simply ignored
-- by every read, so going quiet is going invisible with no cleanup job. Turning
-- visibility off deletes the row outright.
--
-- DUELS STORE THE CHOICES, DERIVE THE SCORE. Who challenged whom, in what, and
-- when it was answered are facts only the athletes can supply, so they are
-- stored. Each side's reps are NOT: they are read from `duel_sets` (below) —
-- scored sets in submitted sessions — exactly as the daily challenge reads
-- `user_daily_movement_reps` (0008). Voiding a session drops its set out of the
-- duel with no correction step. "Active", "expired" and "finished" are likewise
-- derived from the clock on read, never written.
--
-- XP, NOT POWER. A duel reward is a `challenge_claims` row keyed `duel-<id>`,
-- which `GET /me` and session-submit's level maths already add up. Nothing here
-- is read by territory (structural rule 4).
--
-- RLS: enabled, no policies — the service role behind the functions is the only
-- reader and writer, as everywhere else (0001).

create table player_presence (
  user_id    uuid primary key references profiles (id) on delete cascade,
  board      text not null check (board in ('production', 'demo')),
  h3         text not null,
  updated_at timestamptz not null default now()
);

create index player_presence_board_h3_idx on player_presence (board, h3);

alter table player_presence enable row level security;

create table duels (
  id            uuid primary key default gen_random_uuid(),
  -- Both athletes are on the caller's board when it is created (J7): a demo
  -- account can never duel a production one.
  board         text not null check (board in ('production', 'demo')),
  challenger_id uuid not null references profiles (id) on delete cascade,
  opponent_id   uuid not null references profiles (id) on delete cascade,
  movement_id   text not null references movements (id),
  -- Only the answer is stored; expiry and the finish are clock-derived.
  status        text not null default 'pending'
                check (status in ('pending', 'accepted', 'declined')),
  created_at    timestamptz not null default now(),
  -- Fixed when the row is written, so retuning the windows mid-duel cannot
  -- move a running duel's goalposts.
  respond_by    timestamptz not null,
  accepted_at   timestamptz,
  ends_at       timestamptz,
  check (challenger_id <> opponent_id),
  check ((status = 'accepted') = (accepted_at is not null and ends_at is not null))
);

create index duels_challenger_idx on duels (challenger_id, created_at desc);
create index duels_opponent_idx on duels (opponent_id, created_at desc);

alter table duels enable row level security;

-- Scored sets with the submit instant and board of their session — what a duel
-- counts. The submit time is the server's clock (I3), so a set cannot be dated
-- into or out of a duel window by the client.
create view duel_sets
with (security_invoker = true) as
  select s.user_id,
         s.board,
         r.movement_id,
         r.rep_count,
         s.submitted_at_ms
  from set_records r
  join workout_sessions s on s.id = r.session_id
  where s.status = 'submitted'
    and s.submitted_at_ms is not null
    and r.scored;

revoke all on duel_sets from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Demo reset (0006, 0008) — presence and duels are session-adjacent state too
-- ---------------------------------------------------------------------------

-- Same wrapping as 0008: rename the current entry points and wrap them, so
-- `tool/reset_demo.ts` keeps calling the same names. Duel claims live in
-- challenge_claims, which the 0008 wrapper already clears.

alter function reset_user_data(uuid) rename to reset_user_data_0008;
alter function reset_all_data() rename to reset_all_data_0008;

create function reset_user_data(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_duels integer := 0;
begin
  v_result := reset_user_data_0008(p_user);
  delete from duels where challenger_id = p_user or opponent_id = p_user;
  get diagnostics v_duels = row_count;
  delete from player_presence where user_id = p_user;
  return v_result || jsonb_build_object('duelsDeleted', v_duels);
end;
$$;

create function reset_all_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_duels integer := 0;
begin
  v_result := reset_all_data_0008();
  delete from duels where id is not null;
  get diagnostics v_duels = row_count;
  delete from player_presence where user_id is not null;
  return v_result || jsonb_build_object('duelsDeleted', v_duels);
end;
$$;

revoke all on function reset_user_data(uuid) from public, anon, authenticated;
grant execute on function reset_user_data(uuid) to service_role;
revoke all on function reset_all_data() from public, anon, authenticated;
grant execute on function reset_all_data() to service_role;
revoke all on function reset_user_data_0008(uuid) from public, anon, authenticated;
revoke all on function reset_all_data_0008() from public, anon, authenticated;
