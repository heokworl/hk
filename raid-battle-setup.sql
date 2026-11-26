begin;

-- raid-battle-1-schema.sql
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

-- raid-battle-2-access.sql
create or replace function public.raid_can_access_v1(p_quest_id text)
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null
    and exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.active and q.category='raid')
    and exists(select 1 from public.quest_participants p where p.quest_id=p_quest_id and p.user_id=auth.uid())
    and not exists(select 1 from public.quest_entry_blocks b where b.user_id=auth.uid() and b.quest_key in ('*',p_quest_id));
$$;
revoke all on function public.raid_can_access_v1(text) from public,anon;
grant execute on function public.raid_can_access_v1(text) to authenticated;
drop policy if exists raid_participant_read on public.raid_battles;
create policy raid_participant_read on public.raid_battles for select to authenticated
  using (public.raid_can_access_v1(quest_id));
grant select on public.raid_battles to authenticated;

-- Keep the roster fixed after start, even when an older join RPC is used.
create or replace function public.raid_guard_join_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.quest_limits q where q.quest_id=new.quest_id for update;
  if exists(select 1 from public.raid_battles r where r.quest_id=new.quest_id and r.state<>'waiting') then
    raise exception '이미 시작된 토벌에는 새로 참여할 수 없습니다.' using errcode='22023';
  end if;
  return new;
end;
$$;
revoke all on function public.raid_guard_join_v1() from public,anon,authenticated;
drop trigger if exists raid_guard_join on public.quest_participants;
create trigger raid_guard_join before insert on public.quest_participants
  for each row execute function public.raid_guard_join_v1();

-- raid-battle-3-resolve.sql
-- Internal resolver. All callers lock the battle row before calling this function.
create or replace function public.raid_resolve_turn_v1(p_quest_id text)
returns void language plpgsql security definer set search_path='' as $$
declare
  b public.raid_battles%rowtype;
  actor record;
  eligible integer;
  submitted integer;
  damage integer;
  hits integer:=0;
begin
  select * into b from public.raid_battles where quest_id=p_quest_id for update;
  if not found or b.state<>'active' then return; end if;
  -- Stable lock order prevents concurrent item healing from overwriting combat HP.
  perform p.user_id from public.guild_profiles p join public.raid_members m on m.user_id=p.user_id
    where m.quest_id=p_quest_id order by p.user_id for update of p;
  select count(*),count(a.user_id) into eligible,submitted
    from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id
    left join public.raid_actions a on a.quest_id=m.quest_id and a.user_id=m.user_id and a.turn_no=b.turn_no
    where m.quest_id=p_quest_id and p.hp>0
      and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id));
  if eligible=0 then
    update public.raid_battles set state='defeat',finished_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
    insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'defeat','전투 가능한 참여자가 없어 공략에 실패했습니다.');
    return;
  end if;
  if submitted<eligible then return; end if;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'resolve','전원 행동 완료 · 이번 턴의 효과를 적용합니다.');
  for actor in
    select p.user_id,p.username from public.raid_actions a
    join public.guild_profiles p on p.user_id=a.user_id
    where a.quest_id=p_quest_id and a.turn_no=b.turn_no and p.hp>0
      and not exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id))
    order by a.created_at,a.user_id
  loop
    damage:=least(b.boss_hp,b.player_damage);
    b.boss_hp:=b.boss_hp-damage;
    hits:=hits+1;
    insert into public.raid_logs(quest_id,turn_no,kind,message)
      values(p_quest_id,b.turn_no,'attack',actor.username||'의 공격 · 보스 HP -'||damage::text);
  end loop;
  if b.boss_hp=0 then
    update public.raid_battles set boss_hp=0,state='victory',finished_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
    insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'victory','보스를 처치했습니다. 토벌 성공! 보상은 관리자 지급을 기다려 주세요.');
    return;
  end if;
  for actor in
    select p.user_id,p.username,p.hp from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id
    where m.quest_id=p_quest_id and p.hp>0
      and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))
    order by p.user_id
  loop
    damage:=least(actor.hp,b.boss_damage);
    update public.guild_profiles set hp=greatest(0,hp-b.boss_damage) where user_id=actor.user_id;
    insert into public.raid_logs(quest_id,turn_no,kind,message)
      values(p_quest_id,b.turn_no,'counter',actor.username||'에게 보스 반격 · HP -'||damage::text);
  end loop;
  if not exists(select 1 from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id
    where m.quest_id=p_quest_id and p.hp>0
    and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))) then
    update public.raid_battles set boss_hp=b.boss_hp,state='defeat',finished_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
    insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'defeat','참여자 전원이 전투 불능이 되어 공략에 실패했습니다.');
  else
    update public.raid_battles set boss_hp=b.boss_hp,turn_no=turn_no+1,revision=revision+1,updated_at=now() where quest_id=p_quest_id;
    insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no+1,'turn',(b.turn_no+1)::text||'턴을 시작합니다.');
  end if;
end;
$$;
revoke all on function public.raid_resolve_turn_v1(text) from public,anon,authenticated;

-- raid-battle-4-read.sql
create or replace function public.raid_get_state_v1(p_quest_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; members jsonb; logs jsonb; can_start boolean;
begin
  if not public.raid_can_access_v1(p_quest_id) then
    raise exception '참여한 토벌 퀘스트만 볼 수 있습니다.' using errcode='42501';
  end if;
  insert into public.raid_battles(quest_id) values(p_quest_id) on conflict(quest_id) do nothing;
  select * into b from public.raid_battles where quest_id=p_quest_id for update;
  perform public.raid_resolve_turn_v1(p_quest_id);
  select * into b from public.raid_battles where quest_id=p_quest_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',p.user_id,'username',p.username,'hp',p.hp,'mp',p.mp,
    'blocked',exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id)),
    'acted',exists(select 1 from public.raid_actions a where a.quest_id=p_quest_id and a.turn_no=b.turn_no and a.user_id=p.user_id)
  ) order by p.username_key),'[]'::jsonb) into members
  from public.guild_profiles p where
    (b.state='waiting' and exists(select 1 from public.quest_participants q where q.quest_id=p_quest_id and q.user_id=p.user_id))
    or (b.state<>'waiting' and exists(select 1 from public.raid_members m where m.quest_id=p_quest_id and m.user_id=p.user_id));
  select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into logs
    from (select id,turn_no,kind,message,created_at from public.raid_logs where quest_id=p_quest_id order by id desc limit 100) l;
  can_start:=b.state='waiting' and exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.awarded_at is null);
  return jsonb_build_object('quest_id',b.quest_id,'state',b.state,'turn_no',b.turn_no,
    'boss_name',b.boss_name,'boss_hp',b.boss_hp,'boss_max_hp',b.boss_max_hp,
    'player_damage',b.player_damage,'boss_damage',b.boss_damage,
    'revision',b.revision,'members',members,'logs',logs,'can_start',can_start,
    'has_older_logs',(select count(*)>100 from public.raid_logs where quest_id=p_quest_id));
end;
$$;
create or replace function public.raid_get_logs_v1(p_quest_id text,p_before_id bigint)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not public.raid_can_access_v1(p_quest_id) then
    raise exception '참여한 토벌 퀘스트만 볼 수 있습니다.' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into result
    from (select id,turn_no,kind,message,created_at from public.raid_logs
      where quest_id=p_quest_id and id<p_before_id order by id desc limit 100) l;
  return result;
end;
$$;
revoke all on function public.raid_get_state_v1(text) from public,anon;
revoke all on function public.raid_get_logs_v1(text,bigint) from public,anon;
grant execute on function public.raid_get_state_v1(text) to authenticated;
grant execute on function public.raid_get_logs_v1(text,bigint) to authenticated;

-- raid-battle-5-actions.sql
create or replace function public.raid_start_v1(p_quest_id text)
returns text language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; u record;
begin
  if not public.raid_can_access_v1(p_quest_id) then raise exception '참여 권한이 없습니다.' using errcode='42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('raid-start',0));
  perform 1 from public.quest_limits q where q.quest_id=p_quest_id and q.awarded_at is null for update;
  if not found then raise exception '보상이 지급된 퀘스트는 시작할 수 없습니다.'; end if;
  insert into public.raid_battles(quest_id) values(p_quest_id) on conflict(quest_id) do nothing;
  select * into b from public.raid_battles where quest_id=p_quest_id for update;
  if b.state<>'waiting' then return 'already_started'; end if;
  if exists(select 1 from public.quest_participants q
    join public.raid_members m on m.user_id=q.user_id
    join public.raid_battles r on r.quest_id=m.quest_id
    where q.quest_id=p_quest_id and r.state='active' and r.quest_id<>p_quest_id) then
    raise exception '참여자 중 다른 토벌을 공략 중인 이용자가 있습니다.';
  end if;
  perform p.user_id from public.guild_profiles p join public.quest_participants q on q.user_id=p.user_id
    where q.quest_id=p_quest_id order by p.user_id for update of p;
  insert into public.raid_members(quest_id,user_id)
    select p_quest_id,p.user_id from public.quest_participants q join public.guild_profiles p on p.user_id=q.user_id
    where q.quest_id=p_quest_id and not exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id))
    on conflict(quest_id,user_id) do nothing;
  if not exists(select 1 from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id where m.quest_id=p_quest_id and p.hp>0) then
    raise exception 'HP가 남아 있는 참여자가 필요합니다.';
  end if;
  update public.raid_battles set state='active',started_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
  insert into public.raid_logs(quest_id,turn_no,kind,message)
    values(p_quest_id,1,'start','공략 시작 · 보스 HP 1,000 / 공격 20 / 보스 반격 10. 참여 명단을 확정했습니다.');
  for u in select p.username from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id where m.quest_id=p_quest_id order by p.username_key loop
    insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,1,'member',u.username||' 공략 참여');
  end loop;
  return 'started';
end;
$$;
create or replace function public.raid_submit_action_v1(p_quest_id text,p_turn_no integer)
returns text language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; hp_now integer; actor_name text;
begin
  if not public.raid_can_access_v1(p_quest_id) then raise exception '참여 권한이 없습니다.' using errcode='42501'; end if;
  select * into b from public.raid_battles where quest_id=p_quest_id for update;
  if not found then raise exception '전투가 아직 시작되지 않았습니다.'; end if;
  if b.state<>'active' then return 'not_active'; end if;
  if p_turn_no is null or b.turn_no<>p_turn_no then return 'stale_turn'; end if;
  if not exists(select 1 from public.raid_members m where m.quest_id=p_quest_id and m.user_id=auth.uid()) then
    raise exception '전투 명단에 없는 이용자입니다.' using errcode='42501';
  end if;
  -- Use the same profile lock ordering as the resolver (including multi-window submissions).
  perform p.user_id from public.guild_profiles p join public.raid_members m on m.user_id=p.user_id
    where m.quest_id=p_quest_id order by p.user_id for update of p;
  select p.hp,p.username into hp_now,actor_name from public.guild_profiles p where p.user_id=auth.uid();
  if hp_now is null or hp_now<=0 then return 'incapacitated'; end if;
  insert into public.raid_actions(quest_id,turn_no,user_id) values(p_quest_id,p_turn_no,auth.uid()) on conflict do nothing;
  if not found then return 'already_acted'; end if;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,p_turn_no,'ready',actor_name||' · 공격 예약 완료');
  update public.raid_battles set revision=revision+1,updated_at=now() where quest_id=p_quest_id;
  perform public.raid_resolve_turn_v1(p_quest_id);
  return 'submitted';
end;
$$;
revoke all on function public.raid_start_v1(text) from public,anon;
revoke all on function public.raid_submit_action_v1(text,integer) from public,anon;
grant execute on function public.raid_start_v1(text) to authenticated;
grant execute on function public.raid_submit_action_v1(text,integer) to authenticated;
notify pgrst,'reload schema';

-- raid-battle-6-realtime.sql
-- Only the battle revision row is streamed. Logs, actions and profiles stay RPC-only.
do $$
begin
  if not exists(select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='raid_battles') then
    alter publication supabase_realtime add table public.raid_battles;
  end if;
end;
$$;
notify pgrst,'reload schema';
notify pgrst,'reload schema';
commit;
