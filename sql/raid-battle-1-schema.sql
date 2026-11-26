begin;
alter table public.guild_profiles
  add column if not exists hp integer not null default 200,
  add column if not exists mp integer not null default 200;
alter table public.quest_limits
  add column if not exists category text not null default 'daily',
  add column if not exists game_version integer not null default 1;
create table if not exists public.quest_entry_blocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  quest_key text not null default '*',
  blocked_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key(user_id,quest_key)
);
alter table public.quest_entry_blocks enable row level security;
revoke all on public.quest_entry_blocks from public,anon,authenticated;

create table if not exists public.raid_battles (
  quest_id text primary key references public.quest_limits(quest_id) on delete restrict,
  boss_name text not null default '잔류 균열체',
  boss_max_hp integer not null default 1000 check (boss_max_hp > 0),
  boss_hp integer not null default 1000 check (boss_hp >= 0 and boss_hp <= boss_max_hp),
  player_damage integer not null default 20 check (player_damage > 0),
  boss_damage integer not null default 10 check (boss_damage >= 0),
  turn_no integer not null default 1 check (turn_no > 0),
  state text not null default 'waiting' check (state in ('waiting','active','victory','defeat')),
  revision bigint not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now()
);
create table if not exists public.raid_members (
  quest_id text not null references public.raid_battles(quest_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (quest_id,user_id)
);
create table if not exists public.raid_actions (
  quest_id text not null,
  turn_no integer not null check (turn_no > 0),
  user_id uuid not null,
  action_type text not null default 'attack' check (action_type='attack'),
  created_at timestamptz not null default now(),
  primary key (quest_id,turn_no,user_id),
  foreign key (quest_id,user_id) references public.raid_members(quest_id,user_id) on delete cascade
);
create table if not exists public.raid_logs (
  id bigint generated always as identity primary key,
  quest_id text not null references public.raid_battles(quest_id) on delete restrict,
  turn_no integer not null,
  kind text not null,
  message text not null,
  created_at timestamptz not null default now()
);
create index if not exists raid_logs_quest_id_id_idx on public.raid_logs(quest_id,id desc);
alter table public.raid_battles enable row level security;
alter table public.raid_members enable row level security;
alter table public.raid_actions enable row level security;
alter table public.raid_logs enable row level security;
revoke all on public.raid_battles,public.raid_members,public.raid_actions,public.raid_logs from public,anon,authenticated;
commit;
