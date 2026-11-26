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
await db.exec(readFileSync(new URL('../raid-test-quests.sql',import.meta.url),'utf8'));
let checks=0;
const solo='test_raid_solo_v1',duo='test_raid_duo_v1';
for(const q of [solo,duo])await db.query('insert into public.quest_participants(quest_id,user_id) values($1,$2)',[q,ids[0]]);
const gate=async q=>{await rpc(ids[2],'admin_set_quest_gate_v2',[q,'close']);await rpc(ids[2],'admin_set_quest_gate_v2',[q,'enable'])};
await gate(duo);await assert.rejects(()=>rpc(ids[0],'raid_start_v1',[duo]));checks++;
await rpc(ids[2],'admin_set_quest_gate_v2',[duo,'reopen']);await db.query('insert into public.quest_participants(quest_id,user_id) values($1,$2)',[duo,ids[1]]);await gate(duo);
await gate(solo);
let a=await rpc(ids[0],'raid_get_state_v1',[solo]);assert(a.boss_max_hp>=40&&a.boss_max_hp<=80);assert.equal(a.boss_hp,a.boss_max_hp);assert(['wisp','shade','guardian','beast'].includes(a.boss_kind));checks++;
assert.deepEqual(await rpc(ids[0],'raid_get_state_v1',[solo]),a);checks++;
const firstBoss={hp:a.boss_max_hp,kind:a.boss_kind,name:a.boss_name};
await rpc(ids[0],'raid_start_v1',[solo]);
while((a=await rpc(ids[0],'raid_get_state_v1',[solo])).state==='active')await rpc(ids[0],'raid_submit_choice_v2',[solo,a.turn_no,'attack',null,null]);
assert.equal(a.state,'victory');assert.equal(a.boss_max_hp,firstBoss.hp);assert(a.logs.some(l=>l.message.includes('HP '+firstBoss.hp)));checks++;
// Starting the next test must not reset profile HP.
const ownHp=(await db.query('select hp from public.guild_profiles where user_id=$1',[ids[0]])).rows[0].hp;
await db.query('update public.guild_profiles set hp=0 where user_id=$1',[ids[1]]);
await rpc(ids[0],'raid_start_v1',[duo]);a=await rpc(ids[0],'raid_get_state_v1',[duo]);assert(a.boss_max_hp>=60&&a.boss_max_hp<=100);assert.equal(a.members.find(m=>m.user_id===ids[0]).hp,ownHp);assert.equal(a.required_count,1);assert.equal(a.members.find(m=>m.user_id===ids[1]).turn_required,false);checks++;
const before=a.boss_hp;await rpc(ids[0],'raid_submit_choice_v2',[duo,1,'attack',null,null]);a=await rpc(ids[0],'raid_get_state_v1',[duo]);assert.equal(a.turn_no,2);assert.equal(a.boss_hp,before-20);assert.equal(a.members.find(m=>m.user_id===ids[1]).hp,0);checks++;
// An ordinary user can heal a different ordinary party member.
await db.query('update public.guild_profiles set hp=10 where user_id=$1',[ids[1]]);
await rpc(ids[0],'raid_submit_choice_v2',[duo,2,'item','healing-potion',ids[1]]);
a=await rpc(ids[1],'raid_get_state_v1',[duo]);assert.equal(a.members.find(m=>m.user_id===ids[1]).hp,10);checks++;
await rpc(ids[1],'raid_submit_choice_v2',[duo,2,'attack',null,null]);a=await rpc(ids[1],'raid_get_state_v1',[duo]);assert.equal(a.members.find(m=>m.user_id===ids[1]).hp,20);assert(a.logs.some(l=>l.kind==='item'&&l.message.includes('HP +20')));checks++;
// A player falling to zero after somebody else has queued does not stall the turn.
await rpc(ids[0],'raid_submit_choice_v2',[duo,3,'attack',null,null]);
await db.query('update public.guild_profiles set hp=0 where user_id=$1',[ids[1]]);
a=await rpc(ids[0],'raid_get_state_v1',[duo]);assert(a.turn_no===4||a.state==='victory');checks++;
const finalTurn=a.turn_no,finalBoss=a.boss_max_hp;
await db.exec(readFileSync(new URL('../raid-test-quests.sql',import.meta.url),'utf8'));
a=await rpc(ids[0],'raid_get_state_v1',[duo]);assert.equal(a.boss_max_hp,finalBoss);assert.equal(a.turn_no,finalTurn);checks++;
console.log('PASS: '+checks+' solo/duo random boss, fixed shared spawn, zero-HP auto-advance and cross-user item tests');
await db.close();
