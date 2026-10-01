-- Daily challenge storage — the live half of GET /challenges/daily and
-- POST /challenges/daily/claim (G1, G3).
--
-- PROGRESS IS DERIVED, CLAIMS ARE STORED. A challenge's progress is "verified,
-- server-scored results only" (api-contract.md §challenges), and the only place
-- verified results live is set_records joined to a submitted session. So progress
-- is a read through the view below — never a counter the submit path has to
-- remember to bump, and never a number the client reports. Voiding a session
-- (I12) drops its reps from the view with no correction step, the same mechanism
-- as user_lifetime_score and user_movement_reps (0001).
--
-- The CLAIM is the one fact that cannot be derived, because it is a choice the
-- athlete makes (G3: claiming feels better than auto-award). One row per user per
-- daily template; the primary key is the double-claim guard, so two racing claim
-- requests serialise in Postgres and exactly one inserts.
--
-- XP, NOT POWER. Missions may award capped XP only; territory power accrues only
-- from verified RepScore (requirements.md structural rule 4). challenge_claims is
-- therefore read by GET /me and by session-submit's level maths, and by nothing
-- that resolves territory.

create table challenge_claims (
  user_id     uuid not null references profiles (id) on delete cascade,
  -- `daily-<YYYY-MM-DD>` (UTC). The day is part of the key, so tomorrow's
  -- challenge is a new row rather than an update.
  template_id text not null,
  xp_awarded  integer not null check (xp_awarded >= 0),
  claimed_at  timestamptz not null default now(),
  primary key (user_id, template_id)
);

alter table challenge_claims enable row level security;

-- Append-only, like score_ledger: a claim is never edited or withdrawn.
revoke update, delete on challenge_claims from public, anon, authenticated;

-- Per-user, per-movement, per-UTC-day rep totals from scored sets in submitted
-- sessions. The day is the SUBMIT day on the server's clock — the only trusted
-- clock (I3) — so a set cannot be back- or forward-dated into a different
-- challenge by the client.
--
-- security_invoker so the deny-all RLS on the underlying tables applies to anyone
-- but the service role; the select revoke is belt-and-braces on top of it.
create view user_daily_movement_reps
with (security_invoker = true) as
  select s.user_id,
         r.movement_id,
         (to_timestamp(s.submitted_at_ms / 1000.0) at time zone 'utc')::date as day,
         sum(r.rep_count)::integer as reps
  from set_records r
  join workout_sessions s on s.id = r.session_id
  where s.status = 'submitted'
    and s.submitted_at_ms is not null
    and r.scored
  group by 1, 2, 3;

revoke all on user_daily_movement_reps from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Demo reset (0006) — claims are session-derived state too
-- ---------------------------------------------------------------------------

-- 0006's reset functions predate this table, so a reset would leave today's claim
-- in place and every rehearsal after the first would open on "Claimed". Rather
-- than re-declaring 0006's bodies here (two copies of the delete list to drift),
-- the originals are renamed and wrapped: the wrapper runs them unchanged and adds
-- the claims delete. `tool/reset_demo.ts` keeps calling the same names.

alter function reset_user_data(uuid) rename to reset_user_data_core;
alter function reset_all_data() rename to reset_all_data_core;

create function reset_user_data(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_claims integer := 0;
begin
  v_result := reset_user_data_core(p_user);
  delete from challenge_claims where user_id = p_user;
  get diagnostics v_claims = row_count;
  return v_result || jsonb_build_object('challengeClaimsDeleted', v_claims);
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
  v_claims integer := 0;
begin
  v_result := reset_all_data_core();
  delete from challenge_claims where user_id is not null;
  get diagnostics v_claims = row_count;
  return v_result || jsonb_build_object('challengeClaimsDeleted', v_claims);
end;
$$;

revoke all on function reset_user_data(uuid) from public, anon, authenticated;
grant execute on function reset_user_data(uuid) to service_role;
revoke all on function reset_all_data() from public, anon, authenticated;
grant execute on function reset_all_data() to service_role;
