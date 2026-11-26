begin;
do $$
begin
 if to_regprocedure('public.raid_submit_choice_v2(text,integer,text,text,uuid)') is null
    or to_regprocedure('public.raid_item_quantity_v2(uuid,text)') is null then
  raise exception '먼저 raid-battle-controls-items.sql 전체를 실행해 토벌 기본 설정을 완료해 주세요.';
 end if;
end;
$$;
alter table public.quest_limits
 add column if not exists is_test_raid boolean not null default false,
 add column if not exists test_min_members integer not null default 1 check(test_min_members between 1 and 2),
 add column if not exists test_boss_min_hp integer not null default 40 check(test_boss_min_hp between 1 and 100),
 add column if not exists test_boss_max_hp integer not null default 100 check(test_boss_max_hp between 1 and 100),
 add column if not exists reward_amount integer not null default 0,
 add column if not exists reward_mode text not null default 'per_user';
alter table public.raid_battles add column if not exists boss_kind text not null default 'rift';
do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.quest_limits'::regclass and conname='quest_test_boss_hp_range_check') then
  alter table public.quest_limits add constraint quest_test_boss_hp_range_check check(test_boss_min_hp<=test_boss_max_hp);
 end if;
end;
$$;
insert into public.quest_limits(quest_id,max_members,reward_amount,reward_mode,active,category,is_test_raid,test_min_members,test_boss_min_hp,test_boss_max_hp)
values('test_raid_solo_v1',1,0,'per_user',true,'raid',true,1,40,80),
      ('test_raid_duo_v1',2,0,'per_user',true,'raid',true,2,60,100)
on conflict(quest_id) do update set max_members=excluded.max_members,is_test_raid=true,
 test_min_members=excluded.test_min_members,test_boss_min_hp=excluded.test_boss_min_hp,test_boss_max_hp=excluded.test_boss_max_hp;
create or replace function public.raid_spawn_test_boss_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare q public.quest_limits%rowtype; species record; rolled_hp integer;
begin
 select * into q from public.quest_limits where quest_id=new.quest_id;
 if q.is_test_raid then
  select * into species from (values
   ('wisp','균열 젤리'),('shade','붉은 눈 그림자'),('guardian','조각 골렘'),('beast','잔류 포식자')
  ) as options(kind,name) order by random() limit 1;
  rolled_hp:=q.test_boss_min_hp+floor(random()*(q.test_boss_max_hp-q.test_boss_min_hp+1))::integer;
  new.boss_kind:=species.kind;new.boss_name:=species.name;new.boss_max_hp:=rolled_hp;new.boss_hp:=rolled_hp;
 end if;
 return new;
end;
$$;
drop trigger if exists raid_spawn_test_boss on public.raid_battles;
create trigger raid_spawn_test_boss before insert on public.raid_battles
 for each row execute function public.raid_spawn_test_boss_v1();
revoke all on function public.raid_spawn_test_boss_v1() from public,anon,authenticated;

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
  if exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.is_test_raid and
    (select count(*) from public.quest_participants e where e.quest_id=p_quest_id and not exists(
      select 1 from public.quest_entry_blocks x where x.user_id=e.user_id and x.quest_key in ('*',p_quest_id)
    ))<q.test_min_members) then raise exception '이 테스트 토벌의 필요 참여 인원이 아직 모이지 않았습니다.'; end if;
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
    values(p_quest_id,1,'start','공략 시작 · '||b.boss_name||' HP '||b.boss_max_hp::text||' / 공격 '||b.player_damage::text||' / 보스 반격 '||b.boss_damage::text||'. 참여 명단을 확정했습니다.');
  for u in select p.username from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id where m.quest_id=p_quest_id order by p.username_key loop
    insert into public.raid_logs(quest_id,turn_no,kind,message) values(p_quest_id,1,'member',u.username||' 공략 참여');
  end loop;
  return 'started';
end;
$$;
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
revoke all on function public.raid_start_v1(text) from public,anon;
grant execute on function public.raid_start_v1(text) to authenticated;
revoke all on function public.raid_get_state_v1(text) from public,anon;
grant execute on function public.raid_get_state_v1(text) to authenticated;
notify pgrst,'reload schema';
commit;
