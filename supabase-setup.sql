-- Run this in Supabase Dashboard > SQL Editor; it can be rerun to apply these updates.
-- Browser clients never get direct access to participant, admin, wallet, or payout rows.
-- Name/password signup also requires email auth enabled and mailer_autoconfirm=true in project Auth config.
-- The trusted 관리자 account UUID is granted administrator access below.

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

create table if not exists public.guild_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  username_key text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.shop_items (
  id text primary key,
  name text not null,
  description text not null default '',
  price_g integer not null check (price_g > 0),
  active boolean not null default true
);

insert into public.shop_items (id, name, description, price_g) values
  ('healing-potion', '초급 회복약', '작은 상처와 피로를 달래는 기본 회복 물약.', 50),
  ('antidote', '해독제', '흔한 독과 독초의 영향을 완화하는 약.', 40),
  ('camp-kit', '야영 도구', '야외 탐사에 필요한 간단한 야영 장비 묶음.', 80)
on conflict (id) do nothing;

create table if not exists public.shop_purchases (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id text not null references public.shop_items(id) on delete restrict,
  price_paid integer not null check (price_paid > 0),
  purchased_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

insert into public.guild_profiles (user_id, username, username_key)
select u.id,
       btrim(u.raw_user_meta_data->>'user_name'),
       lower(btrim(u.raw_user_meta_data->>'user_name'))
from auth.users u
where nullif(btrim(u.raw_user_meta_data->>'user_name'), '') is not null
on conflict (user_id) do update set
  username = excluded.username,
  username_key = excluded.username_key;

create or replace function public.create_guild_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(new.raw_user_meta_data->>'user_name', ''));
begin
  if v_name = '' or char_length(v_name) > 40 then
    raise exception 'A username between 1 and 40 characters is required';
  end if;

  insert into public.guild_profiles (user_id, username, username_key)
  values (new.id, v_name, lower(v_name));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_guild_profile on auth.users;
create trigger on_auth_user_created_guild_profile
after insert on auth.users
for each row execute function public.create_guild_profile();

alter table public.quest_limits enable row level security;
alter table public.quest_participants enable row level security;
alter table public.quest_admins enable row level security;
alter table public.quest_reward_payouts enable row level security;
alter table public.guild_profiles enable row level security;
alter table public.shop_items enable row level security;
alter table public.shop_purchases enable row level security;

revoke all on public.quest_limits from anon, authenticated;
revoke all on public.quest_participants from anon, authenticated;
revoke all on public.quest_admins from anon, authenticated;
revoke all on public.quest_reward_payouts from anon, authenticated;
revoke all on public.guild_profiles from anon, authenticated;
revoke all on public.shop_items from anon, authenticated;
revoke all on public.shop_purchases from anon, authenticated;

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

drop function if exists public.get_my_wallet();
create function public.get_my_wallet()
returns table (username text, balance bigint, is_admin boolean)
language sql
security definer
stable
set search_path = ''
as $$
  select coalesce((select p.username from public.guild_profiles p where p.user_id = auth.uid()), '모험가'),
         coalesce((
           select sum(p.amount)::bigint
           from public.quest_reward_payouts p
           where p.user_id = auth.uid()
         ), 0) - coalesce((
           select sum(p.price_paid)::bigint
           from public.shop_purchases p
           where p.user_id = auth.uid()
         ), 0),
         exists (
           select 1 from public.quest_admins a where a.user_id = auth.uid()
         );
$$;

create or replace function public.get_shop_items()
returns table (item_id text, item_name text, description text, price_g integer, owned boolean)
language sql
security definer
stable
set search_path = ''
as $$
  select i.id, i.name, i.description, i.price_g,
         exists (
           select 1 from public.shop_purchases p
           where p.user_id = auth.uid() and p.item_id = i.id
         )
  from public.shop_items i
  where i.active
  order by i.price_g, i.name;
$$;

create or replace function public.get_my_purchases()
returns table (item_id text, item_name text, description text, price_paid integer, purchased_at timestamptz)
language sql
security definer
stable
set search_path = ''
as $$
  select p.item_id, i.name, i.description, p.price_paid, p.purchased_at
  from public.shop_purchases p
  join public.shop_items i on i.id = p.item_id
  where p.user_id = auth.uid()
  order by p.purchased_at desc;
$$;

create or replace function public.purchase_shop_item(p_item_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_price integer;
  v_balance bigint;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:' || v_user_id::text, 0));

  select i.price_g into v_price
  from public.shop_items i
  where i.id = p_item_id and i.active
  for share;

  if v_price is null then
    raise exception 'shop item unavailable' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.shop_purchases p
    where p.user_id = v_user_id and p.item_id = p_item_id
  ) then
    return 'already_owned';
  end if;

  select coalesce((select sum(p.amount)::bigint from public.quest_reward_payouts p where p.user_id = v_user_id), 0)
       - coalesce((select sum(p.price_paid)::bigint from public.shop_purchases p where p.user_id = v_user_id), 0)
    into v_balance;

  if v_balance < v_price then
    return 'insufficient_funds';
  end if;

  insert into public.shop_purchases (user_id, item_id, price_paid)
  values (v_user_id, p_item_id, v_price);

  return 'purchased';
end;
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
revoke all on function public.get_shop_items() from public;
revoke all on function public.get_my_purchases() from public;
revoke all on function public.purchase_shop_item(text) from public;
revoke all on function public.create_guild_profile() from public;
revoke all on function public.join_quest(text) from public;
revoke all on function public.award_quest(text) from public;
grant execute on function public.get_quest_status() to anon, authenticated;
grant execute on function public.get_my_wallet() to authenticated;
grant execute on function public.get_shop_items() to anon, authenticated;
grant execute on function public.get_my_purchases() to authenticated;
grant execute on function public.purchase_shop_item(text) to authenticated;
grant execute on function public.join_quest(text) to authenticated;
grant execute on function public.award_quest(text) to authenticated;

-- Grant admin by immutable user ID, never by the editable display name.
insert into public.quest_admins (user_id)
select id from auth.users where id = '34a5e4ea-2b47-4714-a08b-6dacb0a018e7'::uuid
on conflict (user_id) do nothing;
