-- Run this in Supabase Dashboard > SQL Editor; it can be rerun to apply these updates.
-- Browser clients never get direct access to participant, admin, wallet, or payout rows.
-- Name/password signup also requires email auth enabled and mailer_autoconfirm=true in project Auth config.
-- To grant administrator access, create the trusted 관리자 account first, copy its UUID
-- from Authentication > Users, then run the INSERT shown at the end of this file.

create table if not exists public.quest_limits (
  quest_id text primary key,
  max_members integer not null check (max_members > 0)
);

alter table public.quest_limits
  add column if not exists reward_amount integer not null default 0,
  add column if not exists reward_mode text not null default 'per_user',
  add column if not exists awarded_at timestamptz;

insert into public.quest_limits (quest_id, max_members, reward_amount, reward_mode) values
  ('lantern', 3, 120, 'per_user'),
  ('herbs', 4, 90, 'team_pool'),
  ('bridge', 2, 160, 'per_user')
on conflict (quest_id) do update set
  max_members = excluded.max_members,
  reward_amount = excluded.reward_amount,
  reward_mode = excluded.reward_mode;

create table if not exists public.quest_participants (
  quest_id text not null references public.quest_limits(quest_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (quest_id, user_id)
);

create table if not exists public.quest_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);

create table if not exists public.quest_reward_payouts (
  quest_id text not null references public.quest_limits(quest_id),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null check (amount > 0),
  awarded_by uuid not null references auth.users(id),
  awarded_at timestamptz not null default now(),
  primary key (quest_id, user_id)
);

alter table public.quest_limits enable row level security;
alter table public.quest_participants enable row level security;
alter table public.quest_admins enable row level security;
alter table public.quest_reward_payouts enable row level security;

revoke all on public.quest_limits from anon, authenticated;
revoke all on public.quest_participants from anon, authenticated;
revoke all on public.quest_admins from anon, authenticated;
revoke all on public.quest_reward_payouts from anon, authenticated;

drop function if exists public.get_quest_status();
create function public.get_quest_status()
returns table (
  quest_id text,
  participant_count bigint,
  has_joined boolean,
  reward_amount integer,
  reward_mode text,
  awarded boolean
)
language sql
security definer
set search_path = ''
as $$
  select q.quest_id,
         (select count(*) from public.quest_participants p where p.quest_id = q.quest_id),
         exists (
           select 1 from public.quest_participants p
           where p.quest_id = q.quest_id and p.user_id = auth.uid()
         ),
         q.reward_amount,
         q.reward_mode,
         q.awarded_at is not null
  from public.quest_limits q
  order by q.quest_id;
$$;

create or replace function public.get_my_wallet()
returns table (balance bigint, is_admin boolean)
language sql
security definer
stable
set search_path = ''
as $$
  select coalesce((
           select sum(p.amount)::bigint
           from public.quest_reward_payouts p
           where p.user_id = auth.uid()
         ), 0),
         exists (
           select 1 from public.quest_admins a where a.user_id = auth.uid()
         );
$$;

create or replace function public.join_quest(p_quest_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_max integer;
  v_count integer;
  v_awarded_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_quest_id, 0));

  select max_members, awarded_at into v_max, v_awarded_at
  from public.quest_limits
  where quest_id = p_quest_id;

  if v_max is null then
    raise exception 'unknown quest' using errcode = '22023';
  end if;
  if v_awarded_at is not null then
    return 'closed';
  end if;
  if exists (
    select 1 from public.quest_participants
    where quest_id = p_quest_id and user_id = v_user_id
  ) then
    return 'already_joined';
  end if;

  select count(*) into v_count
  from public.quest_participants
  where quest_id = p_quest_id;

  if v_count >= v_max then
    return 'full';
  end if;

  insert into public.quest_participants (quest_id, user_id)
  values (p_quest_id, v_user_id);

  return 'joined';
end;
$$;

create or replace function public.award_quest(p_quest_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_id uuid := auth.uid();
  v_reward integer;
  v_mode text;
  v_awarded_at timestamptz;
  v_participants bigint;
begin
  if v_admin_id is null or not exists (
    select 1 from public.quest_admins a where a.user_id = v_admin_id
  ) then
    raise exception 'administrator access required' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_quest_id, 0));

  select reward_amount, reward_mode, awarded_at
    into v_reward, v_mode, v_awarded_at
  from public.quest_limits
  where quest_id = p_quest_id
  for update;

  if not found then
    raise exception 'unknown quest' using errcode = '22023';
  end if;
  if v_awarded_at is not null then
    return 'already_awarded';
  end if;

  select count(*) into v_participants
  from public.quest_participants p
  where p.quest_id = p_quest_id;
  if v_participants = 0 then
    return 'no_participants';
  end if;

  if v_mode = 'team_pool' then
    insert into public.quest_reward_payouts (quest_id, user_id, amount, awarded_by)
    select p_quest_id,
           ranked.user_id,
           (v_reward / v_participants)::integer
             + case when ranked.position <= (v_reward % v_participants) then 1 else 0 end,
           v_admin_id
    from (
      select p.user_id,
             row_number() over (order by p.joined_at, p.user_id) as position
      from public.quest_participants p
      where p.quest_id = p_quest_id
    ) ranked
    where (v_reward / v_participants)::integer
             + case when ranked.position <= (v_reward % v_participants) then 1 else 0 end > 0;
  else
    insert into public.quest_reward_payouts (quest_id, user_id, amount, awarded_by)
    select p_quest_id, p.user_id, v_reward, v_admin_id
    from public.quest_participants p
    where p.quest_id = p_quest_id;
  end if;

  update public.quest_limits
  set awarded_at = pg_catalog.now()
  where quest_id = p_quest_id;

  return 'awarded';
end;
$$;

revoke all on function public.get_quest_status() from public;
revoke all on function public.get_my_wallet() from public;
revoke all on function public.join_quest(text) from public;
revoke all on function public.award_quest(text) from public;
grant execute on function public.get_quest_status() to anon, authenticated;
grant execute on function public.get_my_wallet() to authenticated;
grant execute on function public.join_quest(text) to authenticated;
grant execute on function public.award_quest(text) to authenticated;

-- Run once after creating the trusted 관리자 account. Replace the UUID with the ID
-- shown for that account in Authentication > Users. Never grant admin by display name.
-- insert into public.quest_admins (user_id) values ('PASTE-ADMIN-USER-UUID-HERE')
-- on conflict (user_id) do nothing;
