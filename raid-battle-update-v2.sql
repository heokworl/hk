begin;
-- 01-schema-and-gates.sql
alter table public.quest_limits
 add column if not exists recruitment_closed boolean not null default false,
 add column if not exists raid_entry_enabled boolean not null default false;
alter table public.shop_items
 add column if not exists hp_restore integer not null default 0 check(hp_restore between 0 and 200),
 add column if not exists mp_restore integer not null default 0 check(mp_restore between 0 and 200);
update public.shop_items set hp_restore=20 where id='healing-potion' and hp_restore=0;
alter table public.shop_item_uses
 add column if not exists target_user_id uuid references auth.users(id) on delete set null,
 add column if not exists hp_restored integer not null default 0,
 add column if not exists mp_restored integer not null default 0,
 add column if not exists raid_quest_id text,
 add column if not exists raid_turn_no integer;
alter table public.raid_actions drop constraint if exists raid_actions_action_type_check;
alter table public.raid_actions add constraint raid_actions_action_type_check check(action_type in ('attack','item'));
alter table public.raid_actions
 add column if not exists item_id text references public.shop_items(id) on delete restrict,
 add column if not exists target_user_id uuid references auth.users(id) on delete set null,
 add column if not exists resolved_at timestamptz;
update public.raid_actions a set resolved_at=now() from public.raid_battles b
 where b.quest_id=a.quest_id and a.resolved_at is null and (a.turn_no<b.turn_no or b.state in ('victory','defeat'));
create unique index if not exists shop_item_uses_raid_action_uidx
 on public.shop_item_uses(raid_quest_id,raid_turn_no,user_id) where raid_quest_id is not null;
do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.shop_item_uses'::regclass and conname='shop_item_uses_raid_action_fk') then
  alter table public.shop_item_uses add constraint shop_item_uses_raid_action_fk
   foreign key(raid_quest_id,raid_turn_no,user_id) references public.raid_actions(quest_id,turn_no,user_id);
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.shop_item_uses'::regclass and conname='shop_item_uses_raid_pair_check') then
  alter table public.shop_item_uses add constraint shop_item_uses_raid_pair_check
   check((raid_quest_id is null)=(raid_turn_no is null));
 end if;
end;
$$;

create or replace function public.admin_set_quest_gate_v2(p_quest_id text,p_command text)
returns text language plpgsql security definer set search_path='' as $$
declare q public.quest_limits%rowtype;
begin
 if auth.uid() is null or not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) then
  raise exception '관리자만 변경할 수 있습니다.' using errcode='42501'; end if;
 select * into q from public.quest_limits where quest_id=p_quest_id for update;
 if not found then raise exception '해당 퀘스트를 찾을 수 없습니다.'; end if;
 if q.awarded_at is not null then raise exception '보상이 지급된 퀘스트는 변경할 수 없습니다.'; end if;
 if p_command='close' then
  update public.quest_limits set recruitment_closed=true,raid_entry_enabled=false where quest_id=p_quest_id;
 elsif p_command='enable' then
  if q.category<>'raid' or not q.recruitment_closed then raise exception '토벌 모집을 먼저 마감해 주세요.'; end if;
  update public.quest_limits set raid_entry_enabled=true where quest_id=p_quest_id;
 elsif p_command='disable' then
  update public.quest_limits set raid_entry_enabled=false where quest_id=p_quest_id;
 elsif p_command='reopen' then
  if exists(select 1 from public.raid_battles b where b.quest_id=p_quest_id and b.state<>'waiting') then
   raise exception '이미 시작한 토벌의 모집은 다시 열 수 없습니다.'; end if;
  update public.quest_limits set recruitment_closed=false,raid_entry_enabled=false where quest_id=p_quest_id;
 else raise exception '알 수 없는 명령입니다.'; end if;
 return 'saved';
end;
$$;

create or replace function public.raid_can_access_v1(p_quest_id text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
 and exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.active and q.category='raid' and q.recruitment_closed and q.raid_entry_enabled)
 and exists(select 1 from public.quest_participants p where p.quest_id=p_quest_id and p.user_id=auth.uid())
 and not exists(select 1 from public.quest_entry_blocks b where b.user_id=auth.uid() and b.quest_key in ('*',p_quest_id));
$$;
create or replace function public.raid_guard_join_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare closed boolean;
begin
 select q.recruitment_closed into closed from public.quest_limits q where q.quest_id=new.quest_id for update;
 if closed then raise exception '관리자가 모집을 마감한 퀘스트입니다.' using errcode='22023'; end if;
 if exists(select 1 from public.raid_battles r where r.quest_id=new.quest_id and r.state<>'waiting') then
  raise exception '이미 시작된 토벌에는 새로 참여할 수 없습니다.' using errcode='22023'; end if;
 return new;
end;
$$;
create or replace function public.get_quest_details_v3()
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
  'quest_id',q.quest_id,'category',q.category,'game_version',q.game_version,
  'recruitment_closed',q.recruitment_closed,'raid_entry_enabled',q.raid_entry_enabled,
  'battle_started',exists(select 1 from public.raid_battles r where r.quest_id=q.quest_id and r.state<>'waiting'),
  'blocked',exists(select 1 from public.quest_entry_blocks b where b.user_id=auth.uid() and b.quest_key in ('*',q.quest_id)),
  'participants',coalesce((select jsonb_agg(p.username order by e.joined_at)
   from public.quest_participants e join public.guild_profiles p on p.user_id=e.user_id where e.quest_id=q.quest_id),'[]'::jsonb)
 )),'[]'::jsonb) from public.quest_limits q where q.active and auth.uid() is not null;
$$;
create or replace function public.get_raid_page_v1(p_quest_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.raid_can_access_v1(p_quest_id) then
  raise exception '모집 마감 후 관리자 입장 활성화가 필요합니다. 참여 기록도 확인해 주세요.' using errcode='42501'; end if;
 return jsonb_build_object('quest_id',p_quest_id,'game_version',(select q.game_version from public.quest_limits q where q.quest_id=p_quest_id),'content','공유 토벌');
end;
$$;
revoke all on function public.admin_set_quest_gate_v2(text,text) from public,anon;
grant execute on function public.admin_set_quest_gate_v2(text,text) to authenticated;
revoke all on function public.get_quest_details_v3() from public,anon;
grant execute on function public.get_quest_details_v3() to authenticated;
revoke all on function public.get_raid_page_v1(text) from public,anon;
grant execute on function public.get_raid_page_v1(text) to authenticated;

-- 02-reservations.sql
create or replace function public.raid_item_quantity_v2(p_user_id uuid,p_item_id text)
returns bigint language sql stable security definer set search_path='' as $$
 select coalesce((select sum(p.quantity) from public.shop_purchases p where p.user_id=p_user_id and p.item_id=p_item_id),0)
 + (select count(*) from public.shop_item_grants g where g.user_id=p_user_id and g.item_id=p_item_id)
 - (select count(*) from public.shop_item_uses u where u.user_id=p_user_id and u.item_id=p_item_id and u.restored_at is null);
$$;
create or replace function public.raid_item_reserved_v2(p_user_id uuid,p_item_id text)
returns bigint language sql stable security definer set search_path='' as $$
 select count(*) from public.raid_actions a join public.raid_battles b on b.quest_id=a.quest_id
 where a.user_id=p_user_id and a.item_id=p_item_id and a.action_type='item' and a.resolved_at is null and b.state='active';
$$;
create or replace function public.raid_guard_item_use_v2()
returns trigger language plpgsql security definer set search_path='' as $$
declare reserved bigint; own_reservation integer:=0;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||new.user_id::text,0));
 if new.raid_quest_id is null then
  if exists(select 1 from public.raid_members m join public.raid_battles b on b.quest_id=m.quest_id
    where b.state='active' and m.user_id in (new.user_id,new.target_user_id)) then
   raise exception '전투 중에는 토벌 페이지에서 턴 행동으로 아이템을 사용해 주세요.' using errcode='22023'; end if;
 else
  if not exists(select 1 from public.raid_actions a join public.raid_battles b on b.quest_id=a.quest_id
    where a.quest_id=new.raid_quest_id and a.turn_no=new.raid_turn_no and a.user_id=new.user_id
    and a.item_id=new.item_id and a.target_user_id=new.target_user_id and a.action_type='item'
    and a.resolved_at is null and b.state='active' and b.turn_no=a.turn_no) then
   raise exception '유효한 아이템 행동 예약이 없습니다.'; end if;
  own_reservation:=1;
 end if;
 reserved:=public.raid_item_reserved_v2(new.user_id,new.item_id)-own_reservation;
 if public.raid_item_quantity_v2(new.user_id,new.item_id)<=reserved then
  raise exception '사용 가능한 수량이 없습니다. 토벌에 예약된 수량도 확인해 주세요.' using errcode='22023'; end if;
 return new;
end;
$$;
drop trigger if exists raid_guard_item_use on public.shop_item_uses;
create trigger raid_guard_item_use before insert on public.shop_item_uses
 for each row execute function public.raid_guard_item_use_v2();
revoke all on function public.raid_item_quantity_v2(uuid,text) from public,anon,authenticated;
revoke all on function public.raid_item_reserved_v2(uuid,text) from public,anon,authenticated;
revoke all on function public.raid_guard_item_use_v2() from public,anon,authenticated;

-- 03-resolve.sql
create or replace function public.raid_resolve_turn_v1(p_quest_id text)
returns void language plpgsql security definer set search_path='' as $$
declare
 b public.raid_battles%rowtype; actor record; target record; eligible integer; submitted integer;
 damage integer; dhp integer; dmp integer;
begin
 select * into b from public.raid_battles where quest_id=p_quest_id for update;
 if not found or b.state<>'active' then return; end if;
 -- Lock inventory before profiles, in a stable order shared with action submission.
 for actor in select m.user_id from public.raid_members m where m.quest_id=p_quest_id order by m.user_id loop
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||actor.user_id::text,0));
 end loop;
 perform p.user_id from public.guild_profiles p join public.raid_members m on m.user_id=p.user_id
  where m.quest_id=p_quest_id order by p.user_id for update of p;
 select count(*),count(a.user_id) into eligible,submitted
 from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id
 left join public.raid_actions a on a.quest_id=m.quest_id and a.user_id=m.user_id and a.turn_no=b.turn_no
 where m.quest_id=p_quest_id and p.hp>0
 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id));
 if eligible=0 then
  update public.raid_actions set resolved_at=now() where quest_id=p_quest_id and resolved_at is null;
  update public.raid_battles set state='defeat',finished_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'defeat','전투 가능한 참여자가 없어 공략에 실패했습니다.');return;
 end if;
 if submitted<eligible then return; end if;
 insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'resolve','전원 행동 완료 · 아이템 효과, 공격, 보스 반격 순서로 적용합니다.');
 for actor in
  select a.*,p.username,p.hp,i.name as item_name,i.hp_restore,i.mp_restore
  from public.raid_actions a join public.guild_profiles p on p.user_id=a.user_id
  join public.shop_items i on i.id=a.item_id
  where a.quest_id=p_quest_id and a.turn_no=b.turn_no and a.action_type='item' and a.resolved_at is null
  order by a.created_at,a.user_id
 loop
  if actor.hp<=0 or exists(select 1 from public.quest_entry_blocks x where x.user_id=actor.user_id and x.quest_key in ('*',p_quest_id)) then
   insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'item',actor.username||' · 전투 불능 또는 참여 제한으로 아이템 예약 해제');
   continue;
  end if;
  select p.* into target from public.guild_profiles p join public.raid_members m on m.user_id=p.user_id
   where p.user_id=actor.target_user_id and m.quest_id=p_quest_id
   and not exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id));
  if not found or (not exists(select 1 from public.quest_admins x where x.user_id=actor.user_id)
   and exists(select 1 from public.quest_admins x where x.user_id=actor.target_user_id)) then
   insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'item',actor.username||' · 유효한 사용 대상이 없어 아이템을 소모하지 않았습니다.');continue;
  end if;
  dhp:=greatest(0,least(actor.hp_restore,200-target.hp));dmp:=greatest(0,least(actor.mp_restore,200-target.mp));
  if public.raid_item_quantity_v2(actor.user_id,actor.item_id)<1
   or ((actor.hp_restore>0 or actor.mp_restore>0) and dhp=0 and dmp=0) then
   insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'item',actor.username||' · 수량이 없거나 회복할 수치가 없어 아이템을 소모하지 않았습니다.');continue;
  end if;
  update public.guild_profiles set hp=target.hp+dhp,mp=target.mp+dmp where user_id=target.user_id;
  insert into public.shop_item_uses(user_id,item_id,target_user_id,hp_restored,mp_restored,raid_quest_id,raid_turn_no)
   values(actor.user_id,actor.item_id,target.user_id,dhp,dmp,p_quest_id,b.turn_no);
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'item',
   actor.username||' → '||target.username||' · '||actor.item_name||' 1개 사용 · HP +'||dhp::text||' / MP +'||dmp::text);
 end loop;
 update public.raid_actions set resolved_at=now() where quest_id=p_quest_id and turn_no=b.turn_no and action_type='item' and resolved_at is null;
 for actor in
  select p.user_id,p.username from public.raid_actions a join public.guild_profiles p on p.user_id=a.user_id
  where a.quest_id=p_quest_id and a.turn_no=b.turn_no and a.action_type='attack' and p.hp>0
  and not exists(select 1 from public.quest_entry_blocks x where x.user_id=p.user_id and x.quest_key in ('*',p_quest_id))
  order by a.created_at,a.user_id
 loop
  damage:=least(b.boss_hp,b.player_damage);b.boss_hp:=b.boss_hp-damage;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'attack',actor.username||'의 공격 · 보스 HP -'||damage::text);
 end loop;
 update public.raid_actions set resolved_at=now() where quest_id=p_quest_id and turn_no=b.turn_no and resolved_at is null;
 if b.boss_hp=0 then
  update public.raid_battles set boss_hp=0,state='victory',finished_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'victory','보스를 처치했습니다. 토벌 성공! 보상은 관리자 지급을 기다려 주세요.');return;
 end if;
 for actor in select p.user_id,p.username,p.hp from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id
  where m.quest_id=p_quest_id and p.hp>0
  and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id)) order by p.user_id
 loop
  damage:=least(actor.hp,b.boss_damage);
  update public.guild_profiles set hp=greatest(0,hp-b.boss_damage) where user_id=actor.user_id;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'counter',actor.username||'에게 보스 반격 · HP -'||damage::text);
 end loop;
 if not exists(select 1 from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id
  where m.quest_id=p_quest_id and p.hp>0 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))) then
  update public.raid_battles set boss_hp=b.boss_hp,state='defeat',finished_at=now(),revision=revision+1,updated_at=now() where quest_id=p_quest_id;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no,'defeat','참여자 전원이 전투 불능이 되어 공략에 실패했습니다.');
 else
  update public.raid_battles set boss_hp=b.boss_hp,turn_no=turn_no+1,revision=revision+1,updated_at=now() where quest_id=p_quest_id;
  insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,b.turn_no+1,'turn',(b.turn_no+1)::text||'턴을 시작합니다.');
 end if;
end;
$$;
revoke all on function public.raid_resolve_turn_v1(text) from public,anon,authenticated;

-- 04-actions.sql
create or replace function public.raid_submit_choice_v2(p_quest_id text,p_turn_no integer,p_action text,p_item_id text default null,p_target_user_id uuid default null)
returns text language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; hp_now integer; actor_name text; i public.shop_items%rowtype; target public.guild_profiles%rowtype; locked_member record;
begin
 if not public.raid_can_access_v1(p_quest_id) then raise exception '모집 마감과 관리자 입장 활성화, 참여 기록을 확인해 주세요.' using errcode='42501'; end if;
 if p_action is null or p_action not in ('attack','item') then raise exception '알 수 없는 행동입니다.'; end if;
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
create or replace function public.raid_submit_action_v1(p_quest_id text,p_turn_no integer)
returns text language plpgsql security definer set search_path='' as $$
begin return public.raid_submit_choice_v2(p_quest_id,p_turn_no,'attack',null,null); end;
$$;
revoke all on function public.raid_submit_choice_v2(text,integer,text,text,uuid) from public,anon;
grant execute on function public.raid_submit_choice_v2(text,integer,text,text,uuid) to authenticated;

-- 05-read.sql
create or replace function public.raid_get_state_v1(p_quest_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; members jsonb; logs jsonb; can_start boolean; inventory jsonb;
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
    'boss_name',b.boss_name,'boss_hp',b.boss_hp,'boss_max_hp',b.boss_max_hp,
    'player_damage',b.player_damage,'boss_damage',b.boss_damage,
    'revision',b.revision,'members',members,'logs',logs,'can_start',can_start,
    'has_older_logs',(select count(*)>100 from public.raid_logs where quest_id=p_quest_id));
end;
$$;
revoke all on function public.raid_get_state_v1(text) from public,anon;
grant execute on function public.raid_get_state_v1(text) to authenticated;
notify pgrst,'reload schema';
notify pgrst,'reload schema';
commit;
