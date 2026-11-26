begin;
create or replace function public.use_shop_item_target_v3(p_item_id text,p_target_user_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_qty integer;
begin
 if v_uid is null then raise exception 'authentication required' using errcode='28000'; end if;
 if not exists(select 1 from public.guild_profiles p where p.user_id=p_target_user_id)
 then raise exception 'unknown target'; end if;
 if not exists(select 1 from public.quest_admins a where a.user_id=v_uid)
 and exists(select 1 from public.quest_admins a where a.user_id=p_target_user_id)
 then raise exception '관리자 계정은 대상으로 선택할 수 없습니다.' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||v_uid::text,0));
 select i.quantity into v_qty from public.get_my_inventory() i where i.item_id=p_item_id;
 if coalesce(v_qty,0)<1 then return 'not_owned'; end if;
 insert into public.shop_item_uses(user_id,item_id,target_user_id) values(v_uid,p_item_id,p_target_user_id);
 return 'used';
end;
$$;
create or replace function public.get_my_used_items_v3()
returns table(use_id bigint,item_id text,item_name text,used_at timestamptz,restored_at timestamptz,target_name text)
language sql stable security definer set search_path='' as $$
 select u.id,u.item_id,i.name,u.used_at,u.restored_at,p.username
 from public.shop_item_uses u join public.shop_items i on i.id=u.item_id
 left join public.guild_profiles p on p.user_id=u.target_user_id
 where u.user_id=auth.uid() order by u.used_at desc;
$$;

revoke all on function public.use_shop_item_target_v3(text,uuid) from public;
grant execute on function public.use_shop_item_target_v3(text,uuid) to authenticated;
revoke all on function public.get_my_used_items_v3() from public;
grant execute on function public.get_my_used_items_v3() to authenticated;
notify pgrst,'reload schema';
commit;
