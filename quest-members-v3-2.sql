begin;
create or replace function public.admin_quest_block_v3(p_user_id uuid,p_quest_key text,p_block boolean)
returns text language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) then
 raise exception 'administrator access required' using errcode='42501'; end if;
 if not exists(select 1 from public.guild_profiles p where p.user_id=p_user_id) then
 raise exception 'unknown user'; end if;
 if p_quest_key is null or (p_quest_key<>'*' and not exists(select 1 from public.quest_limits q where q.quest_id=p_quest_key)) then
 raise exception 'unknown quest'; end if;
 if p_block then
 insert into public.quest_entry_blocks(user_id,quest_key,blocked_by) values(p_user_id,p_quest_key,auth.uid())
 on conflict(user_id,quest_key) do nothing;
 else delete from public.quest_entry_blocks where user_id=p_user_id and quest_key=p_quest_key; end if;
 return 'saved';
end;
$$;
create or replace function public.admin_get_quest_blocks_v3()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) then
 raise exception 'administrator access required' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('user_id',b.user_id,'username',p.username,'quest_key',b.quest_key)),'[]'::jsonb)
 from public.quest_entry_blocks b join public.guild_profiles p on p.user_id=b.user_id);
end;
$$;

revoke all on function public.admin_quest_block_v3(uuid,text,boolean) from public;
grant execute on function public.admin_quest_block_v3(uuid,text,boolean) to authenticated;
revoke all on function public.admin_get_quest_blocks_v3() from public;
grant execute on function public.admin_get_quest_blocks_v3() to authenticated;
notify pgrst,'reload schema';
commit;
