-- The atomic outcome write, plus the two columns flag triage needs.
--
-- WHY A FUNCTION AND NOT A SERIES OF INSERTS FROM THE EDGE FUNCTION.
-- `POST /session/submit` writes six tables: set_records, rep_events,
-- pose_traces, score_ledger, session_flags, daily_counters. Issued as separate
-- PostgREST calls they are six independent commits, and a failure between them
-- leaves a session that is consumed (one-shot, I2 — it cannot be retried) but
-- only partly recorded. The two bad outcomes are both reachable that way:
-- points banked with no set rows to justify them, or set rows with no points.
-- Either one is a hole in the claim that every point traces to a session (§3
-- rule 1). A plpgsql function body is a single transaction, so it is all or
-- nothing, and the caller cannot get it wrong by reordering statements.
--
-- The scoring maths does NOT live here. This function is a writer: it takes the
-- already-computed numbers as jsonb and persists them. Keeping the arithmetic in
-- `_shared/scoring/` is what lets it be unit-tested against golden fixtures with
-- no database, and what keeps this file boring enough to audit by eye.

-- Flag triage is "show me every flag on set 2 of session X", which needs these
-- as columns rather than buried in the detail jsonb. Nullable: session-scoped
-- flags (DAILY_CAP_APPLIED, SESSION_VOIDED) have neither.
alter table session_flags add column if not exists set_index integer;
alter table session_flags add column if not exists rep_index integer;

create index if not exists session_flags_session_set_idx
  on session_flags (session_id, set_index);

-- jsonb array → double precision[]. `with ordinality` is not optional: a bare
-- `array_agg` over a set-returning function has no guaranteed order, and a
-- reordered pose trace would make every downstream cross-check lie. This is the
-- same reason pose_traces is double precision[] and not numeric[] (0001).
create or replace function jsonb_to_float8_array(p_json jsonb)
returns double precision[]
language sql
immutable
strict
as $$
  select coalesce(
    array_agg(elem::double precision order by ord),
    '{}'::double precision[]
  )
  from jsonb_array_elements_text(p_json) with ordinality as t(elem, ord);
$$;

revoke all on function jsonb_to_float8_array(jsonb) from public, anon, authenticated;
grant execute on function jsonb_to_float8_array(jsonb) to service_role;

-- Persists a scored submission. Callers must have already consumed the session
-- with the atomic `UPDATE ... WHERE status = 'open'`; this asserts it.
create or replace function record_session_outcome(
  p_session uuid,
  p_points  numeric,
  p_day     date,
  p_sets    jsonb,
  p_flags   jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_set     jsonb;
  v_set_id  bigint;
  v_rep     jsonb;
  v_trace   jsonb;
  v_flag    jsonb;
begin
  -- Refuse to write against anything not already consumed. Without this the
  -- function could be pointed at an `open` session and produce a ledger row for
  -- a submission that never passed its gates.
  select user_id into v_user_id
    from workout_sessions
   where id = p_session
     and status = 'submitted';

  if v_user_id is null then
    raise exception 'record_session_outcome: session % is not in submitted state', p_session;
  end if;

  for v_set in select * from jsonb_array_elements(p_sets)
  loop
    insert into set_records (
      session_id, movement_id, measurement_type, rep_count, hold_ms,
      form_factor, tempo_factor, rep_score, capped_score, scored,
      capture, calibration
    ) values (
      p_session,
      v_set ->> 'movement_id',
      v_set ->> 'measurement_type',
      coalesce((v_set ->> 'rep_count')::integer, 0),
      coalesce((v_set ->> 'hold_ms')::integer, 0),
      (v_set ->> 'form_factor')::double precision,
      (v_set ->> 'tempo_factor')::double precision,
      (v_set ->> 'rep_score')::double precision,
      (v_set ->> 'capped_score')::double precision,
      coalesce((v_set ->> 'scored')::boolean, true),
      coalesce(v_set -> 'capture', '{}'::jsonb),
      coalesce(v_set -> 'calibration', '{}'::jsonb)
    ) returning id into v_set_id;

    for v_rep in select * from jsonb_array_elements(coalesce(v_set -> 'reps', '[]'::jsonb))
    loop
      -- The `nullif(..., 'null')` guards are for the optional fields. `->>`
      -- yields SQL NULL for an absent key, which casts fine, but a JSON null
      -- arrives as the four-character string 'null' and would throw on cast.
      -- The Evidence parser never emits JSON nulls; this is belt-and-braces for
      -- a hand-authored fixture.
      insert into rep_events (
        set_id, i, t_start_ms, t_end_ms, rest_extreme, peak_extreme,
        conf_mean, conf_min, concentric_ms, eccentric_ms,
        hip_drift_norm, shoulder_wrist_dy_norm, rom_score
      ) values (
        v_set_id,
        (v_rep ->> 'i')::integer,
        (v_rep ->> 't_start_ms')::integer,
        (v_rep ->> 't_end_ms')::integer,
        (v_rep ->> 'rest_extreme')::double precision,
        (v_rep ->> 'peak_extreme')::double precision,
        (v_rep ->> 'conf_mean')::double precision,
        (v_rep ->> 'conf_min')::double precision,
        nullif(v_rep ->> 'concentric_ms', 'null')::integer,
        nullif(v_rep ->> 'eccentric_ms', 'null')::integer,
        nullif(v_rep ->> 'hip_drift_norm', 'null')::double precision,
        nullif(v_rep ->> 'shoulder_wrist_dy_norm', 'null')::double precision,
        (v_rep ->> 'rom_score')::double precision
      );
    end loop;

    v_trace := v_set -> 'trace';
    if v_trace is not null and jsonb_typeof(v_trace) = 'object' then
      insert into pose_traces (set_id, hz, t0_ms, primary_signal, conf_mean)
      values (
        v_set_id,
        (v_trace ->> 'hz')::double precision,
        (v_trace ->> 't0_ms')::integer,
        jsonb_to_float8_array(v_trace -> 'primary'),
        jsonb_to_float8_array(v_trace -> 'conf_mean')
      );
    end if;
  end loop;

  -- The point itself. score_ledger.session_id is UNIQUE (0001), so this is the
  -- second layer against a double award: the atomic consume is the first.
  insert into score_ledger (user_id, session_id, points, reason)
  values (v_user_id, p_session, p_points, 'session_scored');

  for v_flag in select * from jsonb_array_elements(p_flags)
  loop
    insert into session_flags (session_id, code, severity, set_index, rep_index, detail)
    values (
      p_session,
      v_flag ->> 'code',
      v_flag ->> 'severity',
      nullif(v_flag ->> 'set_index', 'null')::integer,
      nullif(v_flag ->> 'rep_index', 'null')::integer,
      coalesce(v_flag -> 'detail', '{}'::jsonb)
    );
  end loop;

  -- I11's per-day budget accrues here, not in the scorer: the scorer is pure and
  -- is handed the day's running total as an input. sessions_started is bumped by
  -- session-start, so only the score column moves here.
  insert into daily_counters (user_id, day, sessions_started, rep_score_earned)
  values (v_user_id, p_day, 0, p_points)
  on conflict (user_id, day)
  do update set rep_score_earned = daily_counters.rep_score_earned + excluded.rep_score_earned;
end;
$$;

revoke all on function record_session_outcome(uuid, numeric, date, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function record_session_outcome(uuid, numeric, date, jsonb, jsonb)
  to service_role;
