-- Demo / local-dev reset — the "wipe and start clean" path (requirements.md §6-J).
--
-- THIS IS NOT THE PRODUCTION CORRECTION PATH. The sanctioned way to undo a bad
-- session in production is `void_session()` (0004, I12): it flips `voided` and
-- every board recomputes through the `where not voided` predicate, so history is
-- preserved and reversible (§3 rule 1). These functions HARD-DELETE. They exist
-- for one reason: before a demo run the dev user has accumulated a pile of test
-- submissions, a burned daily budget and — once 0007 lands — captured territory,
-- and there is no way to get back to a clean board without dropping the whole
-- stack. A reset that preserves the account (so the app's persisted guest token
-- keeps working) but erases everything it has done is the cheap fix.
--
-- WHAT IS PRESERVED, AND WHY
-- `profiles`, `unlocked_movements`, `movements`, `movement_config_versions` and
-- `movement_config_offsets` are never touched. The first two are per-account
-- state the signup trigger created and the app expects to find on next launch;
-- the last three are the frozen catalogue (B-4). Wiping those would not be a
-- reset, it would be a re-seed, and it would break the account rather than clean
-- it. Everything session-derived — sessions and their sets/reps/traces, the
-- ledger, flags, daily counters, devices, and territory — goes.
--
-- The hex_* deletes are guarded with `to_regclass(...) is not null` so this
-- migration stands alone: it applies cleanly whether or not 0007 (which creates
-- those tables) has run. Migration order is 0006 then 0007, so on a fresh
-- `db reset` the tables do not exist yet when 0006 is created — the guards make
-- the function correct at creation time and complete once 0007 lands.

-- ---------------------------------------------------------------------------
-- reset_user_data — one account
-- ---------------------------------------------------------------------------

create or replace function reset_user_data(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flips        integer := 0;
  v_ownership    integer := 0;
  v_contribs     integer := 0;
  v_ledger       integer := 0;
  v_flags        integer := 0;
  v_counters     integer := 0;
  v_devices      integer := 0;
  v_sessions     integer := 0;
begin
  if p_user is null then
    raise exception 'reset_user_data requires a user id';
  end if;

  -- Children before parents. hex_* first (they reference profiles and, for
  -- contributions, workout_sessions), then the session-scoped tables, then the
  -- session itself — whose ON DELETE CASCADE wipes set_records → rep_events /
  -- pose_traces without naming them here.

  if to_regclass('public.hex_flips') is not null then
    delete from hex_flips where from_user_id = p_user or to_user_id = p_user;
    get diagnostics v_flips = row_count;
  end if;

  if to_regclass('public.hex_ownership') is not null then
    delete from hex_ownership where owner_id = p_user;
    get diagnostics v_ownership = row_count;
  end if;

  if to_regclass('public.hex_contributions') is not null then
    delete from hex_contributions where user_id = p_user;
    get diagnostics v_contribs = row_count;
  end if;

  delete from score_ledger where user_id = p_user;
  get diagnostics v_ledger = row_count;

  delete from session_flags
   where session_id in (select id from workout_sessions where user_id = p_user);
  get diagnostics v_flags = row_count;

  delete from daily_counters where user_id = p_user;
  get diagnostics v_counters = row_count;

  delete from devices where user_id = p_user;
  get diagnostics v_devices = row_count;

  delete from workout_sessions where user_id = p_user;
  get diagnostics v_sessions = row_count;

  return jsonb_build_object(
    'userId', p_user,
    'sessionsDeleted', v_sessions,
    'ledgerDeleted', v_ledger,
    'flagsDeleted', v_flags,
    'countersDeleted', v_counters,
    'devicesDeleted', v_devices,
    'hexContributionsDeleted', v_contribs,
    'hexOwnershipDeleted', v_ownership,
    'hexFlipsDeleted', v_flips
  );
end;
$$;

revoke all on function reset_user_data(uuid) from public, anon, authenticated;
grant execute on function reset_user_data(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- reset_all_data — the whole board
-- ---------------------------------------------------------------------------

-- Same deletion set with no user filter: every account's session-derived data at
-- once, catalogue and profiles preserved. This is what the reset tool's `--all`
-- calls, and it is the reason `--all` is gated behind an explicit `--yes` on the
-- command line — it clears the board for every user the stack has ever seen.
create or replace function reset_all_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flips        integer := 0;
  v_ownership    integer := 0;
  v_contribs     integer := 0;
  v_ledger       integer := 0;
  v_flags        integer := 0;
  v_counters     integer := 0;
  v_devices      integer := 0;
  v_sessions     integer := 0;
begin
  -- Every DELETE carries an always-true `<pk> is not null` predicate rather than
  -- being bare. This stack's PostgREST (16.x) rejects an unqualified DELETE
  -- reached through an RPC with 400 / SQLSTATE 21000 "DELETE requires a WHERE
  -- clause", even though psql as the superuser owner runs the identical body
  -- fine — the guard keys on the non-superuser session, not on the function.
  -- `reset_user_data` is already qualified by `p_user`; this mirrors that with a
  -- predicate on the primary key so the wipe still matches every row. Do NOT
  -- "simplify" these back to bare deletes: tool/reset_demo.ts --all breaks.
  if to_regclass('public.hex_flips') is not null then
    delete from hex_flips where id is not null;
    get diagnostics v_flips = row_count;
  end if;

  if to_regclass('public.hex_ownership') is not null then
    delete from hex_ownership where h3 is not null;
    get diagnostics v_ownership = row_count;
  end if;

  if to_regclass('public.hex_contributions') is not null then
    delete from hex_contributions where id is not null;
    get diagnostics v_contribs = row_count;
  end if;

  delete from score_ledger where id is not null;
  get diagnostics v_ledger = row_count;

  delete from session_flags where id is not null;
  get diagnostics v_flags = row_count;

  delete from daily_counters where user_id is not null;
  get diagnostics v_counters = row_count;

  delete from devices where id is not null;
  get diagnostics v_devices = row_count;

  delete from workout_sessions where id is not null;
  get diagnostics v_sessions = row_count;

  return jsonb_build_object(
    'scope', 'all',
    'sessionsDeleted', v_sessions,
    'ledgerDeleted', v_ledger,
    'flagsDeleted', v_flags,
    'countersDeleted', v_counters,
    'devicesDeleted', v_devices,
    'hexContributionsDeleted', v_contribs,
    'hexOwnershipDeleted', v_ownership,
    'hexFlipsDeleted', v_flips
  );
end;
$$;

revoke all on function reset_all_data() from public, anon, authenticated;
grant execute on function reset_all_data() to service_role;
