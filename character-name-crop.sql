begin;
-- Requires character-events-update.sql. The login ID and all ledgers stay unchanged.
create or replace function public.save_my_character_v2(
 p_name text,p_department text,p_rank text,p_title_id text,p_portrait_path text,p_version bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();display_name text:=btrim(p_name);result jsonb;
begin
 if uid is null then raise exception '로그인이 필요합니다.' using errcode='28000';end if;
 if display_name is null or char_length(display_name) not between 1 and 40 or display_name ~ '[[:cntrl:]]' then
  raise exception '이름은 줄바꿈 없이 1~40자로 입력해 주세요.' using errcode='22023';end if;
 result:=public.save_my_character_v1(p_department,p_rank,p_title_id,p_portrait_path,p_version);
 -- username_key has the existing unique constraint, including concurrent requests.
 update public.guild_profiles set username=display_name,username_key=lower(display_name) where user_id=uid;
 if not found then raise exception '캐릭터 계정을 찾을 수 없습니다.' using errcode='22023';end if;
 update auth.users set raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)
  ||jsonb_build_object('display_name',display_name,'user_name',display_name) where id=uid;
 return result||jsonb_build_object('username',display_name);
end;
$$;
revoke all on function public.save_my_character_v2(text,text,text,text,text,bigint) from public,anon;
grant execute on function public.save_my_character_v2(text,text,text,text,text,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
