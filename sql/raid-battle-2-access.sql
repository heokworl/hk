begin;
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
commit;
