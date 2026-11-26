begin;
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
commit;
