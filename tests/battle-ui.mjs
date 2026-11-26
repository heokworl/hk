import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const dom=new JSDOM('<div id="game"></div>',{runScripts:'outside-only',url:'https://example.test/raid.html?raid=raid-a',pretendToBeVisual:true});
const w=dom.window;
const timers=[];w.setInterval=fn=>{timers.push(fn);return timers.length};w.clearInterval=()=>{};w.confirm=()=>true;
w.eval(readFileSync(new URL('../raid-battle.js',import.meta.url),'utf8'));
let state={quest_id:'raid-a',state:'waiting',turn_no:1,boss_hp:1000,boss_max_hp:1000,boss_name:'균열체',player_damage:20,boss_damage:10,revision:0,can_start:true,logs:[],has_older_logs:false,members:[{user_id:'a',username:'<ABLE>',hp:200,mp:200,acted:false,blocked:false},{user_id:'b',username:'B',hp:200,mp:200,acted:false,blocked:false}]};
let notification,channels=0,removed=0,vitals=0,permission=true,actionCalls=0;
const client={
 async rpc(name,args){
  if(!permission)return {data:null,error:{code:'42501',message:'참여 권한 없음'}};
  if(name==='raid_get_state_v1')return {data:structuredClone(state),error:null};
  if(name==='raid_start_v1'){state.state='active';state.revision++;return {data:'started',error:null}}
  if(name==='raid_submit_action_v1'){
   actionCalls++;assert.equal(args.p_turn_no,1);state.members[0].acted=true;state.revision++;
   state.logs.push({id:1,turn_no:1,kind:'ready',message:'<ABLE> 공격 예약 완료'});
   return {data:'submitted',error:null};
  }
  if(name==='raid_get_logs_v1')return {data:[],error:null};
  throw Error('unexpected '+name);
 },
 channel(){channels++;return {on(type,filter,fn){assert.equal(type,'postgres_changes');assert.equal(filter.filter,'quest_id=eq.raid-a');notification=fn;return this},subscribe(fn){queueMicrotask(()=>fn('SUBSCRIBED'));return this}}},
 removeChannel(){removed++}
};
const container=w.document.querySelector('#game');
const config={client,questId:'raid-a',userId:'a',container,onVitalsChanged:()=>vitals++};
const settle=()=>new Promise(resolve=>setTimeout(resolve,20));
await w.CheonhoRaid.open(config);await settle();
assert(container.querySelector('.raid-start'));assert.equal(channels,1);assert(container.textContent.includes('<ABLE>'));assert.equal(container.querySelector('able'),null);
container.querySelector('.raid-start').click();await settle();assert.equal(state.state,'active');assert(container.querySelector('.raid-attack'));
container.querySelector('.raid-attack').click();container.querySelector('.raid-attack').click();await settle();
assert.equal(actionCalls,1);assert.equal(state.boss_hp,1000);assert(container.querySelector('.raid-attack').disabled);assert(container.textContent.includes('공격을 예약했습니다'));
state.members=state.members.map(m=>({...m,hp:190,acted:false}));state.boss_hp=960;state.turn_no=2;state.revision++;
state.logs.push({id:2,turn_no:1,kind:'counter',message:'B HP -10'},{id:3,turn_no:2,kind:'turn',message:'2턴 시작'});
notification();await settle();assert(container.textContent.includes('960'));assert(container.textContent.includes('B HP -10'));assert(!container.querySelector('.raid-attack').disabled);assert(vitals>0);
// Returning to a suspended page must resubscribe without creating duplicate widgets.
w.CheonhoRaid.suspend();assert(removed>0);w.CheonhoRaid.resume();await settle();assert.equal(container.querySelectorAll('.raid-boss').length,1);assert.equal(channels,2);
// Revoked membership must clear the boss, roster and logs instead of leaving stale content.
permission=false;notification();await settle();assert.equal(container.querySelector('.raid-boss'),null);assert(container.textContent.includes('참여 권한 없음'));assert(!container.textContent.includes('<ABLE>'));
permission=true;container.querySelector('.raid-refresh').click();await settle();assert(container.querySelector('.raid-boss'));
w.CheonhoRaid.destroy();assert.equal(container.children.length,0);
// A late response for a logged-out account must not put protected content back.
let resolveRead;
const delayed={...client,rpc(){return new Promise(resolve=>{resolveRead=resolve})}};
const opening=w.CheonhoRaid.open({...config,client:delayed});w.CheonhoRaid.destroy();resolveRead({data:structuredClone(state),error:null});await opening;
assert.equal(container.children.length,0);
console.log('PASS: raid UI start, single-action, synchronized update, escaped names, reconnect, access revocation and logout checks');
dom.window.close();
