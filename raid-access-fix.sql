begin;
create or replace function public.get_raid_page_v1(p_quest_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_quest public.quest_limits%rowtype;
begin
 if auth.uid() is null then
   raise exception '로그인 후 이용해 주세요.' using errcode='28000';
 end if;
 select q.* into v_quest from public.quest_limits q
 where q.quest_id=p_quest_id and q.active and q.category='raid';
 if not found then raise exception '해당 토벌 의뢰를 찾을 수 없습니다.' using errcode='22023'; end if;
 if not exists(select 1 from public.quest_participants p
   where p.quest_id=p_quest_id and p.user_id=auth.uid()) then
   raise exception '이 퀘스트에 참여한 이용자만 공략 페이지를 볼 수 있습니다.' using errcode='42501';
 end if;
 if exists(select 1 from public.quest_entry_blocks b
   where b.user_id=auth.uid() and b.quest_key in ('*',p_quest_id)) then
   raise exception '참여가 제한된 토벌입니다.' using errcode='42501';
 end if;
 return jsonb_build_object('quest_id',v_quest.quest_id,
   'game_version',v_quest.game_version,'content','게임1');
end;
$$;
revoke all on function public.get_raid_page_v1(text) from public,anon;
grant execute on function public.get_raid_page_v1(text) to authenticated;
notify pgrst,'reload schema';
commit;
