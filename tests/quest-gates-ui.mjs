import {installGuildFixture} from './guild-ui-fixture.mjs';
import {JSDOM} from 'jsdom';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const html=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const dom=new JSDOM(html,{runScripts:'outside-only',url:'https://test/index.html',pretendToBeVisual:true});
const w=dom.window;w.setInterval=()=>1;w.confirm=()=>true;
w.matchMedia=()=>({matches:false,addEventListener(){},removeEventListener(){}});
let authCallback,admin=true,closed=false,enabled=false;
const uid='11111111-1111-4111-8111-111111111111';
const client={auth:{onAuthStateChange(cb){authCallback=cb},async getSession(){return {data:{session:null},error:null}},async getUser(){return {data:{user:{id:uid}},error:null}}},async rpc(name,args){
 let data;
 switch(name){
  case 'get_my_wallet':data={username:'ABLE',balance:0,is_admin:admin};break;
  case 'get_quest_status':data=[{quest_id:'quarantine_clear',participant_count:1,has_joined:true,awarded:false}];break;
  case 'get_quest_details_v3':data=[{quest_id:'quarantine_clear',category:'raid',participants:['ABLE'],blocked:false,recruitment_closed:closed,raid_entry_enabled:enabled,battle_started:false}];break;
  case 'get_member_stats_v3':data={hp:200,mp:200};break;
  case 'get_item_targets_v3':data=[{user_id:uid,username:'ABLE'}];break;
  case 'admin_set_quest_gate_v2':
   if(args.p_command==='close'){closed=true;enabled=false}
   if(args.p_command==='enable'){assert(closed);enabled=true}
   data='saved';break;
  default:data=[];
 }
 return {data,error:null};
}};
installGuildFixture(w,client,html);w.supabase={createClient(){return client}};
const scripts=[...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(x=>x[1]).filter(x=>x.trim());
for(const script of scripts)w.eval(script);
const settle=()=>new Promise(resolve=>setTimeout(resolve,50));
await settle();authCallback('SIGNED_IN',{user:{id:uid,user_metadata:{display_name:'ABLE'}}});await settle();
w.document.querySelector('[data-category="raid"]').click();
const card=()=>w.document.querySelector('[data-quest="quarantine_clear"]').closest('.quest-card');
assert(card().querySelector('[data-gate="close"]'));assert(!card().querySelector('a[href*="raid.html"]'));assert(card().querySelector('[data-gate="enable"]').disabled);
card().querySelector('[data-gate="close"]').click();await settle();assert(closed);assert(!card().querySelector('a[href*="raid.html"]'));assert(!card().querySelector('[data-gate="enable"]').disabled);
card().querySelector('[data-gate="enable"]').click();await settle();assert(enabled);assert(card().querySelector('a[href*="raid.html"]'));
authCallback('SIGNED_OUT',null);await settle();admin=false;authCallback('SIGNED_IN',{user:{id:uid,user_metadata:{display_name:'ABLE'}}});await settle();w.document.querySelector('[data-category="raid"]').click();
assert.equal(w.document.querySelectorAll('[data-gate]').length,0);assert(card().querySelector('a[href*="raid.html"]'));
dom.window.close();console.log('PASS: admin-only gate buttons, close-before-enable and participant entry link visibility');
