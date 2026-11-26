begin;
create or replace function public.use_shop_item_target_v4(p_item_id text,p_target_user_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_uid uuid:=auth.uid(); v_qty integer; v_hp integer; v_mp integer;
 v_heal integer; v_mana integer; v_dhp integer; v_dmp integer; v_name text;
begin
 if v_uid is null then raise exception 'authentication required' using errcode='28000'; end if;
 if not exists(select 1 from public.quest_admins a where a.user_id=v_uid)
 and exists(select 1 from public.quest_admins a where a.user_id=p_target_user_id)
 then raise exception '관리자 계정은 대상으로 선택할 수 없습니다.' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||v_uid::text,0));
 select i.quantity into v_qty from public.get_my_inventory() i where i.item_id=p_item_id;
 if coalesce(v_qty,0)<1 then return jsonb_build_object('status','not_owned'); end if;
 select i.hp_restore,i.mp_restore into v_heal,v_mana from public.shop_items i where i.id=p_item_id for share;
 if not found then raise exception 'unknown item'; end if;
 select p.hp,p.mp,p.username into v_hp,v_mp,v_name from public.guild_profiles p where p.user_id=p_target_user_id for update;
 if not found then raise exception 'unknown target'; end if;
 v_dhp:=greatest(0,least(v_heal,200-v_hp));
 v_dmp:=greatest(0,least(v_mana,200-v_mp));
 if (v_heal>0 or v_mana>0) and v_dhp=0 and v_dmp=0 then
 return jsonb_build_object('status','already_full','target_name',v_name,'hp',v_hp,'mp',v_mp);
 end if;
 update public.guild_profiles set hp=v_hp+v_dhp,mp=v_mp+v_dmp where user_id=p_target_user_id;
 insert into public.shop_item_uses(user_id,item_id,target_user_id,hp_restored,mp_restored)
 values(v_uid,p_item_id,p_target_user_id,v_dhp,v_dmp);
 return jsonb_build_object('status','used','target_name',v_name,'hp',v_hp+v_dhp,'mp',v_mp+v_dmp,'hp_restored',v_dhp,'mp_restored',v_dmp);
end;
$$;
create or replace function public.use_shop_item_target_v3(p_item_id text,p_target_user_id uuid)
returns text language plpgsql security definer set search_path='' as $$
begin
 return public.use_shop_item_target_v4(p_item_id,p_target_user_id)->>'status';
end;
$$;
revoke all on function public.use_shop_item_target_v4(text,uuid) from public,anon;
grant execute on function public.use_shop_item_target_v4(text,uuid) to authenticated;
revoke all on function public.use_shop_item_target_v3(text,uuid) from public,anon;
grant execute on function public.use_shop_item_target_v3(text,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
