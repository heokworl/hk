begin;
alter table public.guild_profiles
 add column if not exists hp integer not null default 200,
 add column if not exists mp integer not null default 200;
create or replace function public.admin_get_member_status_v1()
returns table(user_id uuid,username text,hp integer,mp integer)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(
   select 1 from public.quest_admins a where a.user_id=auth.uid()
 ) then
   raise exception 'administrator access required' using errcode='42501';
 end if;
 return query
 select p.user_id,p.username,p.hp,p.mp
 from public.guild_profiles p order by p.username_key,p.user_id;
end;
$$;
revoke all on function public.admin_get_member_status_v1() from public;
revoke all on function public.admin_get_member_status_v1() from anon;
grant execute on function public.admin_get_member_status_v1() to authenticated;
notify pgrst,'reload schema';
commit;
