-- Hex history — who trained in a hex, at what, and what it earned
-- (GET territory/history/<h3>).
--
-- READ-ONLY, DERIVED. Every row is a scored set in a submitted session that
-- STARTED in the hex — the session's server-recorded start cell, the same one
-- territory resolves from (0001), never a location the client claims. Voiding a
-- session drops its sets from the view with no correction step, like every
-- other read in this schema. `power` is the territory contribution the session
-- made (0007), null when the set fell below the claim floor: it still happened
-- here, it just took no ground.
--
-- PRIVACY (N7): a hex and the server's submit time are already what the schema
-- stores; nothing finer is exposed, and the client shows the time coarsely
-- ("5 h ago").

create index workout_sessions_hex_history_idx
  on workout_sessions (start_h3, board, submitted_at_ms desc)
  where status = 'submitted';

create view hex_set_history
with (security_invoker = true) as
  select s.start_h3 as h3,
         s.board,
         s.user_id,
         r.movement_id,
         r.measurement_type,
         r.rep_count,
         r.hold_ms,
         c.power,
         s.submitted_at_ms
  from workout_sessions s
  join set_records r on r.session_id = s.id
  left join hex_contributions c on c.session_id = s.id
  where s.status = 'submitted'
    and s.submitted_at_ms is not null
    and r.scored;

revoke all on hex_set_history from public, anon, authenticated;
