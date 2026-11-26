begin;
alter table public.shop_items
 add column if not exists hp_restore integer not null default 0,
 add column if not exists mp_restore integer not null default 0;
update public.shop_items set hp_restore=20 where id='healing-potion' and hp_restore=0;
alter table public.shop_item_uses
 add column if not exists target_user_id uuid references auth.users(id) on delete set null,
 add column if not exists hp_restored integer not null default 0,
 add column if not exists mp_restored integer not null default 0;
create or replace function public.use_shop_items_bulk_v1(p_item_id text,p_target_user_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_uid uuid:=auth.uid(); v_owned bigint; v_used integer; v_needed integer:=0;
 v_heal integer; v_mana integer; v_hp integer; v_mp integer; v_name text;
 dhp integer; dmp integer; total_hp integer:=0; total_mp integer:=0; n integer;
begin
 if v_uid is null then raise exception '로그인이 필요합니다.' using errcode='28000'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>1000 then
  raise exception '사용 수량은 1~1,000 사이의 정수로 입력해 주세요.' using errcode='22023'; end if;
 if not exists(select 1 from public.quest_admins a where a.user_id=v_uid)
  and exists(select 1 from public.quest_admins a where a.user_id=p_target_user_id) then
  raise exception '관리자 계정은 대상으로 선택할 수 없습니다.' using errcode='42501'; end if;
 if exists(select 1 from public.raid_members m join public.raid_battles b on b.quest_id=m.quest_id
  where b.state='active' and m.user_id in (v_uid,p_target_user_id)) then
  return jsonb_build_object('status','in_battle');
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||v_uid::text,0));
 select i.quantity into v_owned from public.get_my_inventory() i where i.item_id=p_item_id;
 if coalesce(v_owned,0)<p_quantity then return jsonb_build_object('status','not_owned'); end if;
 select i.hp_restore,i.mp_restore into v_heal,v_mana from public.shop_items i where i.id=p_item_id for share;
 if not found then raise exception '아이템을 찾을 수 없습니다.'; end if;
 select p.hp,p.mp,p.username into v_hp,v_mp,v_name from public.guild_profiles p where p.user_id=p_target_user_id for update;
 if not found then raise exception '사용 대상을 찾을 수 없습니다.'; end if;
 if v_heal>0 then v_needed:=greatest(v_needed,(greatest(0,200-v_hp)+v_heal-1)/v_heal); end if;
 if v_mana>0 then v_needed:=greatest(v_needed,(greatest(0,200-v_mp)+v_mana-1)/v_mana); end if;
 if v_heal>0 or v_mana>0 then
  if v_needed=0 then return jsonb_build_object('status','already_full','target_name',v_name,'hp',v_hp,'mp',v_mp); end if;
  v_used:=least(p_quantity,v_needed);
 else v_used:=p_quantity; end if;
 for n in 1..v_used loop
  dhp:=greatest(0,least(v_heal,200-v_hp));dmp:=greatest(0,least(v_mana,200-v_mp));
  v_hp:=v_hp+dhp;v_mp:=v_mp+dmp;total_hp:=total_hp+dhp;total_mp:=total_mp+dmp;
  insert into public.shop_item_uses(user_id,item_id,target_user_id,hp_restored,mp_restored)
   values(v_uid,p_item_id,p_target_user_id,dhp,dmp);
 end loop;
 update public.guild_profiles set hp=v_hp,mp=v_mp where user_id=p_target_user_id;
 return jsonb_build_object('status','used','target_name',v_name,'requested_quantity',p_quantity,
  'used_quantity',v_used,'unused_quantity',p_quantity-v_used,'hp',v_hp,'mp',v_mp,'hp_restored',total_hp,'mp_restored',total_mp);
end;
$$;
revoke all on function public.use_shop_items_bulk_v1(text,uuid,integer) from public,anon;
grant execute on function public.use_shop_items_bulk_v1(text,uuid,integer) to authenticated;
notify pgrst,'reload schema';
commit;
