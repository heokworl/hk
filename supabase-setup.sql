-- Run once in Supabase Dashboard > SQL Editor.
-- Also turn off Authentication > Providers > Email > Confirm email, because accounts use names and passwords without email addresses.
-- This design hides participant rows and names from browser clients. The site only receives counts and the current user's own joined status.
create table if not exists public.quest_limits (
  quest_id text primary key,
  max_members integer not null check (max_members > 0)
);

insert into public.quest_limits (quest_id, max_members) values
  ('lantern', 3), ('herbs', 4), ('bridge', 2)
on conflict (quest_id) do update set max_members = excluded.max_members;

create table if not exists public.quest_participants (
  quest_id text not null references public.quest_limits(quest_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (quest_id, user_id)
);

alter table public.quest_limits enable row level security;
alter table public.quest_participants enable row level security;

-- Browser clients cannot read, insert, update, or delete raw records.
revoke all on public.quest_limits from anon, authenticated;
revoke all on public.quest_participants from anon, authenticated;

create or replace function public.get_quest_status()
returns table (quest_id text, participant_count bigint, has_joined boolean)
language sql
security definer
set search_path = ''
as $$
  select q.quest_id,
         (select count(*) from public.quest_participants p where p.quest_id = q.quest_id),
         exists (
           select 1 from public.quest_participants p
           where p.quest_id = q.quest_id and p.user_id = auth.uid()
         )
  from public.quest_limits q
  order by q.quest_id;
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
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_quest_id, 0));

  select max_members into v_max
  from public.quest_limits
  where quest_id = p_quest_id;

  if v_max is null then
    raise exception 'unknown quest' using errcode = '22023';
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

revoke all on function public.get_quest_status() from public;
revoke all on function public.join_quest(text) from public;
grant execute on function public.get_quest_status() to anon, authenticated;
grant execute on function public.join_quest(text) to authenticated;
