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
let checks=0;
async function denied(fn){await assert.rejects(fn);checks++}
await denied(()=>state(ids[2]));
await denied(()=>state(null));
assert.equal((await state(ids[0])).state,'waiting');checks++;
assert.equal(await rpc(ids[0],'raid_start_v1',['raid-a']),'started');checks++;
assert.equal(await rpc(ids[1],'raid_start_v1',['raid-a']),'already_started');checks++;
await denied(()=>rpc(ids[0],'raid_start_v1',['raid-b']));
await denied(()=>db.query('insert into public.quest_participants(quest_id,user_id) values($1,$2)',['raid-a',ids[2]]));
await denied(()=>asUser(ids[0],"update public.raid_battles set boss_hp=0 where quest_id='raid-a'"));
assert.equal(await rpc(ids[0],'raid_submit_action_v1',['raid-a',1]),'submitted');
let a=await state(ids[0]);assert.equal(a.boss_hp,1000);assert.equal(a.turn_no,1);assert(a.members.every(x=>x.hp===200));checks++;
assert.equal(await rpc(ids[0],'raid_submit_action_v1',['raid-a',1]),'already_acted');checks++;
assert.equal(await rpc(ids[1],'raid_submit_action_v1',['raid-a',1]),'submitted');
a=await state(ids[0]);assert.equal(a.boss_hp,960);assert.equal(a.turn_no,2);assert(a.members.every(x=>x.hp===190));checks++;
const b=await state(ids[1]);assert.deepEqual(a,b);checks++;
assert.equal(await rpc(ids[0],'raid_submit_action_v1',['raid-a',1]),'stale_turn');checks++;
await db.query('update public.guild_profiles set hp=0 where user_id=$1',[ids[1]]);
assert.equal(await rpc(ids[1],'raid_submit_action_v1',['raid-a',2]),'incapacitated');checks++;
await rpc(ids[0],'raid_submit_action_v1',['raid-a',2]);a=await state(ids[0]);assert.equal(a.turn_no,3);assert.equal(a.boss_hp,940);assert.equal(a.members.find(m=>m.user_id===ids[0]).hp,180);checks++;
// Revived participants are eligible in the new turn; all alive members must act again.
await db.query('update public.guild_profiles set hp=20 where user_id=$1',[ids[1]]);
await db.exec("update public.raid_battles set boss_hp=20 where quest_id='raid-a';");
await rpc(ids[0],'raid_submit_action_v1',['raid-a',3]);assert.equal((await state(ids[0])).state,'active');checks++;
await rpc(ids[1],'raid_submit_action_v1',['raid-a',3]);a=await state(ids[0]);assert.equal(a.state,'victory');assert.equal(a.boss_hp,0);assert.equal(a.members.find(m=>m.user_id===ids[0]).hp,180);checks++;
assert.equal(await rpc(ids[0],'raid_submit_action_v1',['raid-a',3]),'not_active');checks++;
// Concurrent duplicate submissions through independent transactions still resolve only once.
await rpc(ids[0],'raid_start_v1',['raid-b']);
const results=await Promise.all([rpc(ids[0],'raid_submit_action_v1',['raid-b',1]),rpc(ids[0],'raid_submit_action_v1',['raid-b',1]),rpc(ids[1],'raid_submit_action_v1',['raid-b',1])]);
assert.equal(results.filter(x=>x==='submitted').length,2);assert.equal((await rpc(ids[1],'raid_get_state_v1',['raid-b'])).turn_no,2);checks++;
await db.exec('update public.guild_profiles set hp=0;');
assert.equal((await rpc(ids[0],'raid_get_state_v1',['raid-b'])).state,'defeat');checks++;
// Read RLS must hide even the revision stream from nonparticipants.
assert.equal((await asUser(ids[2],'select count(*)::int as n from public.raid_battles')).rows[0].n,0);checks++;
await db.query('insert into public.quest_entry_blocks values($1,$2)',[ids[1],'*']);
await denied(()=>state(ids[1]));
// Logs are paginated and only accessible to the same authorized participants.
await db.exec("insert into public.raid_logs(quest_id,turn_no,kind,message) select 'raid-a',3,'test','record '||x from generate_series(1,130) x;");
a=await state(ids[0]);assert.equal(a.logs.length,100);assert.equal(a.has_older_logs,true);
const older=await rpc(ids[0],'raid_get_logs_v1',['raid-a',a.logs[0].id]);assert(older.length>0);assert(older.every(l=>l.id<a.logs[0].id));checks++;
await denied(()=>rpc(ids[2],'raid_get_logs_v1',['raid-a',10000]));
const before=(await db.query('select count(*)::int as n from public.raid_logs')).rows[0].n;
await db.exec(readFileSync(new URL('../raid-battle-setup.sql',import.meta.url),'utf8'));
assert.equal((await state(ids[0])).state,'victory');assert.equal((await db.query('select count(*)::int as n from public.raid_logs')).rows[0].n,before);checks++;
console.log('PASS: '+checks+' database behavior and access checks');
await db.close();
