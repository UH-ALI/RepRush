-- Append-only ledger enforcement and the void path (§3 rule 1, I12).
--
-- The ledger is append-only in the sense that matters: no row is ever edited to
-- change a number, and no row is ever deleted. Correction happens by flipping
-- `voided`, and every board recomputes through the user_lifetime_score view,
-- which already filters on it. That is what makes anti-cheat survivable — a
-- bad session found on Day 5 can be undone on Day 5 without touching history.
--
-- The revokes below are belt-and-braces on top of RLS: RLS denies anon and
-- authenticated already, and these remove the table-level privilege so a future
-- permissive policy cannot silently re-open the write path.

revoke update, delete on score_ledger from public, anon, authenticated;
revoke update, delete on session_flags from public, anon, authenticated;

-- The only sanctioned mutation of a ledger row. service_role bypasses RLS but
-- NOT these grants, so the void path goes through this function rather than an
-- ad-hoc update — which also means the session status and the ledger flag can
-- never disagree.
--
-- security definer: runs as the owning role (postgres), so the revoked
-- UPDATE is available inside and nowhere else.
create or replace function void_session(p_session uuid, p_why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer;
begin
  if p_why is null or length(trim(p_why)) = 0 then
    raise exception 'void_session requires a reason';
  end if;

  -- Flag the ledger row without deleting it. A session that scored zero (tier
  -- gated, capped to nothing) still has a row, so this always finds one.
  update score_ledger
     set voided = true
   where session_id = p_session;
  get diagnostics v_rows = row_count;

  update workout_sessions
     set status = 'voided'
   where id = p_session
     and status <> 'voided';

  insert into session_flags (session_id, code, severity, detail)
  values (p_session, 'SESSION_VOIDED', 'contradiction', jsonb_build_object('why', p_why));

  if v_rows = 0 then
    raise exception 'void_session: no ledger row for session %', p_session;
  end if;
end;
$$;

revoke all on function void_session(uuid, text) from public, anon, authenticated;
grant execute on function void_session(uuid, text) to service_role;

-- Expiry sweep. Sessions are wall-clock bounded (I2: unsubmitted sessions
-- expire after 4 h) and the submit gate checks expires_at_ms directly, so this
-- is hygiene rather than correctness — it just stops `open` rows accumulating
-- forever. Safe to run from a cron or by hand; it never touches submitted work.
create or replace function expire_stale_sessions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer;
begin
  update workout_sessions
     set status = 'expired'
   where status = 'open'
     and expires_at_ms < (extract(epoch from now()) * 1000)::bigint;
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

revoke all on function expire_stale_sessions() from public, anon, authenticated;
grant execute on function expire_stale_sessions() to service_role;
