begin;
alter table public.guild_profiles
 add column if not exists hp integer not null default 200,
 add column if not exists mp integer not null default 200;
alter table public.shop_items
 add column if not exists hp_restore integer not null default 0 check(hp_restore between 0 and 200),
 add column if not exists mp_restore integer not null default 0 check(mp_restore between 0 and 200);
alter table public.shop_item_uses
 add column if not exists target_user_id uuid references auth.users(id) on delete set null,
 add column if not exists hp_restored integer not null default 0,
 add column if not exists mp_restored integer not null default 0;
update public.shop_items
 set hp_restore=20,mp_restore=0,
 description='작은 상처와 피로를 달래는 기본 회복 물약. 대상의 HP를 20 회복합니다. (최대 HP 200)'
 where id='healing-potion';
notify pgrst,'reload schema';
commit;
