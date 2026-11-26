begin;
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
commit;
