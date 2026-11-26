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
let checks=0;
async function denied(fn){await assert.rejects(fn);checks++}
await denied(()=>state(ids[0]));
await denied(()=>rpc(ids[0],'admin_set_quest_gate_v2',['raid-a','close']));
await denied(()=>rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','enable']));
assert.equal(await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','close']),'saved');checks++;
await denied(()=>db.query('insert into public.quest_participants(quest_id,user_id) values($1,$2)',['raid-a',ids[2]]));
await denied(()=>state(ids[0]));
await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','enable']);
assert.equal((await state(ids[0])).state,'waiting');checks++;
await denied(()=>state(ids[2]));
await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','reopen']);await denied(()=>state(ids[0]));
await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','close']);await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','enable']);
await rpc(ids[0],'raid_start_v1',['raid-a']);
await denied(()=>rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','reopen']));
await db.query('update public.guild_profiles set hp=100 where user_id=$1',[ids[1]]);
const choice=(uid,turn,kind,item=null,target=null)=>rpc(uid,'raid_submit_choice_v2',['raid-a',turn,kind,item,target]);
assert.equal(await choice(ids[0],1,'item','healing-potion',ids[1]),'submitted');
let a=await state(ids[0]);assert.equal(a.boss_hp,1000);assert.equal(a.members.find(m=>m.user_id===ids[1]).hp,100);assert.equal(a.inventory[0].quantity,2);assert.equal(a.inventory[0].reserved,1);checks++;
assert.equal(await choice(ids[0],1,'attack'),'already_acted');checks++;
await denied(()=>choice(ids[1],1,'item','healing-potion',ids[2]));
assert.equal(await choice(ids[1],1,'attack'),'submitted');
a=await state(ids[0]);assert.equal(a.turn_no,2);assert.equal(a.boss_hp,980);assert.equal(a.members.find(m=>m.user_id===ids[1]).hp,110);assert.equal(a.inventory[0].quantity,2);assert.equal(a.inventory[0].reserved,0);checks++;
assert.equal((await db.query("select count(*)::int n from public.shop_item_uses")).rows[0].n,1);checks++;
const use=(await db.query('select * from public.shop_item_uses')).rows[0];assert.equal(use.hp_restored,20);assert.equal(use.raid_quest_id,'raid-a');assert.equal(use.target_user_id,ids[1]);checks++;
assert.equal(await choice(ids[0],1,'item','healing-potion',ids[1]),'stale_turn');checks++;
// Ordinary players cannot target an administrator in the roster.
await db.query('insert into public.quest_admins values($1)',[ids[1]]);
assert.equal((await state(ids[0])).members.find(m=>m.user_id===ids[1]).can_target,false);checks++;
await denied(()=>choice(ids[0],2,'item','healing-potion',ids[1]));
await db.query('delete from public.quest_admins where user_id=$1',[ids[1]]);
await db.query('update public.guild_profiles set hp=200 where user_id=$1',[ids[1]]);
assert.equal(await choice(ids[0],2,'item','healing-potion',ids[1]),'already_full');checks++;
assert.equal((await state(ids[0])).members.find(m=>m.user_id===ids[0]).acted,false);checks++;
await db.query('update public.guild_profiles set hp=120 where user_id=$1',[ids[1]]);
await choice(ids[0],2,'item','healing-potion',ids[1]);
// Restore targets may become full before turn resolution: do not consume, but do spend the turn.
await db.query('update public.guild_profiles set hp=200 where user_id=$1',[ids[1]]);
await choice(ids[1],2,'attack');a=await state(ids[0]);assert.equal(a.turn_no,3);assert.equal(a.inventory[0].quantity,2);assert.equal(a.inventory[0].reserved,0);checks++;
// External/profile uses cannot bypass the action limit, and their profile updates roll back.
const before=(await state(ids[0])).members.find(m=>m.user_id===ids[1]).hp;
await denied(()=>db.transaction(async tx=>{
 await tx.query("select set_config('app.uid',$1,true)",[ids[0]]);
 await tx.query('update public.guild_profiles set hp=200 where user_id=$1',[ids[1]]);
 await tx.query("insert into public.shop_item_uses(user_id,item_id,target_user_id) values($1,'healing-potion',$2)",[ids[0],ids[1]]);
}));
assert.equal((await state(ids[0])).members.find(m=>m.user_id===ids[1]).hp,before);checks++;
// All attackers/items share one unique action slot, including requests from multiple tabs.
const results=await Promise.all([choice(ids[0],3,'item','healing-potion',ids[1]),choice(ids[0],3,'attack'),choice(ids[1],3,'attack')]);
assert.equal(results.filter(x=>x==='submitted').length,2);assert.equal((await state(ids[0])).turn_no,4);checks++;
await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','disable']);await denied(()=>state(ids[0]));
await denied(()=>choice(ids[0],4,'attack'));await rpc(ids[2],'admin_set_quest_gate_v2',['raid-a','enable']);
// A transaction failure during effect application must roll back the final action and all HP changes.
await choice(ids[0],4,'item','healing-potion',ids[1]);
const previous=await state(ids[0]);
await db.exec(`create function public.test_reject_item() returns trigger language plpgsql as $$begin raise exception 'test write failure';end;$$; create trigger test_reject_item before insert on public.shop_item_uses for each row execute function public.test_reject_item();`);
await denied(()=>choice(ids[1],4,'attack'));
assert.deepEqual((await state(ids[0])).members.map(m=>[m.hp,m.acted]),previous.members.map(m=>[m.hp,m.acted]));checks++;
await db.exec('drop trigger test_reject_item on public.shop_item_uses;');
await choice(ids[1],4,'attack');assert.equal((await state(ids[0])).turn_no,5);checks++;
const count=(await db.query('select count(*)::int n from public.shop_item_uses')).rows[0].n;
await db.exec(readFileSync(new URL('../raid-battle-update-v2.sql',import.meta.url),'utf8'));
assert.equal((await state(ids[0])).turn_no,5);assert.equal((await db.query('select count(*)::int n from public.shop_item_uses')).rows[0].n,count);checks++;
await db.exec(readFileSync(new URL('../raid-battle-controls-items.sql',import.meta.url),'utf8'));
assert.equal((await state(ids[0])).turn_no,5);assert.equal((await db.query('select count(*)::int n from public.shop_item_uses')).rows[0].n,count);checks++;
console.log('PASS: '+checks+' recruitment, entry authorization, item reservation, exclusive action and atomic healing checks');
await db.close();
