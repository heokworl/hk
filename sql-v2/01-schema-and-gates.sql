begin;
-- Grandfather existing active raids only on the first installation of entry gates.
do $
declare first_install boolean;
begin
 select not exists(
  select 1 from information_schema.columns
  where table_schema='public' and table_name='quest_limits' and column_name='recruitment_closed'
 ) into first_install;
 alter table public.quest_limits
  add column if not exists recruitment_closed boolean not null default false,
  add column if not exists raid_entry_enabled boolean not null default false;
 if first_install then
  update public.quest_limits q
  set recruitment_closed=true,raid_entry_enabled=true
  from public.raid_battles b
  where b.quest_id=q.quest_id and b.state='active' and q.active and q.category='raid';
 end if;
end;
$;
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
returns text language plpgsql security definer set search_path='' as $
declare q public.quest_limits%rowtype;
begin
 if auth.uid() is null or not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) then
  raise exception '관리자만 변경할 수 있습니다.' using errcode='42501'; end if;
 select * into q from public.quest_limits where quest_id=p_quest_id for update;
 if not found then raise exception '해당 퀘스트를 찾을 수 없습니다.'; end if;
 if q.awarded_at is not null and not (p_command in ('close','enable','disable','resume') and exists(select 1 from public.raid_battles b where b.quest_id=p_quest_id and b.state='active')) then raise exception '종료된 퀘스트는 변경할 수 없습니다.'; end if;
 if p_command='resume' then
  if q.category<>'raid' or not exists(select 1 from public.raid_battles b where b.quest_id=p_quest_id and b.state='active') then raise exception '진행 중인 토벌만 접근을 복구할 수 있습니다.'; end if;
  update public.quest_limits set recruitment_closed=true,raid_entry_enabled=true where quest_id=p_quest_id;
 elsif p_command='close' then
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
$;

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
returns jsonb language sql stable security definer set search_path='' as $
 select coalesce(jsonb_agg(jsonb_build_object(
  'quest_id',q.quest_id,'category',q.category,'game_version',q.game_version,
  'recruitment_closed',q.recruitment_closed,'raid_entry_enabled',q.raid_entry_enabled,
  'battle_state',(select r.state from public.raid_battles r where r.quest_id=q.quest_id),
  'battle_started',exists(select 1 from public.raid_battles r where r.quest_id=q.quest_id and r.state<>'waiting'),
  'blocked',exists(select 1 from public.quest_entry_blocks b where b.user_id=auth.uid() and b.quest_key in ('*',q.quest_id)),
  'participants',coalesce((select jsonb_agg(p.username order by e.joined_at)
   from public.quest_participants e join public.guild_profiles p on p.user_id=e.user_id where e.quest_id=q.quest_id),'[]'::jsonb)
 )),'[]'::jsonb) from public.quest_limits q where q.active and auth.uid() is not null;
$;
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
commit;
