begin;
-- New quests only. Existing quests, participants and battles are preserved.
insert into public.quest_limits
 (quest_id,max_members,reward_amount,reward_mode,active,category,is_test_raid,test_min_members,test_boss_min_hp,test_boss_max_hp)
values
 ('test_raid_solo_v2',1,0,'per_user',true,'raid',true,1,40,60),
 ('test_raid_solo_v3',1,0,'per_user',true,'raid',true,1,60,80)
on conflict(quest_id) do nothing;

create or replace function public.raid_admin_observe_v1(p_quest_id text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
 and exists(select 1 from public.quest_admins a where a.user_id=auth.uid())
 and exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.category='raid');
$$;
revoke all on function public.raid_admin_observe_v1(text) from public,anon;
grant execute on function public.raid_admin_observe_v1(text) to authenticated;

create or replace function public.raid_get_state_v1(p_quest_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.raid_battles%rowtype; members jsonb; logs jsonb; can_start boolean; inventory jsonb;
begin
  if exists(select 1 from public.raid_battles r where r.quest_id=p_quest_id and r.state in ('victory','defeat')) then
    return public.raid_terminal_status_v1(p_quest_id);
  end if;
  if not (public.raid_can_access_v1(p_quest_id) or public.raid_admin_observe_v1(p_quest_id)) then
    raise exception '참여한 토벌 퀘스트만 볼 수 있습니다.' using errcode='42501';
  end if;
  perform 1 from public.quest_limits q where q.quest_id=p_quest_id for update;
  insert into public.raid_battles(quest_id) values(p_quest_id) on conflict(quest_id) do nothing;
  select * into b from public.raid_battles where quest_id=p_quest_id for update;
  if public.raid_can_access_v1(p_quest_id) then perform public.raid_resolve_turn_v1(p_quest_id);end if;
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
  can_start:=public.raid_can_access_v1(p_quest_id) and b.state='waiting' and exists(select 1 from public.quest_limits q where q.quest_id=p_quest_id and q.awarded_at is null);
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_id',i.item_id,'item_name',i.item_name,'description',i.description,
    'quantity',greatest(i.quantity-public.raid_item_reserved_v2(auth.uid(),i.item_id),0),
    'reserved',public.raid_item_reserved_v2(auth.uid(),i.item_id),
    'hp_restore',s.hp_restore,'mp_restore',s.mp_restore
  ) order by i.item_name),'[]'::jsonb) into inventory
  from public.get_my_inventory() i join public.shop_items s on s.id=i.item_id where public.raid_can_access_v1(p_quest_id);
  return jsonb_build_object('spectator',not public.raid_can_access_v1(p_quest_id),'inventory',inventory,'quest_id',b.quest_id,'state',b.state,'turn_no',b.turn_no,
    'boss_kind',b.boss_kind,'boss_name',b.boss_name,'boss_hp',b.boss_hp,'boss_max_hp',b.boss_max_hp,
    'player_damage',b.player_damage,'boss_damage',b.boss_damage,
    'required_count',(select count(*) from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id where m.quest_id=p_quest_id and p.hp>0 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))),
    'ready_count',(select count(*) from public.raid_members m join public.guild_profiles p on p.user_id=m.user_id join public.raid_actions a on a.quest_id=m.quest_id and a.user_id=m.user_id and a.turn_no=b.turn_no where m.quest_id=p_quest_id and p.hp>0 and not exists(select 1 from public.quest_entry_blocks x where x.user_id=m.user_id and x.quest_key in ('*',p_quest_id))),
    'revision',b.revision,'members',members,'logs',logs,'can_start',can_start,
    'has_older_logs',(select count(*)>100 from public.raid_logs where quest_id=p_quest_id));
end;
$$;
create or replace function public.raid_terminal_status_v1(p_quest_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b public.raid_battles%rowtype;
begin
 if not public.raid_admin_observe_v1(p_quest_id) and (auth.uid() is null or not exists(select 1 from public.quest_participants p where p.quest_id=p_quest_id and p.user_id=auth.uid())) then
  raise exception '참여한 토벌 퀘스트만 확인할 수 있습니다.' using errcode='42501';end if;
 select * into b from public.raid_battles where quest_id=p_quest_id and state in ('victory','defeat');
 if not found then return null;end if;
 return jsonb_build_object('quest_id',b.quest_id,'state',b.state,'finished',true,'revision',b.revision,
  'user_reward',coalesce((select p.amount from public.quest_reward_payouts p where p.quest_id=p_quest_id and p.user_id=auth.uid()),0),
  'reward_total',b.reward_total,'rewards_settled',b.rewards_settled_at is not null,
  'is_test',(select q.is_test_raid from public.quest_limits q where q.quest_id=p_quest_id));
end;
$$;
create or replace function public.raid_can_observe_v2(p_quest_id text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (public.raid_admin_observe_v1(p_quest_id) or public.raid_can_access_v1(p_quest_id)
 or (exists(select 1 from public.raid_battles b where b.quest_id=p_quest_id and b.state in ('victory','defeat'))
 and exists(select 1 from public.raid_members m where m.quest_id=p_quest_id and m.user_id=auth.uid())));
$$;
create or replace function public.raid_get_logs_v1(p_quest_id text,p_before_id bigint)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not (public.raid_can_access_v1(p_quest_id) or public.raid_admin_observe_v1(p_quest_id)) then
    raise exception '참여한 토벌 퀘스트만 볼 수 있습니다.' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into result
    from (select id,turn_no,kind,message,created_at from public.raid_logs
      where quest_id=p_quest_id and id<p_before_id order by id desc limit 100) l;
  return result;
end;
$$;
notify pgrst,'reload schema';
commit;
