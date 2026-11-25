begin;
-- Existing duplicate names must be resolved before this migration can commit.
create unique index if not exists shop_items_name_normalized_uidx
on public.shop_items ((lower(btrim(name))));
create or replace function public.admin_add_shop_item(
  p_name text, p_description text, p_price integer
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(p_name);
  v_description text := btrim(coalesce(p_description,''));
  v_id text;
begin
  if auth.uid() is null or not exists(
    select 1 from public.quest_admins a where a.user_id=auth.uid()
  ) then
    raise exception 'administrator access required' using errcode='42501';
  end if;
  if v_name is null or char_length(v_name)<1 or char_length(v_name)>80 then
    raise exception '상품명은 1~80자로 입력해 주세요.' using errcode='22023';
  end if;
  if char_length(v_description)>2000 then
    raise exception '설명은 2000자 이하로 입력해 주세요.' using errcode='22023';
  end if;
  if p_price is null or p_price<1 or p_price>1000000 then
    raise exception '가격은 1~1,000,000G의 정수여야 합니다.' using errcode='22023';
  end if;
  v_id := 'item-' || pg_catalog.gen_random_uuid()::text;
  insert into public.shop_items(id,name,description,price_g,active)
    values(v_id,v_name,v_description,p_price,true);
  return pg_catalog.jsonb_build_object('item_id',v_id,'item_name',v_name,'price_g',p_price);
end;
$$;
revoke all on function public.admin_add_shop_item(text,text,integer) from public;
revoke all on function public.admin_add_shop_item(text,text,integer) from anon;
grant execute on function public.admin_add_shop_item(text,text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
