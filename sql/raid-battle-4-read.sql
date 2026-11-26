begin;
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
commit;
