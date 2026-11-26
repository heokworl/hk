import {JSDOM} from 'jsdom';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const dom=new JSDOM('<div id="game"></div>',{runScripts:'outside-only',url:'https://test/raid.html?raid=raid-a',pretendToBeVisual:true});
const w=dom.window;w.setInterval=()=>1;w.clearInterval=()=>{};
w.eval(readFileSync(new URL('../raid-battle.js',import.meta.url),'utf8'));
let state={quest_id:'raid-a',state:'active',turn_no:1,boss_hp:1000,boss_max_hp:1000,boss_name:'균열체',player_damage:20,boss_damage:10,revision:1,can_start:false,logs:[],has_older_logs:false,
 members:[{user_id:'a',username:'ABLE',hp:200,mp:200,acted:false,blocked:false,can_target:true},{user_id:'b',username:'대상',hp:100,mp:200,acted:false,blocked:false,can_target:true},{user_id:'admin',username:'관리자',hp:200,mp:200,acted:false,blocked:false,can_target:false}],
 inventory:[{item_id:'potion',item_name:'회복약',description:'HP 20 회복',quantity:2,reserved:0,hp_restore:20,mp_restore:0}]};
let notification,calls=0;
const client={async rpc(name,args){
 if(name==='raid_get_state_v1')return {data:structuredClone(state),error:null};
 if(name==='raid_submit_choice_v2'){
  calls++;assert.equal(args.p_action,'item');assert.equal(args.p_item_id,'potion');assert.equal(args.p_target_user_id,'b');assert.equal(args.p_turn_no,1);
  state.members[0].acted=true;state.inventory[0].quantity=1;state.inventory[0].reserved=1;state.revision++;
  return {data:'submitted',error:null};
 }
 throw Error('unexpected '+name);
},channel(){return {on(t,f,cb){notification=cb;return this},subscribe(){return this}}},removeChannel(){}};
const container=w.document.querySelector('#game');
await w.CheonhoRaid.open({client,questId:'raid-a',userId:'a',container});
const settle=()=>new Promise(resolve=>setTimeout(resolve,20));
assert(container.querySelector('.raid-inventory'));assert.equal(container.querySelectorAll('[data-raid-target] option').length,3);
assert(![...container.querySelectorAll('option')].some(x=>x.value==='admin'));
const select=container.querySelector('[data-raid-target]');select.value='b';select.dispatchEvent(new w.Event('change'));
assert(!container.querySelector('[data-raid-use]').disabled);
container.querySelector('[data-raid-use]').click();container.querySelector('.raid-attack').click();await settle();
assert.equal(calls,1);assert.equal(state.boss_hp,1000);assert.equal(state.members[1].hp,100);
assert(container.querySelector('.raid-attack').disabled);assert(container.querySelector('[data-raid-use]').disabled);assert(container.textContent.includes('예약 1개'));
state.turn_no=2;state.revision++;state.members[0].acted=false;state.members[1].hp=110;state.inventory[0].reserved=0;state.boss_hp=960;
state.logs=[{id:1,turn_no:1,kind:'item',message:'ABLE → 대상 · 회복약 HP +20'},{id:2,turn_no:1,kind:'counter',message:'대상 HP -10'}];
notification();await settle();assert(!container.querySelector('.raid-attack').disabled);assert(container.textContent.includes('HP +20'));assert(container.textContent.includes('110 / 200'));
w.CheonhoRaid.destroy();dom.window.close();
console.log('PASS: right inventory, target filtering, item-only action slot, delayed effects and next-turn refresh');
