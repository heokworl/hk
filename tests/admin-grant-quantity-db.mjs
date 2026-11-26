import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`
 create role anon; create role authenticated;
 create schema auth; create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.uid',true),'')::uuid$$;
 create table public.guild_profiles(user_id uuid primary key references auth.users(id),username text,username_key text,hp integer not null default 200,mp integer not null default 200);
 create table public.quest_limits(quest_id text primary key,active boolean default true,category text default 'raid',game_version integer default 1,max_members integer default 5,awarded_at timestamptz);
 create table public.quest_participants(quest_id text references public.quest_limits,user_id uuid references auth.users(id),joined_at timestamptz default now(),primary key(quest_id,user_id));
 create table public.quest_entry_blocks(user_id uuid references auth.users(id),quest_key text,primary key(user_id,quest_key));
 create publication supabase_realtime;
`);
await db.exec(readFileSync(new URL('../raid-battle-setup.sql',import.meta.url),'utf8'));
// Re-running setup must preserve state and logs.
await db.exec(readFileSync(new URL('../raid-battle-setup.sql',import.meta.url),'utf8'));
const ids=['11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333'];
for(let i=0;i<3;i++){
 await db.query('insert into auth.users values($1)',[ids[i]]);
 await db.query('insert into public.guild_profiles(user_id,username,username_key) values($1,$2,$2)',[ids[i],'USER'+i]);
}
await db.exec("insert into public.quest_limits(quest_id) values('raid-a'),('raid-b'),('raid-c');");
for(const q of ['raid-a','raid-b','raid-c'])for(const u of ids.slice(0,2))await db.query('insert into public.quest_participants(quest_id,user_id) values($1,$2)',[q,u]);
async function asUser(uid,sql,args=[]){
 return db.transaction(async tx=>{
   await tx.query("select set_config('app.uid',$1,true)",[uid||'']);
   await tx.exec('set local role authenticated');
   return tx.query(sql,args);
 });
}
const rpc=(uid,name,args=[])=>asUser(uid,'select public.'+name+'('+args.map((_,i)=>'$'+(i+1)).join(',')+') as result',args).then(r=>r.rows[0].result);
const state=uid=>rpc(uid,'raid_get_state_v1',['raid-a']);
await db.exec(`
 create table public.quest_admins(user_id uuid primary key references auth.users(id));
 create table public.shop_items(id text primary key,name text,description text default '',active boolean default true);
 create table public.shop_purchases(user_id uuid,item_id text references public.shop_items,quantity integer,primary key(user_id,item_id));
 create table public.shop_item_grants(id bigint generated always as identity primary key,user_id uuid,item_id text references public.shop_items);
 create table public.shop_item_uses(id bigint generated always as identity primary key,user_id uuid,item_id text references public.shop_items,used_at timestamptz default now(),restored_at timestamptz);
 create function public.get_my_inventory() returns table(item_id text,item_name text,description text,quantity bigint)
 language sql stable security definer set search_path='' as $$
  select i.id,i.name,i.description,coalesce((select sum(p.quantity) from public.shop_purchases p where p.user_id=auth.uid() and p.item_id=i.id),0)
   +(select count(*) from public.shop_item_grants g where g.user_id=auth.uid() and g.item_id=i.id)
   -(select count(*) from public.shop_item_uses u where u.user_id=auth.uid() and u.item_id=i.id and u.restored_at is null)
  from public.shop_items i where exists(select 1 from public.shop_purchases p where p.user_id=auth.uid() and p.item_id=i.id);
 $$;
 insert into public.shop_items(id,name) values('healing-potion','초급 회복약');
`);
await db.query('insert into public.quest_admins values($1)',[ids[2]]);
for(const uid of ids.slice(0,2))await db.query("insert into public.shop_purchases values($1,'healing-potion',3)",[uid]);
await db.exec(readFileSync(new URL('../raid-battle-update-v2.sql',import.meta.url),'utf8'));
await db.exec(`
 alter table public.shop_item_grants add column granted_by uuid references auth.users(id),add column granted_at timestamptz not null default now();
 alter table public.shop_item_grants add constraint original_one_each unique(user_id,item_id);
 create unique index legacy_one_each_idx on public.shop_item_grants(item_id,user_id);
 alter table public.shop_item_grants add constraint keep_other_unique unique(id,granted_by);
`);
await db.query("insert into public.shop_item_grants(user_id,item_id,granted_by) values($1,'healing-potion',$2)",[ids[0],ids[2]]);
await db.query("insert into public.shop_item_uses(user_id,item_id,target_user_id) values($1,'healing-potion',$2)",[ids[0],ids[1]]);
await db.exec(readFileSync(new URL('../admin-grant-item-quantity.sql',import.meta.url),'utf8'));
let checks=0;
const grant=(user,target,item,n)=>rpc(user,'admin_grant_shop_items_v2',[target,item,n]);
let r=await grant(ids[2],ids[0],'healing-potion',5);assert.equal(r.quantity,5);assert.equal(r.owned_quantity,8);checks++;
r=await grant(ids[2],ids[0],'healing-potion',2);assert.equal(r.owned_quantity,10);checks++;
assert.equal(await rpc(ids[2],'admin_grant_shop_item',[ids[0],'healing-potion']),'granted');
assert.equal((await asUser(ids[0],'select * from public.get_my_inventory()')).rows[0].quantity,11);checks++;
// Administrator recipients and repeated grants are explicitly allowed.
assert.equal((await grant(ids[2],ids[2],'healing-potion',3)).owned_quantity,3);assert.equal((await grant(ids[2],ids[2],'healing-potion',4)).owned_quantity,7);checks++;
await assert.rejects(()=>grant(ids[0],ids[1],'healing-potion',2));checks++;
for(const n of [0,-1,1001,null])await assert.rejects(()=>grant(ids[2],ids[1],'healing-potion',n));checks++;
await assert.rejects(()=>grant(ids[2],'44444444-4444-4444-8444-444444444444','healing-potion',1));await assert.rejects(()=>grant(ids[2],ids[1],'missing',1));checks++;
await db.exec("insert into public.shop_items(id,name,active) values('inactive','비활성',false)");await assert.rejects(()=>grant(ids[2],ids[1],'inactive',1));checks++;
await assert.rejects(()=>asUser(ids[0],"insert into public.shop_item_grants(user_id,item_id,granted_by) values($1,'healing-potion',$2)",[ids[0],ids[2]]));checks++;
const both=await Promise.all([grant(ids[2],ids[1],'healing-potion',4),grant(ids[2],ids[1],'healing-potion',7)]);assert.equal(Math.max(...both.map(x=>x.owned_quantity)),14);checks++;
assert.equal((await db.query("select count(*)::int n from pg_constraint where conrelid='public.shop_item_grants'::regclass and conname='keep_other_unique'")).rows[0].n,1);assert.equal((await db.query("select count(*)::int n from pg_constraint where conrelid='public.shop_item_grants'::regclass and contype='p'")).rows[0].n,1);checks++;
await db.exec("insert into public.shop_items(id,name) values('fail-grant','오류 테스트')");
await db.exec(`create function public.reject_third_grant() returns trigger language plpgsql as $$begin if new.item_id='fail-grant' and (select count(*) from public.shop_item_grants where item_id=new.item_id)>=2 then raise exception 'simulated failure';end if;return new;end;$$;create trigger reject_third_grant before insert on public.shop_item_grants for each row execute function public.reject_third_grant();`);
await assert.rejects(()=>grant(ids[2],ids[1],'fail-grant',5));assert.equal((await db.query("select count(*)::int n from public.shop_item_grants where item_id='fail-grant'")).rows[0].n,0);checks++;
const before=(await db.query('select count(*)::int n from public.shop_item_grants')).rows[0].n;
await db.exec(readFileSync(new URL('../admin-grant-item-quantity.sql',import.meta.url),'utf8'));assert.equal((await db.query('select count(*)::int n from public.shop_item_grants')).rows[0].n,before);checks++;
console.log('PASS: '+checks+' repeated and multi-quantity grants, admin recipients, inventory counts, legacy RPC, access checks, atomic rollback and safe migration checks');
await db.close();
