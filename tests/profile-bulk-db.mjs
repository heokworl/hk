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
await db.exec(readFileSync(new URL('../profile-bulk-item-use.sql',import.meta.url),'utf8'));
const bulk=(uid,item,target,n)=>rpc(uid,'use_shop_items_bulk_v1',[item,target,n]);
let checks=0;
await db.query('update public.guild_profiles set hp=0 where user_id=$1',[ids[1]]);
let r=await bulk(ids[0],'healing-potion',ids[1],3);assert.equal(r.used_quantity,3);assert.equal(r.hp,60);assert.equal(r.hp_restored,60);checks++;
assert.equal((await db.query('select count(*)::int n from public.shop_item_uses')).rows[0].n,3);checks++;
await db.query('update public.shop_purchases set quantity=10 where user_id=$1',[ids[0]]);
await db.query('update public.guild_profiles set hp=190 where user_id=$1',[ids[1]]);
r=await bulk(ids[0],'healing-potion',ids[1],5);assert.equal(r.used_quantity,1);assert.equal(r.unused_quantity,4);assert.equal(r.hp,200);assert.equal(r.hp_restored,10);checks++;
const before=(await db.query('select count(*)::int n from public.shop_item_uses')).rows[0].n;
assert.equal((await bulk(ids[0],'healing-potion',ids[1],2)).status,'already_full');assert.equal((await db.query('select count(*)::int n from public.shop_item_uses')).rows[0].n,before);checks++;
assert.equal((await bulk(ids[0],'healing-potion',ids[1],999)).status,'not_owned');checks++;
await assert.rejects(()=>bulk(ids[0],'healing-potion',ids[1],0));await assert.rejects(()=>bulk(ids[0],'healing-potion',ids[1],1001));checks++;
await assert.rejects(()=>bulk(ids[0],'healing-potion',ids[2],1));checks++;
await db.exec("insert into public.shop_items(id,name,hp_restore,mp_restore) values('dual','혼합 물약',20,5),('generic','일반 아이템',0,0),('rollback-potion','원자성 물약',20,0)");
for(const item of ['dual','generic','rollback-potion'])await db.query('insert into public.shop_purchases values($1,$2,5)',[ids[0],item]);
await db.query('update public.guild_profiles set hp=190,mp=190 where user_id=$1',[ids[1]]);
r=await bulk(ids[0],'dual',ids[1],5);assert.equal(r.used_quantity,2);assert.equal(r.hp_restored,10);assert.equal(r.mp_restored,10);assert.equal(r.hp,200);assert.equal(r.mp,200);checks++;
r=await bulk(ids[0],'generic',ids[1],3);assert.equal(r.used_quantity,3);assert.equal(r.hp_restored,0);checks++;
await db.query('update public.shop_purchases set quantity=6 where user_id=$1 and item_id=$2',[ids[0],'healing-potion']);
await db.query('update public.guild_profiles set hp=0 where user_id=$1',[ids[1]]);
const results=await Promise.all([bulk(ids[0],'healing-potion',ids[1],2),bulk(ids[0],'healing-potion',ids[1],2)]);
assert.equal(results.filter(x=>x.status==='used').length,1);assert.equal(results.filter(x=>x.status==='not_owned').length,1);assert.equal((await db.query('select hp from public.guild_profiles where user_id=$1',[ids[1]])).rows[0].hp,40);checks++;
await db.exec(`create function public.reject_second_bulk() returns trigger language plpgsql as $$begin if new.item_id='rollback-potion' and exists(select 1 from public.shop_item_uses where user_id=new.user_id and item_id=new.item_id) then raise exception 'simulated write failure';end if;return new;end;$$;create trigger reject_second_bulk before insert on public.shop_item_uses for each row execute function public.reject_second_bulk();`);
await assert.rejects(()=>bulk(ids[0],'rollback-potion',ids[1],3));
assert.equal((await db.query("select count(*)::int n from public.shop_item_uses where item_id='rollback-potion'")).rows[0].n,0);assert.equal((await db.query('select hp from public.guild_profiles where user_id=$1',[ids[1]])).rows[0].hp,40);checks++;
await db.query("insert into public.shop_purchases values($1,'healing-potion',3)",[ids[2]]);await db.query('update public.guild_profiles set hp=0 where user_id=$1',[ids[2]]);
r=await bulk(ids[2],'healing-potion',ids[2],2);assert.equal(r.used_quantity,2);assert.equal(r.hp,40);checks++;
await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','close']);await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','enable']);await rpc(ids[0],'raid_start_v1',['raid-a']);
assert.equal((await bulk(ids[2],'healing-potion',ids[1],1)).status,'in_battle');assert.equal((await bulk(ids[0],'generic',ids[0],1)).status,'in_battle');checks++;
console.log('PASS: '+checks+' bulk quantity, cap-aware consumption, target permissions, concurrent stock, atomic rollback and battle guard checks');
await db.close();
