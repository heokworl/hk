begin;
alter table public.quest_limits
 add column if not exists reward_amount integer not null default 0,
 add column if not exists reward_mode text not null default 'per_user',
 add column if not exists is_test_raid boolean not null default false;
create table if not exists public.quest_reward_payouts(
 quest_id text not null references public.quest_limits(quest_id),
 user_id uuid not null references auth.users(id) on delete cascade,
 amount integer not null check(amount>0),
 awarded_by uuid references auth.users(id),
 awarded_at timestamptz not null default now(),
 primary key(quest_id,user_id)
);
alter table public.quest_reward_payouts alter column awarded_by drop not null;
alter table public.quest_reward_payouts add column if not exists payout_source text not null default 'admin';
alter table public.quest_reward_payouts enable row level security;
revoke all on public.quest_reward_payouts from public,anon,authenticated;
alter table public.raid_battles
 add column if not exists rewards_settled_at timestamptz,
 add column if not exists reward_total bigint not null default 0;
create or replace function public.raid_settle_completion_v1(p_quest_id text)
returns void language plpgsql security definer set search_path='' as $$
declare q public.quest_limits%rowtype; b public.raid_battles%rowtype; n bigint; total bigint;
begin
 select * into q from public.quest_limits where quest_id=p_quest_id for update;
 select * into b from public.raid_battles where quest_id=p_quest_id for update;
 if not found or b.state not in ('victory','defeat') or b.rewards_settled_at is not null then return; end if;
 if b.state='victory' and q.awarded_at is null then
  select count(*) into n from public.raid_members where quest_id=p_quest_id;
  if n>0 and q.reward_amount>0 then
   if q.reward_mode='team_pool' then
    insert into public.quest_reward_payouts(quest_id,user_id,amount,awarded_by,payout_source)
    select p_quest_id,ranked.user_id,(q.reward_amount/n)::integer
       +case when ranked.position<=q.reward_amount%n then 1 else 0 end,null,'raid_auto'
    from (select m.user_id,row_number() over(order by m.user_id) as position
          from public.raid_members m where m.quest_id=p_quest_id) ranked
    where (q.reward_amount/n)::integer+case when ranked.position<=q.reward_amount%n then 1 else 0 end>0
    on conflict(quest_id,user_id) do nothing;
   else
    insert into public.quest_reward_payouts(quest_id,user_id,amount,awarded_by,payout_source)
    select p_quest_id,m.user_id,q.reward_amount,null,'raid_auto' from public.raid_members m where m.quest_id=p_quest_id
    on conflict(quest_id,user_id) do nothing;
   end if;
  end if;
  update public.quest_limits set awarded_at=now() where quest_id=p_quest_id;
 end if;
 select coalesce(sum(amount),0) into total from public.quest_reward_payouts where quest_id=p_quest_id;
 update public.quest_limits set recruitment_closed=true,raid_entry_enabled=false where quest_id=p_quest_id;
 update public.raid_battles set rewards_settled_at=now(),reward_total=total,revision=revision+1,updated_at=now() where quest_id=p_quest_id;
 insert into public.raid_logs(quest_id,turn_no,kind,message)
 values(p_quest_id,b.turn_no,'settlement',case when b.state='victory' then '토벌 성공 · 보상 정산 완료 · 총 '||total::text||'G' else '토벌 실패 · 보상 없이 종료되었습니다.' end);
end;
$$;
create or replace function public.raid_settle_completion_trigger_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin perform public.raid_settle_completion_v1(new.quest_id);return new;end;
$$;
drop trigger if exists raid_settle_completion on public.raid_battles;
create trigger raid_settle_completion after update of state on public.raid_battles
 for each row when(new.state in ('victory','defeat') and old.state is distinct from new.state)
 execute function public.raid_settle_completion_trigger_v1();
create or replace function public.raid_terminal_status_v1(p_quest_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b public.raid_battles%rowtype;
begin
 if auth.uid() is null or not exists(select 1 from public.quest_participants p where p.quest_id=p_quest_id and p.user_id=auth.uid()) then
  raise exception '참여한 토벌 퀘스트만 확인할 수 있습니다.' using errcode='42501';end if;
 select * into b from public.raid_battles where quest_id=p_quest_id and state in ('victory','defeat');
 if not found then return null;end if;
 return jsonb_build_object('quest_id',b.quest_id,'state',b.state,'finished',true,'revision',b.revision,
  'user_reward',coalesce((select p.amount from public.quest_reward_payouts p where p.quest_id=p_quest_id and p.user_id=auth.uid()),0),
  'reward_total',b.reward_total,'rewards_settled',b.rewards_settled_at is not null,
  'is_test',(select q.is_test_raid from public.quest_limits q where q.quest_id=p_quest_id));
end;
$$;
-- Terminal notifications must still reach party members after entry is closed.
create or replace function public.raid_can_observe_v2(p_quest_id text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (public.raid_can_access_v1(p_quest_id)
 or (exists(select 1 from public.raid_battles b where b.quest_id=p_quest_id and b.state in ('victory','defeat'))
 and exists(select 1 from public.raid_members m where m.quest_id=p_quest_id and m.user_id=auth.uid())));
$$;
revoke all on function public.raid_settle_completion_v1(text) from public,anon,authenticated;
revoke all on function public.raid_settle_completion_trigger_v1() from public,anon,authenticated;
revoke all on function public.raid_terminal_status_v1(text) from public,anon,authenticated;
revoke all on function public.raid_can_observe_v2(text) from public,anon;
grant execute on function public.raid_can_observe_v2(text) to authenticated;
drop policy if exists raid_participant_read on public.raid_battles;
create policy raid_participant_read on public.raid_battles for select to authenticated
 using(public.raid_can_observe_v2(quest_id));

create or replace function public.raid_get_state_v1(p_quest_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; members jsonb; logs jsonb; can_start boolean; inventory jsonb;
begin
  if exists(select 1 from public.raid_battles r where r.quest_id=p_quest_id and r.state in ('victory','defeat')) then
    return public.raid_terminal_status_v1(p_quest_id);
  end if;
  if not public.raid_can_access_v1(p_quest_id) then
    raise exception '참여한 토벌 퀘스트만 볼 수 있습니다.' using errcode='42501';
  end if;
  perform 1 from public.quest_limits q where q.quest_id=p_quest_id for update;
  insert into public.raid_battles(quest_id) values(p_quest_id) on conflict(quest_id) do nothing;
  select * into b from public.raid_battles where quest_id=p_quest_id for update;
  perform public.raid_resolve_turn_v1(p_quest_id);
  select * into b from public.raid_battles where quest_id=p_quest_id;
  if b.state in ('victory','defeat') then return public.raid_terminal_status_v1(p_quest_id);end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',p.user_id,'username',p.username,'hp',p.hp,'mp',p.mp,
    'blocked',exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id)),
    'turn_required',(p.hp>0 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id))),
    'can_target',(exists(select 1 from public.quest_admins x where x.user_id=auth.uid()) or not exists(select 1 from public.quest_admins x where x.user_id=p.user_id)),
    'acted',exists(select 1 from public.raid_actions a where a.quest_id=p_quest_id and a.turn_no=b.turn_no and a.user_id=p.user_id)
  ) order by p.username_key),'[]'::jsonb) into members
  from public.guild_profiles p where
    (b.state='waiting' and exists(select 1 from public.quest_participants q where q.quest_id=p_quest_id and q.user_id=p.user_id))
    or (b.state<>'waiting' and exists(select 1 from public.raid_members m where m.quest_id=p_quest_id and m.user_id=p.user_id));
  select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into logs
    from (select id,turn_no,kind,message,created_at from public.raid_logs where quest_id=p_quest_id order by id desc limit 100) l;
  can_start:=b.state='waiting' and exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.awarded_at is null);
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_id',i.item_id,'item_name',i.item_name,'description',i.description,
    'quantity',greatest(i.quantity-public.raid_item_reserved_v2(auth.uid(),i.item_id),0),
    'reserved',public.raid_item_reserved_v2(auth.uid(),i.item_id),
    'hp_restore',s.hp_restore,'mp_restore',s.mp_restore
  ) order by i.item_name),'[]'::jsonb) into inventory
  from public.get_my_inventory() i join public.shop_items s on s.id=i.item_id;
  return jsonb_build_object('inventory',inventory,'quest_id',b.quest_id,'state',b.state,'turn_no',b.turn_no,
    'boss_kind',b.boss_kind,'boss_name',b.boss_name,'boss_hp',b.boss_hp,'boss_max_hp',b.boss_max_hp,
    'player_damage',b.player_damage,'boss_damage',b.boss_damage,
    'required_count',(select count(*) from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id where m.quest_id=p_quest_id and p.hp>0 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))),
    'ready_count',(select count(*) from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id join public.raid_actions a on a.quest_id=m.quest_id and a.user_id=m.user_id and a.turn_no=b.turn_no where m.quest_id=p_quest_id and p.hp>0 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))),
    'revision',b.revision,'members',members,'logs',logs,'can_start',can_start,
    'has_older_logs',(select count(*)>100 from public.raid_logs where quest_id=p_quest_id));
end;
$$;
create or replace function public.raid_submit_choice_v2(p_quest_id text,p_turn_no integer,p_action text,p_item_id text default null,p_target_user_id uuid default null)
returns text language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; hp_now integer; actor_name text; i public.shop_items%rowtype; target public.guild_profiles%rowtype; locked_member record;
begin
 if not public.raid_can_access_v1(p_quest_id) then raise exception '모집 마감과 관리자 입장 활성화, 참여 기록을 확인해 주세요.' using errcode='42501'; end if;
 if p_action is null or p_action not in ('attack','item') then raise exception '알 수 없는 행동입니다.'; end if;
 perform 1 from public.quest_limits q where q.quest_id=p_quest_id for update;
 select * into b from public.raid_battles where quest_id=p_quest_id for update;
 if not found then raise exception '전투가 아직 시작되지 않았습니다.'; end if;
 if b.state<>'active' then return 'not_active'; end if;
 if p_turn_no is null or b.turn_no<>p_turn_no then return 'stale_turn'; end if;
 if not exists(select 1 from public.raid_members x where x.quest_id=p_quest_id and x.user_id=auth.uid()) then raise exception '전투 명단에 없는 이용자입니다.' using errcode='42501'; end if;
 if exists(select 1 from public.raid_actions a where a.quest_id=p_quest_id and a.turn_no=p_turn_no and a.user_id=auth.uid()) then return 'already_acted'; end if;
 for locked_member in select user_id from public.raid_members where quest_id=p_quest_id order by user_id loop
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||locked_member.user_id::text,0));
 end loop;
 perform p.user_id from public.guild_profiles p join public.raid_members m on m.user_id=p.user_id where m.quest_id=p_quest_id order by p.user_id for update of p;
 select p.hp,p.username into hp_now,actor_name from public.guild_profiles p where p.user_id=auth.uid();
 if hp_now is null or hp_now<=0 then return 'incapacitated'; end if;
 if p_action='item' then
  select * into i from public.shop_items where id=p_item_id;
  if not found then raise exception '아이템을 찾을 수 없습니다.'; end if;
  if public.raid_item_quantity_v2(auth.uid(),p_item_id)-public.raid_item_reserved_v2(auth.uid(),p_item_id)<1 then return 'not_owned'; end if;
  select p.* into target from public.guild_profiles p join public.raid_members m on m.user_id=p.user_id
   where p.user_id=p_target_user_id and m.quest_id=p_quest_id
   and not exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id));
  if not found then raise exception '같은 토벌의 참여자를 대상으로 선택해 주세요.'; end if;
  if not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) and exists(select 1 from public.quest_admins a where a.user_id=p_target_user_id) then
   raise exception '관리자 계정은 대상으로 선택할 수 없습니다.' using errcode='42501'; end if;
  if (i.hp_restore>0 or i.mp_restore>0) and greatest(0,least(i.hp_restore,200-target.hp))+greatest(0,least(i.mp_restore,200-target.mp))=0 then return 'already_full'; end if;
 end if;
 insert into public.raid_actions(quest_id,turn_no,user_id,action_type,item_id,target_user_id)
  values(p_quest_id,p_turn_no,auth.uid(),p_action,case when p_action='item' then p_item_id end,case when p_action='item' then p_target_user_id end);
 insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,p_turn_no,'ready',actor_name||case when p_action='item' then ' · '||i.name||' → '||target.username||' 사용 예약' else ' · 공격 예약 완료' end);
 update public.raid_battles set revision=revision+1,updated_at=now() where quest_id=p_quest_id;
 perform public.raid_resolve_turn_v1(p_quest_id);
 return 'submitted';
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
  where quest_id = p_quest_id and active
  for update;

  if not found then
    raise exception 'unknown quest' using errcode = '22023';
  end if;
  if v_awarded_at is not null then
    return 'already_awarded';
  end if;

  if exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.category='raid') then
    if not exists(select 1 from public.raid_battles b where b.quest_id=p_quest_id and b.state='victory') then
      raise exception '토벌 보상은 공략 성공 즉시 자동 지급됩니다.';
    end if;
    perform public.raid_settle_completion_v1(p_quest_id);
    return 'awarded';
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
-- Settle previously completed, unpaid victories once; never reset active battles.
do $$
declare r record;
begin
 for r in select quest_id from public.raid_battles where state in ('victory','defeat') and rewards_settled_at is null order by quest_id loop
  perform public.raid_settle_completion_v1(r.quest_id);
 end loop;
end;
$$;
notify pgrst,'reload schema';
commit;

