import {installGuildFixture} from './guild-ui-fixture.mjs';
import {JSDOM} from 'jsdom';
import {readFileSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const html=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const dom=new JSDOM(html,{runScripts:'outside-only',url:'https://test/index.html',pretendToBeVisual:true});
const w=dom.window;w.setInterval=()=>1;w.confirm=()=>true;w.matchMedia=()=>({matches:false});w.HTMLElement.prototype.scrollIntoView=()=>{};
let authCallback;
const users=[{user_id:'a',username:'ABLE',balance:0},{user_id:'b',username:'BETA',balance:80}];
let used=[{use_id:1,user_id:'a',username:'ABLE',item_id:'p',item_name:'회복 물약',used_at:'2026-11-26T00:00:00Z'},{use_id:2,user_id:'b',username:'BETA',item_id:'k',item_name:'야영 도구',used_at:'2026-11-26T00:01:00Z'}];
const client={auth:{onAuthStateChange(cb){authCallback=cb},async getSession(){return {data:{session:null},error:null}}},async rpc(name,args){
 let data;
 switch(name){
 case 'get_my_wallet':data={username:'관리자',balance:0,is_admin:true};break;
 case 'admin_get_users':data=users;break;
 case 'admin_get_member_status_v1':data=[{user_id:'a',username:'ABLE',hp:0,mp:200},{user_id:'b',username:'BETA',hp:150,mp:120}];break;
 case 'admin_get_used_items':data=used;break;
 case 'admin_restore_used_item':used=used.filter(x=>x.use_id!==args.p_use_id);data='restored';break;
 case 'admin_grant_gold':users.find(x=>x.user_id===args.p_user_id).balance+=args.p_amount;data='granted';break;
 case 'get_member_stats_v3':data={hp:200,mp:200};break;
 case 'get_quest_status':data=[];break;
 case 'get_quest_details_v3':data=[];break;
 default:data=[];
 }
 return {data,error:null};
}};
installGuildFixture(w,client,html);w.supabase={createClient(){return client}};
for(const script of [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(x=>x[1]).filter(x=>x.trim()))w.eval(script);
const settle=()=>new Promise(resolve=>setTimeout(resolve,45));
await settle();authCallback('SIGNED_IN',{user:{id:'admin',user_metadata:{display_name:'관리자'}}});await settle();
w.document.querySelector('[data-page="admin"]').click();await settle();
assert.equal(w.document.querySelectorAll('.admin-pane:not(.hidden)').length,1);
assert.equal(w.document.querySelector('#adminSummaryUsers').textContent,'2');
assert.equal(w.document.querySelectorAll('#memberStatusRows tr').length,2);
assert.equal(w.document.querySelector('#memberStatusRows .vital-hp').value,0);
const search=w.document.querySelector('#adminMemberSearch');search.value='ABLE';search.dispatchEvent(new w.Event('input'));
assert.equal(w.document.querySelectorAll('#memberStatusRows tr').length,1);
w.document.querySelector('[data-admin-select="a"]').click();
assert.equal(w.document.querySelector('#adminUserSelect').value,'a');
w.document.querySelector('#adminGoldAmount').value='25';w.document.querySelector('#adminGoldButton').click();await settle();
assert(w.document.querySelector('#adminStatus').textContent.includes('25G'));assert(w.document.querySelector('#memberStatusRows').textContent.includes('25G'));
w.document.querySelector('[data-admin-tab="quests"]').click();assert(!w.document.querySelector('#adminPane-quests').classList.contains('hidden'));assert(w.document.querySelector('#adminPane-members').classList.contains('hidden'));
w.document.querySelector('[data-admin-tab="quests"]').dispatchEvent(new w.KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
assert.equal(w.document.querySelector('[data-admin-tab="shop"]').getAttribute('aria-selected'),'true');
w.document.querySelector('[data-admin-tab="restore"]').click();const restoreMember=w.document.querySelector('#adminRestoreMember');restoreMember.value='a';restoreMember.dispatchEvent(new w.Event('change'));await settle();const filter=w.document.querySelector('#adminRestoreSearch');filter.value='물약';filter.dispatchEvent(new w.Event('input'));
assert.equal(w.document.querySelectorAll('#adminUsedItems .admin-used-row').length,1);
w.document.querySelector('#adminUsedItems [data-restore-use]').click();await settle();assert(w.document.querySelector('#adminRestoreStatus').textContent.includes('복구했습니다'));
assert.equal(w.document.querySelector('#adminSummaryRestore').textContent,'0');
// All original form hooks remain unique and reachable after reorganization.
for(const id of ['adminGoldButton','adminItemButton','adminProductForm','adminBlockUser','blockQuestUser','adminQuestGateList','memberStatusRows'])assert.equal(w.document.querySelectorAll('#'+id).length,1);
if(process.env.ADMIN_PREVIEW){
 w.document.querySelector('[data-admin-tab="members"]').click();search.value='';search.dispatchEvent(new w.Event('input'));
 writeFileSync(process.env.ADMIN_PREVIEW,'<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'+[...w.document.querySelectorAll('style')].map(x=>x.outerHTML).join('')+'</head><body><main class="shell"><section class="panel">'+w.document.querySelector('#adminPage').outerHTML+'</section></main></body></html>');
}
authCallback('SIGNED_OUT',null);await settle();assert.equal(w.document.querySelector('#memberStatusRows').children.length,0);
dom.window.close();console.log('PASS: compact admin tabs, merged HP/MP/gold roster, search, target selection, grant feedback, restore feedback and logout');
