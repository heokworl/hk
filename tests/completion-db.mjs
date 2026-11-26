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

await db.exec(readFileSync(new URL('../raid-completion-home.sql',import.meta.url),'utf8'));
await db.exec(readFileSync(new URL('../raid-completion-home.sql',import.meta.url),'utf8'));
await db.exec("update public.quest_limits set reward_amount=220 where quest_id='raid-a'; update public.quest_limits set recruitment_closed=true,raid_entry_enabled=true where quest_id='raid-a';");
await rpc(ids[0],'raid_get_state_v1',['raid-a']);
await rpc(ids[0],'raid_start_v1',['raid-a']);
await db.exec("update public.raid_battles set boss_hp=20 where quest_id='raid-a';");
await rpc(ids[0],'raid_submit_choice_v2',['raid-a',1,'attack',null,null]);
await rpc(ids[1],'raid_submit_choice_v2',['raid-a',1,'attack',null,null]);
assert.equal((await db.query("select sum(amount)::int as total from public.quest_reward_payouts where quest_id='raid-a'")).rows[0].total,440);
const terminal=await rpc(ids[0],'raid_get_state_v1',['raid-a']);assert.equal(terminal.state,'victory');assert.equal(terminal.user_reward,220);assert.equal(terminal.members,undefined);
await assert.rejects(()=>rpc(ids[2],'raid_get_state_v1',['raid-a']));
assert.equal(await rpc(ids[2],'award_quest',['raid-a']),'already_awarded');
await db.exec(readFileSync(new URL('../raid-completion-home.sql',import.meta.url),'utf8'));
assert.equal((await db.query('select count(*)::int as n from public.quest_reward_payouts')).rows[0].n,2);
for(const q of ['raid-b']){await db.query('update public.quest_limits set recruitment_closed=true,raid_entry_enabled=true,reward_amount=101,reward_mode=$2 where quest_id=$1',[q,q==='raid-b'?'team_pool':'per_user']);await rpc(ids[0],'raid_get_state_v1',[q]);await rpc(ids[0],'raid_start_v1',[q]);}
await db.exec("update public.guild_profiles set hp=0 where user_id='22222222-2222-4222-8222-222222222222'; update public.raid_battles set boss_hp=20 where quest_id='raid-b';");
await rpc(ids[0],'raid_submit_choice_v2',['raid-b',1,'attack',null,null]);
assert.equal((await db.query("select sum(amount)::int as total from public.quest_reward_payouts where quest_id='raid-b'")).rows[0].total,101);
assert.equal((await db.query("select count(*)::int as n from public.quest_reward_payouts where quest_id='raid-b'")).rows[0].n,2);
await db.exec("update public.guild_profiles set hp=200;update public.quest_limits set recruitment_closed=true,raid_entry_enabled=true,reward_amount=100 where quest_id='raid-c';");await rpc(ids[0],'raid_get_state_v1',['raid-c']);await rpc(ids[0],'raid_start_v1',['raid-c']);await db.exec("update public.guild_profiles set hp=0;");
const defeat=await rpc(ids[0],'raid_get_state_v1',['raid-c']);assert.equal(defeat.state,'defeat');assert.equal(defeat.user_reward,0);
assert.equal((await db.query("select count(*)::int as n from public.quest_reward_payouts where quest_id='raid-c'")).rows[0].n,0);
console.log('completion DB: payout, terminal access, team pool, dead member rewards, defeat, idempotence passed');await db.close();
