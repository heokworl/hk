import {installGuildFixture} from './guild-ui-fixture.mjs';
import {JSDOM} from 'jsdom';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const html=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const dom=new JSDOM(html,{runScripts:'outside-only',url:'https://test/index.html',pretendToBeVisual:true});
const w=dom.window;w.setInterval=()=>1;w.matchMedia=()=>({matches:false});
let authCallback,owned=5,calls=0;
const client={auth:{onAuthStateChange(cb){authCallback=cb},async getSession(){return {data:{session:null},error:null}}},async rpc(name,args){
 let data;
 switch(name){
 case 'get_my_wallet':data={username:'ABLE',balance:0,is_admin:false};break;
 case 'get_member_stats_v3':data={hp:200,mp:200};break;
 case 'get_item_targets_v3':data=[{user_id:'a',username:'ABLE'},{user_id:'b',username:'대상'}];break;
 case 'get_my_inventory':data=[{item_id:'potion',item_name:'회복약',quantity:owned,acquisition_type:'구매'}];break;
 case 'use_shop_items_bulk_v1':
  calls++;assert.equal(args.p_quantity,3);assert.equal(args.p_target_user_id,'b');owned-=2;
  data={status:'used',target_name:'대상',used_quantity:2,unused_quantity:1,hp:200,mp:200,hp_restored:30,mp_restored:0};break;
 default:data=[];
 }
 return {data,error:null};
}};
installGuildFixture(w,client,html);w.supabase={createClient(){return client}};
for(const script of [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(x=>x[1]).filter(x=>x.trim()))w.eval(script);
const settle=()=>new Promise(resolve=>setTimeout(resolve,45));
await settle();authCallback('SIGNED_IN',{user:{id:'a',user_metadata:{display_name:'ABLE'}}});await settle();w.document.querySelector('[data-page="profile"]').click();await settle();
const target=()=>w.document.querySelector('[data-item-target]'),input=()=>w.document.querySelector('[data-use-quantity]'),button=()=>w.document.querySelector('[data-confirm-use]');
assert(input());assert.equal(input().max,'5');assert(button().disabled);
target().value='b';target().dispatchEvent(new w.Event('change'));input().value='3';input().dispatchEvent(new w.Event('input'));
assert(!button().disabled);assert(button().textContent.includes('3개'));
button().click();button().click();await settle();assert.equal(calls,1);
assert(w.document.querySelector('#profileStatus').textContent.includes('2개 사용 완료'));
assert(w.document.querySelector('#profileStatus').textContent.includes('나머지 1개'));
assert.equal(input().max,'3');assert.equal(input().value,'1');
target().value='b';target().dispatchEvent(new w.Event('change'));input().value='100';input().dispatchEvent(new w.Event('input'));assert(button().disabled);
w.document.querySelector('[data-cancel-use]').click();assert.equal(input().value,'1');assert.equal(target().value,'');assert(button().disabled);
dom.window.close();console.log('PASS: profile bulk quantity, selected target, single request, partial consumption receipt, new stock and cancel');
