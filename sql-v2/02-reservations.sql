begin;
create or replace function public.raid_item_quantity_v2(p_user_id uuid,p_item_id text)
returns bigint language sql stable security definer set search_path='' as $$
 select coalesce((select sum(p.quantity) from public.shop_purchases p where p.user_id=p_user_id and p.item_id=p_item_id),0)
 + (select count(*) from public.shop_item_grants g where g.user_id=p_user_id and g.item_id=p_item_id)
 - (select count(*) from public.shop_item_uses u where u.user_id=p_user_id and u.item_id=p_item_id and u.restored_at is null);
$$;
create or replace function public.raid_item_reserved_v2(p_user_id uuid,p_item_id text)
returns bigint language sql stable security definer set search_path='' as $$
 select count(*) from public.raid_actions a join public.raid_battles b on b.quest_id=a.quest_id
 where a.user_id=p_user_id and a.item_id=p_item_id and a.action_type='item' and a.resolved_at is null and b.state='active';
$$;
create or replace function public.raid_guard_item_use_v2()
returns trigger language plpgsql security definer set search_path='' as $$
declare reserved bigint; own_reservation integer:=0;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||new.user_id::text,0));
 if new.raid_quest_id is null then
  if exists(select 1 from public.raid_members m join public.raid_battles b on b.quest_id=m.quest_id
    where b.state='active' and m.user_id in (new.user_id,new.target_user_id)) then
   raise exception '전투 중에는 토벌 페이지에서 턴 행동으로 아이템을 사용해 주세요.' using errcode='22023'; end if;
 else
  if not exists(select 1 from public.raid_actions a join public.raid_battles b on b.quest_id=a.quest_id
    where a.quest_id=new.raid_quest_id and a.turn_no=new.raid_turn_no and a.user_id=new.user_id
    and a.item_id=new.item_id and a.target_user_id=new.target_user_id and a.action_type='item'
    and a.resolved_at is null and b.state='active' and b.turn_no=a.turn_no) then
   raise exception '유효한 아이템 행동 예약이 없습니다.'; end if;
  own_reservation:=1;
 end if;
 reserved:=public.raid_item_reserved_v2(new.user_id,new.item_id)-own_reservation;
 if public.raid_item_quantity_v2(new.user_id,new.item_id)<=reserved then
  raise exception '사용 가능한 수량이 없습니다. 토벌에 예약된 수량도 확인해 주세요.' using errcode='22023'; end if;
 return new;
end;
$$;
drop trigger if exists raid_guard_item_use on public.shop_item_uses;
create trigger raid_guard_item_use before insert on public.shop_item_uses
 for each row execute function public.raid_guard_item_use_v2();
revoke all on function public.raid_item_quantity_v2(uuid,text) from public,anon,authenticated;
revoke all on function public.raid_item_reserved_v2(uuid,text) from public,anon,authenticated;
revoke all on function public.raid_guard_item_use_v2() from public,anon,authenticated;
commit;
