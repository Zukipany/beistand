-- Beistand: accounts, modes, contacts, consent, events, medicines.
-- Run in the Supabase SQL editor. Row-level security: a person sees their own rows;
-- a relative sees only the event kinds the person consented to share with them.

create table if not exists profiles (
  id          uuid primary key references auth.users on delete cascade,
  name        text not null,
  language    text not null default 'de',
  set_up_by   uuid references auth.users,          -- relative who helped with sign-up
  family_pin  text,                                -- hashed; guards settings on the 4-button home
  created_at  timestamptz not null default now()
);

-- Answers are "what is hard", never a diagnosis.
create type mode as enum ('older','dementia','sight','low_vision','hearing','wheelchair',
                          'speech','calm','easy_reading','seizure','tremor','low_energy','deafblind');

create table if not exists modes (
  user_id uuid references profiles on delete cascade,
  mode    mode not null,
  enabled_at timestamptz not null default now(),
  primary key (user_id, mode)
);

create table if not exists contacts (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references profiles on delete cascade,
  name      text not null,
  phone     text not null check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  relation  text,
  priority  int not null default 1,
  member_id uuid references auth.users             -- set once the relative accepts the invite
);

create type event_kind as enum ('check_in','medicine_taken','medicine_missed','alert','location',
                                'repeated_question','routine_step_skipped','left_safe_area');

-- One row per thing the person allows one contact to see. Withdraw = delete the row.
create table if not exists consents (
  user_id    uuid references profiles on delete cascade,
  contact_id uuid references contacts on delete cascade,
  kind       event_kind not null,
  granted_at timestamptz not null default now(),
  primary key (user_id, contact_id, kind)
);

create table if not exists events (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references profiles on delete cascade,
  kind     event_kind not null,
  at       timestamptz not null default now(),
  detail   jsonb not null default '{}'
);
create index on events (user_id, at desc);

create table if not exists medicines (
  id       uuid primary key default gen_random_uuid(),
  user_id  uuid not null references profiles on delete cascade,
  name     text not null,                 -- entered by the person/family; the app gives no dosing advice
  times    time[] not null,
  active   boolean not null default true
);

create table if not exists doses (
  medicine_id uuid references medicines on delete cascade,
  scheduled   timestamptz not null,
  taken_at    timestamptz,
  primary key (medicine_id, scheduled)
);

-- ---------------------------------------------------------------- RLS
alter table profiles  enable row level security;
alter table modes     enable row level security;
alter table contacts  enable row level security;
alter table consents  enable row level security;
alter table events    enable row level security;
alter table medicines enable row level security;
alter table doses     enable row level security;

create policy own_profile  on profiles  for all using (id = auth.uid() or set_up_by = auth.uid());
create policy own_modes    on modes     for all using (user_id = auth.uid());
create policy own_contacts on contacts  for all using (user_id = auth.uid());
create policy own_consents on consents  for all using (user_id = auth.uid());
create policy own_meds     on medicines for all using (user_id = auth.uid());
create policy own_doses    on doses     for all using (
  exists (select 1 from medicines m where m.id = medicine_id and m.user_id = auth.uid()));
create policy own_events   on events    for all using (user_id = auth.uid());

-- Family view: a relative reads an event only if that kind is consented for them.
-- Location events are written only during an active alert (see backend ladder).
create policy family_events on events for select using (
  exists (select 1 from consents cs join contacts c on c.id = cs.contact_id
          where cs.user_id = events.user_id and cs.kind = events.kind and c.member_id = auth.uid()));
