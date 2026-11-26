begin;
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
commit;
