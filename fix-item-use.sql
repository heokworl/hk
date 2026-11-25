-- Use the same remaining quantity as the inventory screen.
create or replace function public.use_shop_item(p_item_id text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid := auth.uid();
  v_available bigint;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shop:' || v_user_id::text, 0)
  );
  select coalesce(i.quantity, 0) into v_available
  from public.get_my_inventory() i where i.item_id = p_item_id;
  if coalesce(v_available, 0) < 1 then return 'not_owned'; end if;
  insert into public.shop_item_uses(user_id, item_id)
  values(v_user_id, p_item_id);
  return 'used';
end;
$$;
revoke all on function public.use_shop_item(text) from public;
grant execute on function public.use_shop_item(text) to authenticated;
notify pgrst, 'reload schema';
