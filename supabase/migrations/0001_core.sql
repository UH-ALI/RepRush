-- RepRush — core schema for the count + verify spine.
--
-- H3 DECISION (docs/backend-scaffolding.md §2): hex indices are computed in the
-- Edge Function with h3-js and stored as text. No h3/h3_postgis extension. No
-- PostGIS in this slice either — its only consumers are spots.location and the
-- 100 m ST_DWithin check-in, and both belong to the territory work that is out
-- of scope here. Add `create extension postgis;` when spots land.
--
-- RLS POSTURE (docs/backend-scaffolding.md §3): row level security is enabled on
-- every table with ZERO write policies. Nothing but the service role — i.e. the
-- Edge Functions — can write. Reads are routed through functions too, so there
-- are no read policies either. This is deliberate, not an omission: a missing
-- policy denies by default, which is the posture we want.
--
-- Scope: requirements.md I1–I3, I6–I13; roles.md B-1, B-4, B-6, B-7, B-8.
-- Territory, spots, boards, XP curve, achievements and challenges are NOT here.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- One row per auth user, created by the trigger below. `lifetime_score` is not
-- stored — it is a ledger aggregate (see user_lifetime_score), because a stored
-- counter and an append-only ledger drift the first time a session is voided.
create table profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  handle      text not null unique,
  avatar_url  text,
  created_at  timestamptz not null default now()
);

-- Device binding (A3) is upserted inside session-start; there is no separate
-- /devices flow. attestation_state stays 'none' until B-19 lands on Day 6.
create table devices (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references profiles (id) on delete cascade,
  platform          text not null,
  attestation_state text not null default 'none',
  first_seen_at     timestamptz not null default now(),
  last_seen_at      timestamptz not null default now()
);

create index devices_user_idx on devices (user_id);

-- ---------------------------------------------------------------------------
-- Movement catalogue and versioned thresholds
-- ---------------------------------------------------------------------------

-- B owns id/family/tier/difficulty; A owns joint_config (roles.md §5). Frozen
-- after seeding — changing a multiplier needs standup.
create table movements (
  id               text primary key,
  family           text not null,
  tier             integer not null,
  measurement_type text not null check (measurement_type in ('repBodyweight', 'holdTime')),
  difficulty       numeric not null check (difficulty > 0),
  joint_config     jsonb not null default '{}'::jsonb,
  placement_hint   text,
  -- Absolute in-form band for holdTime movements only (plank: 160–185).
  hold_band_low    double precision,
  hold_band_high   double precision,
  check (
    (measurement_type = 'holdTime') = (hold_band_low is not null and hold_band_high is not null)
  )
);

-- The active version is what POST /session/start issues and binds to the
-- session. Clients cannot select an older one (api-contract.md §Versioned
-- calibration): a tuned offset set is a NEW row, never a silent edit.
create table movement_config_versions (
  version      text primary key,
  published_at timestamptz not null default now(),
  active       boolean not null default false
);

-- Exactly one active version — enforced, not hoped for.
create unique index movement_config_versions_one_active
  on movement_config_versions (active) where active;

-- Offsets are REST-RELATIVE, never absolute angles (A-19). The scorer resolves
-- them against each set's own calibration.restSignal.
--
-- `unit` and `direction` are load-bearing and easy to overlook: `unit` selects
-- the trace tolerance (15 for degrees, 0.15 for ratios) and `direction` says
-- which way "more extreme" runs, so the same code covers squat (decreasing
-- angle) and jumping jack (increasing ratio).
create table movement_config_offsets (
  version           text not null references movement_config_versions (version) on delete cascade,
  movement_id       text not null references movements (id) on delete cascade,
  enter_peak_offset double precision not null,
  enter_rest_offset double precision not null,
  rom_target_offset double precision not null,
  unit              text not null check (unit in ('deg', 'ratio')),
  direction         text not null check (direction in ('decreasing', 'increasing', 'hold')),
  primary key (version, movement_id)
);

-- Tier gating doubles as anti-cheat (I10): a user cannot score a movement they
-- have not unlocked. T1/T2 are granted on signup by the trigger below.
create table unlocked_movements (
  user_id               uuid not null references profiles (id) on delete cascade,
  movement_id           text not null references movements (id) on delete cascade,
  unlocked_at           timestamptz not null default now(),
  qualifying_session_id uuid,
  primary key (user_id, movement_id)
);

-- ---------------------------------------------------------------------------
-- Sessions — one-shot (I2), server-timed (I3)
-- ---------------------------------------------------------------------------

create table workout_sessions (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references profiles (id) on delete cascade,
  -- open → submitted exactly once. The one-shot mechanism is the atomic
  -- UPDATE ... WHERE status = 'open' in session-submit, not application logic.
  status                  text not null default 'open'
                          check (status in ('open', 'submitted', 'expired', 'voided')),
  movement_config_version text not null references movement_config_versions (version),

  -- Server-observed window. These two numbers are the only clock that is
  -- trusted; every claimed timeline is measured against them (I3).
  server_start_ms         bigint not null,
  submitted_at_ms         bigint,
  expires_at_ms           bigint not null,

  -- Session-start context, captured once. Submit must match it, and territory
  -- always resolves from HERE, never from the submitted location. One stored
  -- fix rather than a GPS trace, so N7 holds.
  start_lat               double precision not null,
  start_lng               double precision not null,
  start_accuracy_m        double precision not null,
  start_is_mocked         boolean not null default false,
  start_h3                text not null,
  spot_id                 text,

  -- Server-side context (J7). Decided from the authenticated account and an
  -- allowlist — never from a request field.
  board                   text not null default 'production'
                          check (board in ('production', 'demo')),

  -- The verbatim payload. Kept because the async validators need to be
  -- re-runnable after the fact (structural rule 2), and because it is the only
  -- way to answer "why was this session flagged" three days later.
  evidence                jsonb
);

create index workout_sessions_user_status_idx on workout_sessions (user_id, status);
create index workout_sessions_start_idx on workout_sessions (user_id, server_start_ms desc);

create table set_records (
  id               bigint generated always as identity primary key,
  session_id       uuid not null references workout_sessions (id) on delete cascade,
  movement_id      text not null references movements (id),
  measurement_type text not null,
  -- Server-recomputed. Legal here; forbidden in the Evidence payload (I1).
  rep_count        integer not null default 0,
  hold_ms          integer not null default 0,
  form_factor      double precision not null,
  tempo_factor     double precision not null,
  rep_score        double precision not null,
  capped_score     double precision not null,
  scored           boolean not null default true,
  capture          jsonb not null default '{}'::jsonb,
  calibration      jsonb not null default '{}'::jsonb
);

create index set_records_session_idx on set_records (session_id);

-- Mirrors api-contract.md §evidence reps[] verbatim plus the recomputed
-- rom_score. No pixel field may ever appear here (§The normalisation rule).
create table rep_events (
  id                     bigint generated always as identity primary key,
  set_id                 bigint not null references set_records (id) on delete cascade,
  i                      integer not null,
  t_start_ms             integer not null,
  t_end_ms               integer not null,
  rest_extreme           double precision not null,
  peak_extreme           double precision not null,
  conf_mean              double precision not null,
  conf_min               double precision not null,
  concentric_ms          integer,
  eccentric_ms           integer,
  hip_drift_norm         double precision,
  shoulder_wrist_dy_norm double precision,
  rom_score              double precision not null
);

create index rep_events_set_idx on rep_events (set_id);

-- I8 / structural rule 2. double precision[] and NOT numeric[] — supabase-js
-- returns numerics as strings, which would put a parse pass in every validator.
create table pose_traces (
  set_id    bigint primary key references set_records (id) on delete cascade,
  hz        double precision not null,
  t0_ms     integer not null,
  primary_signal double precision[] not null,
  conf_mean      double precision[] not null
);

-- ---------------------------------------------------------------------------
-- Ledger, flags, counters
-- ---------------------------------------------------------------------------

-- Append-only (§3 rule 1). Revokes are in 0004; the void path flips `voided`
-- via a service-role-only function and never deletes.
create table score_ledger (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles (id) on delete cascade,
  session_id uuid not null unique references workout_sessions (id) on delete cascade,
  points     numeric not null,
  reason     text not null,
  voided     boolean not null default false,
  created_at timestamptz not null default now()
);

create index score_ledger_user_idx on score_ledger (user_id) where not voided;

-- The shadow-flag mechanism (I13). Write-only from the submit path; never read
-- when building a response, so a false positive can degrade a score's standing
-- later without ever locking a judge out mid-demo.
create table session_flags (
  id         bigint generated always as identity primary key,
  session_id uuid not null references workout_sessions (id) on delete cascade,
  code       text not null,
  severity   text not null check (severity in ('info', 'warn', 'contradiction')),
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index session_flags_session_idx on session_flags (session_id);
create index session_flags_code_idx on session_flags (code);

-- Rate limits and the per-day cap (I11). One row per user per UTC day.
create table daily_counters (
  user_id          uuid not null references profiles (id) on delete cascade,
  day              date not null,
  sessions_started integer not null default 0,
  rep_score_earned numeric not null default 0,
  primary key (user_id, day)
);

-- Every board reads through this predicate, so voiding a session is enough to
-- recompute all of them (I12). No trigger, no denormalised counter to drift.
create view user_lifetime_score as
  select user_id, coalesce(sum(points), 0) as lifetime_score
  from score_ledger
  where not voided
  group by user_id;

-- Per-movement rep totals, backing `repsTowardNextTier` in GET /movements.
-- Restricted to `submitted` so a voided session stops counting immediately,
-- which is the same I12 mechanism as the view above: nothing is corrected, the
-- predicate simply stops matching.
--
-- This is reps EARNED, not reps attempted. The threshold that turns a total into
-- a tier unlock is B-14's progression rule and is deliberately not here.
create view user_movement_reps as
  select s.user_id, r.movement_id, sum(r.rep_count)::integer as reps
  from set_records r
  join workout_sessions s on s.id = r.session_id
  where s.status = 'submitted'
  group by s.user_id, r.movement_id;

-- ---------------------------------------------------------------------------
-- Signup trigger
-- ---------------------------------------------------------------------------

-- Anonymous sign-in is the whole Day-1 auth deliverable (A1) — a judge never
-- hits a signup wall. Guests get a generated handle and T1/T2 unlocked, so the
-- tier gate (I10) has something to check against from the first session.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (id, handle)
  values (new.id, 'athlete_' || substr(replace(new.id::text, '-', ''), 1, 6))
  on conflict (id) do nothing;

  insert into unlocked_movements (user_id, movement_id)
  select new.id, m.id from movements m where m.tier <= 2
  on conflict do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------------------------------------------------------------------------
-- Row level security — deny everything, no exceptions
-- ---------------------------------------------------------------------------

alter table profiles                enable row level security;
alter table devices                 enable row level security;
alter table movements               enable row level security;
alter table movement_config_versions enable row level security;
alter table movement_config_offsets enable row level security;
alter table unlocked_movements      enable row level security;
alter table workout_sessions        enable row level security;
alter table set_records             enable row level security;
alter table rep_events              enable row level security;
alter table pose_traces             enable row level security;
alter table score_ledger            enable row level security;
alter table session_flags           enable row level security;
alter table daily_counters          enable row level security;
