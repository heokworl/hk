begin;
-- Each granted unit keeps its own audit row; inventory already sums these rows.
do $$
declare r record;
begin
 for r in
  select c.conname from pg_constraint c
  where c.conrelid='public.shop_item_grants'::regclass and c.contype='u'
   and (select array_agg(a.attname::text order by a.attname::text)
        from unnest(c.conkey) k(attnum)
        join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum)=array['item_id','user_id']::text[]
 loop
  execute format('alter table public.shop_item_grants drop constraint %I',r.conname);
 end loop;
 for r in
  select n.nspname,c.relname from pg_index i
  join pg_class c on c.oid=i.indexrelid join pg_namespace n on n.oid=c.relnamespace
  where i.indrelid='public.shop_item_grants'::regclass and i.indisunique and not i.indisprimary
   and i.indnkeyatts=2 and i.indexprs is null
   and not exists(select 1 from pg_constraint pc where pc.conindid=i.indexrelid)
   and (select array_agg(a.attname::text order by a.attname::text)
        from unnest(i.indkey::smallint[]) with ordinality k(attnum,position)
        join pg_attribute a on a.attrelid=i.indrelid and a.attnum=k.attnum
        where k.position<=i.indnkeyatts)=array['item_id','user_id']::text[]
 loop
  execute format('drop index %I.%I',r.nspname,r.relname);
 end loop;
end;
$$;
alter table public.shop_item_grants enable row level security;
revoke all on public.shop_item_grants from public,anon,authenticated;
create or replace function public.admin_grant_shop_items_v2(p_user_id uuid,p_item_id text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_admin uuid:=auth.uid(); v_inserted integer; v_owned bigint;
begin
 if v_admin is null or not exists(select 1 from public.quest_admins a where a.user_id=v_admin) then
  raise exception '관리자만 아이템을 지급할 수 있습니다.' using errcode='42501'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>1000 then
  raise exception '지급 수량은 1~1,000 사이의 정수로 입력해 주세요.' using errcode='22023'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shop:'||p_user_id::text,0));
 perform 1 from public.guild_profiles p where p.user_id=p_user_id for key share;
 if not found then raise exception '지급 대상을 찾을 수 없습니다.' using errcode='22023'; end if;
 perform 1 from public.shop_items i where i.id=p_item_id and i.active for share;
 if not found then raise exception '판매 중인 아이템을 선택해 주세요.' using errcode='22023'; end if;
 insert into public.shop_item_grants(user_id,item_id,granted_by)
  select p_user_id,p_item_id,v_admin from pg_catalog.generate_series(1,p_quantity);
 get diagnostics v_inserted=row_count;
 if v_inserted<>p_quantity then raise exception '지급 수량 저장에 실패했습니다.'; end if;
 select coalesce((select sum(p.quantity)::bigint from public.shop_purchases p where p.user_id=p_user_id and p.item_id=p_item_id),0)
  +(select count(*) from public.shop_item_grants g where g.user_id=p_user_id and g.item_id=p_item_id)
  -(select count(*) from public.shop_item_uses u where u.user_id=p_user_id and u.item_id=p_item_id and u.restored_at is null)
 into v_owned;
 return jsonb_build_object('status','granted','user_id',p_user_id,'item_id',p_item_id,'quantity',v_inserted,'owned_quantity',v_owned);
end;
$$;
-- Older clients can grant one more unit too; existing ownership never blocks a grant.
create or replace function public.admin_grant_shop_item(p_user_id uuid,p_item_id text)
returns text language plpgsql security definer set search_path='' as $$
begin
 return public.admin_grant_shop_items_v2(p_user_id,p_item_id,1)->>'status';
end;
$$;
revoke all on function public.admin_grant_shop_items_v2(uuid,text,integer) from public,anon;
grant execute on function public.admin_grant_shop_items_v2(uuid,text,integer) to authenticated;
revoke all on function public.admin_grant_shop_item(uuid,text) from public,anon;
grant execute on function public.admin_grant_shop_item(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;

