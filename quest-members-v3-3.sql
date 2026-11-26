begin;
create or replace function public.join_quest(p_quest_id text)
returns text language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_max integer; v_awarded timestamptz; v_count integer;
begin
 if v_uid is null then raise exception 'authentication required' using errcode='28000'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_quest_id,0));
 select q.max_members,q.awarded_at into v_max,v_awarded from public.quest_limits q where q.quest_id=p_quest_id and q.active for update;
 if v_max is null then raise exception 'unknown quest'; end if;
 if exists(select 1 from public.quest_entry_blocks b where b.user_id=v_uid and b.quest_key in ('*',p_quest_id)) then return 'blocked'; end if;
 if v_awarded is not null then return 'closed'; end if;
 if exists(select 1 from public.quest_participants e where e.quest_id=p_quest_id and e.user_id=v_uid) then return 'already_joined'; end if;
 select count(*) into v_count from public.quest_participants e where e.quest_id=p_quest_id;
 if v_count>=v_max then return 'full'; end if;
 insert into public.quest_participants(quest_id,user_id) values(p_quest_id,v_uid);
 return 'joined';
end;
$$;

revoke all on function public.join_quest(text) from public;
grant execute on function public.join_quest(text) to authenticated;
notify pgrst,'reload schema';
commit;
