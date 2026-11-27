begin;
-- Hidden event items use the same inventory and consumption ledger as shop items.
alter table public.shop_items add column if not exists is_event boolean not null default false,
 add column if not exists hp_restore integer not null default 0,
 add column if not exists mp_restore integer not null default 0;

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
 perform 1 from public.shop_items i where i.id=p_item_id and (i.active or i.is_event) for share;
 if not found then raise exception '지급 가능한 아이템을 선택해 주세요.' using errcode='22023'; end if;
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

commit;

create or replace function public.reject_event_purchase_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.shop_items i where i.id=new.item_id and i.is_event) then
  raise exception '이벤트 아이템은 상점에서 구매할 수 없습니다.' using errcode='22023';end if;
 return new;
end;
$$;
revoke all on function public.reject_event_purchase_v1() from public,anon,authenticated;
drop trigger if exists reject_event_purchase on public.shop_purchases;
create trigger reject_event_purchase before insert or update on public.shop_purchases
 for each row execute function public.reject_event_purchase_v1();


create table if not exists public.guild_event_item_requests(
 request_id uuid primary key,admin_id uuid not null references auth.users(id) on delete cascade,
 payload jsonb not null,result jsonb not null,created_at timestamptz not null default now()
);
alter table public.guild_event_item_requests enable row level security;
revoke all on public.guild_event_item_requests from public,anon,authenticated;
create or replace function public.admin_create_and_grant_event_v1(
 p_request_id uuid,p_user_id uuid,p_name text,p_description text,p_quantity integer,p_hp integer,p_mp integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();item_key text;receipt jsonb;previous public.guild_event_item_requests%rowtype;params jsonb;
begin
 if uid is null or not exists(select 1 from public.quest_admins a where a.user_id=uid) then
  raise exception '관리자만 이벤트 아이템을 지급할 수 있습니다.' using errcode='42501';end if;
 if p_request_id is null or p_user_id is null or p_name is null or char_length(btrim(p_name)) not between 1 and 80
 or char_length(coalesce(p_description,''))>2000 or p_quantity is null or p_quantity not between 1 and 1000
 or p_hp is null or p_hp not between 0 and 200 or p_mp is null or p_mp not between 0 and 200 then
  raise exception '이름·수량·회복량·지급 대상을 확인해 주세요.' using errcode='22023';end if;
 params:=jsonb_build_object('user_id',p_user_id,'name',btrim(p_name),'description',btrim(coalesce(p_description,'')),'quantity',p_quantity,'hp',p_hp,'mp',p_mp);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('event:'||p_request_id::text,0));
 select * into previous from public.guild_event_item_requests where request_id=p_request_id;
 if found then
  if previous.admin_id<>uid or previous.payload<>params then raise exception '다른 요청에 사용된 지급 번호입니다.' using errcode='22023';end if;
  return previous.result;
 end if;
 item_key:='event-'||pg_catalog.gen_random_uuid()::text;
 insert into public.shop_items(id,name,description,price_g,active,is_event,hp_restore,mp_restore)
 values(item_key,btrim(p_name),btrim(coalesce(p_description,'')),1,false,true,p_hp,p_mp);
 receipt:=public.admin_grant_shop_items_v2(p_user_id,item_key,p_quantity);
 receipt:=receipt||jsonb_build_object('item_name',btrim(p_name),'is_event',true);
 insert into public.guild_event_item_requests(request_id,admin_id,payload,result) values(p_request_id,uid,params,receipt);
 return receipt;
end;
$$;
create or replace function public.admin_get_grant_items_v1()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) then
  raise exception '관리자 권한이 필요합니다.' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('item_id',i.id,'item_name',i.name,'is_event',i.is_event,'price_g',i.price_g) order by i.is_event desc,i.name),'[]'::jsonb) from public.shop_items i where i.active or i.is_event);
end;
$$;
create or replace function public.admin_get_used_items_for_member_v1(p_user_id uuid)
returns table(use_id bigint,user_id uuid,username text,item_id text,item_name text,used_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.quest_admins a where a.user_id=auth.uid()) then
  raise exception '관리자 권한이 필요합니다.' using errcode='42501';end if;
 return query select u.id,u.user_id,p.username,u.item_id,i.name,u.used_at
 from public.shop_item_uses u join public.guild_profiles p on p.user_id=u.user_id
 join public.shop_items i on i.id=u.item_id where u.user_id=p_user_id and u.restored_at is null order by u.used_at desc,u.id desc;
end;
$$;
-- Archive quest definitions only; keep foreign keys, payouts, participants and combat history.
alter table public.quest_limits add column if not exists archived_at timestamptz;
create or replace function public.archive_paid_quest_v1()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.awarded_at is not null then new.active:=false;new.archived_at:=coalesce(new.archived_at,new.awarded_at);end if;
 return new;
end;
$$;
revoke all on function public.archive_paid_quest_v1() from public,anon,authenticated;
drop trigger if exists archive_paid_quest on public.quest_limits;
create trigger archive_paid_quest before insert or update on public.quest_limits
 for each row execute function public.archive_paid_quest_v1();
update public.quest_limits set active=false,archived_at=coalesce(archived_at,awarded_at) where awarded_at is not null and (active or archived_at is null);
create or replace function public.get_visible_quests_v1()
returns table(quest_id text) language sql stable security definer set search_path='' as $$
 select q.quest_id from public.quest_limits q where auth.uid() is not null and q.active and q.awarded_at is null and q.archived_at is null;
$$;
-- Character presentation data is isolated from HP, MP, wallets and login identity.
create table if not exists public.guild_titles(
 id text primary key,label text not null,emblem text not null,description text not null,active boolean not null default true
);
insert into public.guild_titles(id,label,emblem,description) values
 ('newcomer','새벽의 신입','star','천호에서 첫 이야기를 시작하는 헌터'),
 ('bounty_hunter','현상금 사냥꾼','target','의뢰의 끝까지 표적을 추적하는 사냥꾼'),
 ('gate_breaker','게이트 개척자','gate','미지의 경계 앞에 먼저 서는 헌터'),
 ('lifeline','생명의 파수꾼','cross','마지막 순간까지 동료를 지키는 손길'),
 ('night_watch','밤의 감시자','moon','고요한 밤에도 경계를 늦추지 않는 눈')
 on conflict(id) do nothing;
create table if not exists public.guild_characters(
 user_id uuid primary key references public.guild_profiles(user_id) on delete cascade,
 department text check(department in ('azure','white','black')),
 hunter_rank text check(hunter_rank in ('S','A','B','C','D','E','F')),
 portrait_path text,title_id text references public.guild_titles(id),
 version bigint not null default 0,updated_at timestamptz not null default now()
);
alter table public.guild_titles enable row level security;
alter table public.guild_characters enable row level security;
revoke all on public.guild_titles,public.guild_characters from public,anon,authenticated;
create or replace function public.get_my_character_v1()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.guild_characters%rowtype;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.' using errcode='28000';end if;
 select * into c from public.guild_characters where user_id=auth.uid();
 return jsonb_build_object('department',c.department,'rank',c.hunter_rank,'portrait_path',c.portrait_path,
 'title_id',c.title_id,'version',coalesce(c.version,0),'titles',
 (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'label',t.label,'emblem',t.emblem,'description',t.description) order by t.id),'[]'::jsonb) from public.guild_titles t where t.active));
end;
$$;
create or replace function public.save_my_character_v1(
 p_department text,p_rank text,p_title_id text,p_portrait_path text,p_version bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();v bigint;
begin
 if uid is null then raise exception '로그인이 필요합니다.' using errcode='28000';end if;
 if p_department is null or p_department not in ('azure','white','black') or p_rank is null or p_rank not in ('S','A','B','C','D','E','F')
 or p_version is null or p_version<0 then raise exception '부서와 등급을 확인해 주세요.' using errcode='22023';end if;
 if p_title_id is not null and not exists(select 1 from public.guild_titles t where t.id=p_title_id and t.active) then
  raise exception '선택할 수 없는 칭호입니다.' using errcode='22023';end if;
 if p_portrait_path is not null and (
  char_length(p_portrait_path)>150 or split_part(p_portrait_path,'/',1)<>uid::text
  or p_portrait_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}[.]webp$'
  or not exists(select 1 from storage.objects o where o.bucket_id='character-portraits' and o.name=p_portrait_path)) then
  raise exception '본인 계정으로 업로드한 이미지만 선택할 수 있습니다.' using errcode='42501';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('character:'||uid::text,0));
 insert into public.guild_characters(user_id) values(uid) on conflict(user_id) do nothing;
 update public.guild_characters set department=p_department,hunter_rank=p_rank,title_id=p_title_id,portrait_path=p_portrait_path,
 version=version+1,updated_at=now() where user_id=uid and version=p_version returning version into v;
 if not found then raise exception '다른 창에서 캐릭터가 수정되었습니다. 다시 불러온 뒤 저장해 주세요.' using errcode='40001';end if;
 return public.get_my_character_v1();
end;
$$;
-- Public image files, owner-only upload/delete. Only raster images <=2 MiB are accepted.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('character-portraits','character-portraits',true,2097152,array['image/webp','image/jpeg','image/png'])
 on conflict(id) do update set public=true,file_size_limit=2097152,allowed_mime_types=array['image/webp','image/jpeg','image/png'];
drop policy if exists character_portrait_insert on storage.objects;
create policy character_portrait_insert on storage.objects for insert to authenticated
 with check(bucket_id='character-portraits' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists character_portrait_delete on storage.objects;
create policy character_portrait_delete on storage.objects for delete to authenticated
 using(bucket_id='character-portraits' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists character_portrait_owner_read on storage.objects;
create policy character_portrait_owner_read on storage.objects for select to authenticated
 using(bucket_id='character-portraits' and (storage.foldername(name))[1]=auth.uid()::text);
revoke all on function public.admin_create_and_grant_event_v1(uuid,uuid,text,text,integer,integer,integer) from public,anon;
revoke all on function public.admin_get_grant_items_v1() from public,anon;
revoke all on function public.admin_get_used_items_for_member_v1(uuid) from public,anon;
revoke all on function public.get_visible_quests_v1() from public,anon;
revoke all on function public.get_my_character_v1() from public,anon;
revoke all on function public.save_my_character_v1(text,text,text,text,bigint) from public,anon;
grant execute on function public.admin_create_and_grant_event_v1(uuid,uuid,text,text,integer,integer,integer),public.admin_get_grant_items_v1(),public.admin_get_used_items_for_member_v1(uuid),public.get_visible_quests_v1(),public.get_my_character_v1(),public.save_my_character_v1(text,text,text,text,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
