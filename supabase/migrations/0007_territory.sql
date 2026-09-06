-- Territory storage — the claim/capture/decay spine (B-9, B-10; D1–D3, D7).
--
-- THE MODEL: AN APPEND-ONLY CONTRIBUTIONS LEDGER, DECAYED LAZILY ON READ.
-- requirements.md D3 is explicit — "Power decays on a 72 h half-life, computed
-- lazily on read — don't run a cron for this." A stored, pre-decayed `power`
-- counter would need exactly the cron D3 forbids: something would have to keep
-- multiplying it by 0.5 every 72 h. So power is never stored as a running total.
-- Instead every scored session appends one IMMUTABLE contribution (a power amount
-- and the instant it was earned), and a reader reconstructs current power as
--
--     power(u, h, now) = Σ over live contributions c in h by u:
--                            c.power × 0.5 ^ ((now − c.earned_at) / 72 h)
--
-- That sum is what `_shared/territory.ts` computes. Decay is a pure function of
-- (amount, age), so the same contribution read at two different times yields two
-- different powers with nothing in between having been updated.
--
-- WHY A SEPARATE `hex_ownership` TABLE IF POWER IS RECOMPUTED.
-- Recomputing the argmax over every contribution is fine for one hex (a handful
-- of rows) but the leaderboard ("hexes held, total area", D7) would otherwise
-- scan and decay the entire contributions table on every map open. `hex_ownership`
-- is a MATERIALISED CACHE of the current winner per cell, written only when a
-- resolution actually changes the holder. It is a cache, not the source of truth:
-- the contributions ledger is authoritative, and a stale ownership row is corrected
-- the next time that hex is resolved. `hex_flips` is the audit trail behind D6's
-- "recent flips" and is append-only like the score ledger.
--
-- BOARD ISOLATION (J7). Every table carries `board`, and `hex_ownership` is keyed
-- `(h3, board)` — NOT `h3` alone. The demo venue is a real res-8 cell that a
-- production athlete standing in the same park would also land in; a global
-- ownership row would let a demo capture overwrite the production holder, which is
-- precisely the leak J7 forbids ("Demo-board data never appears in production
-- competitive reads"). Keying on the pair keeps the two boards' claims separate in
-- one table.
--
-- VOIDING (I12). A contribution is tied to its session by `session_id`, and reads
-- go through the `hex_contributions_live` view below, which filters
-- `s.status = 'submitted'`. Voiding a session (0004) flips its status to `voided`,
-- so its territory contribution drops out of every read with no correction step —
-- the identical mechanism `user_lifetime_score` and `user_movement_reps` use.

-- ---------------------------------------------------------------------------
-- The append-only contributions ledger
-- ---------------------------------------------------------------------------

create table hex_contributions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles (id) on delete cascade,
  -- One contribution per session, enforced. A session scores in exactly one hex
  -- (its server-recorded start_h3), so this UNIQUE is the territory analogue of
  -- score_ledger.session_id: a second layer against a double award behind the
  -- atomic one-shot consume.
  session_id uuid not null unique references workout_sessions (id) on delete cascade,
  h3         text not null,
  -- The RepScore awarded for the session, frozen at submit time. Decay is applied
  -- on read, never written back, so this value never changes after insert.
  power      double precision not null check (power > 0),
  board      text not null default 'production'
             check (board in ('production', 'demo')),
  earned_at  timestamptz not null default now()
);

-- Reads resolve one hex at a time (hex detail) or a bbox of them (map), so the
-- (board, h3) index is the hot one; the user index backs the reset and any
-- future "your claims" view.
create index hex_contributions_board_h3_idx on hex_contributions (board, h3);
create index hex_contributions_user_idx on hex_contributions (user_id);

-- ---------------------------------------------------------------------------
-- Materialised current holder (cache)
-- ---------------------------------------------------------------------------

create table hex_ownership (
  h3          text not null,
  board       text not null check (board in ('production', 'demo')),
  owner_id    uuid not null references profiles (id) on delete cascade,
  -- The owner's decayed power at the moment this row was last written. Stored for
  -- display and for a cheap "is the cache still ahead?" check; the authoritative
  -- number is always recomputed from the ledger.
  owner_power double precision not null,
  updated_at  timestamptz not null default now(),
  primary key (h3, board)
);

-- The leaderboard groups by owner, so it needs this index rather than a scan.
create index hex_ownership_owner_idx on hex_ownership (owner_id);

-- ---------------------------------------------------------------------------
-- Flip audit trail (append-only, D6 "recent flips")
-- ---------------------------------------------------------------------------

create table hex_flips (
  id           bigint generated always as identity primary key,
  h3           text not null,
  board        text not null check (board in ('production', 'demo')),
  -- Null on the first-ever capture of a cell (it flipped from unclaimed).
  from_user_id uuid references profiles (id) on delete cascade,
  to_user_id   uuid not null references profiles (id) on delete cascade,
  at_ms        bigint not null,
  created_at   timestamptz not null default now()
);

-- "Recent flips for this hex" reads newest-first, hence the descending index.
create index hex_flips_h3_idx on hex_flips (h3, at_ms desc);

-- ---------------------------------------------------------------------------
-- The live-contribution read path (I12)
-- ---------------------------------------------------------------------------

-- Every territory read goes through this view, never the bare table. It joins the
-- session and keeps only `submitted` ones, so a voided session's contribution
-- disappears from power, from the argmax and from the leaderboard the instant
-- void_session() runs — with no trigger, no denormalised counter and no
-- correction pass. This is the same design as user_lifetime_score (0001).
create view hex_contributions_live as
  select c.id, c.user_id, c.h3, c.power, c.board, c.earned_at
  from hex_contributions c
  join workout_sessions s on s.id = c.session_id
  where s.status = 'submitted';

-- ---------------------------------------------------------------------------
-- Row level security — deny everything (0001 posture)
-- ---------------------------------------------------------------------------

alter table hex_contributions enable row level security;
alter table hex_ownership     enable row level security;
alter table hex_flips         enable row level security;

-- Append-only, like score_ledger (0004): the service role writes through the Edge
-- Functions and nothing may edit or delete a contribution or a flip after the
-- fact. hex_ownership is deliberately NOT revoked — it is a cache that is upserted
-- whenever the holder changes, so it needs UPDATE.
revoke update, delete on hex_contributions from public, anon, authenticated;
revoke update, delete on hex_flips from public, anon, authenticated;
