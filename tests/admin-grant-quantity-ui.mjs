import {JSDOM} from 'jsdom';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const html=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const dom=new JSDOM(html,{runScripts:'outside-only',url:'https://test/index.html',pretendToBeVisual:true});
const w=dom.window;w.setInterval=()=>1;w.confirm=()=>true;w.matchMedia=()=>({matches:false});
let authCallback,owned=2,calls=0;
const client={auth:{onAuthStateChange(cb){authCallback=cb},async getSession(){return {data:{session:null},error:null}}},async rpc(name,args){
 let data;
 switch(name){
 case 'get_my_wallet':data={username:'관리자',balance:0,is_admin:true};break;
 case 'admin_get_users':data=[{user_id:'admin',username:'관리자',balance:0}];break;
 case 'admin_get_member_status_v1':data=[{user_id:'admin',username:'관리자',hp:200,mp:200}];break;
 case 'get_member_stats_v3':data={hp:200,mp:200};break;
 case 'get_shop_items':data=[{item_id:'potion',item_name:'회복약',description:'HP 20',price_g:50,owned_quantity:owned}];break;
 case 'get_my_inventory':data=[{item_id:'potion',item_name:'회복약',quantity:owned,acquisition_type:'관리자 지급'}];break;
 case 'admin_grant_shop_items_v2':calls++;assert.equal(args.p_user_id,'admin');assert.equal(args.p_item_id,'potion');owned+=args.p_quantity;data={status:'granted',user_id:'admin',item_id:'potion',quantity:args.p_quantity,owned_quantity:owned};break;
 default:data=[];
 }
 return {data,error:null};
}};
w.supabase={createClient(){return client}};
for(const script of [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(x=>x[1]).filter(x=>x.trim()))w.eval(script);
const settle=()=>new Promise(resolve=>setTimeout(resolve,45));
await settle();authCallback('SIGNED_IN',{user:{id:'admin',user_metadata:{display_name:'관리자'}}});await settle();
w.document.querySelector('[data-page="admin"]').click();await settle();
w.document.querySelector('#adminUserSelect').value='admin';w.document.querySelector('#adminUserSelect').dispatchEvent(new w.Event('change'));
w.document.querySelector('#adminItemSelect').value='potion';
const quantity=w.document.querySelector('#adminItemQuantity'),button=w.document.querySelector('#adminItemButton');assert(quantity);
quantity.value='5';button.click();button.click();await settle();assert.equal(calls,1);assert.equal(owned,7);
assert(w.document.querySelector('#adminStatus').textContent.includes('5개를 추가 지급'));assert(w.document.querySelector('#adminStatus').textContent.includes('보유 7개'));
quantity.value='3';button.click();await settle();assert.equal(calls,2);assert.equal(owned,10);
quantity.value='0';button.click();await settle();assert.equal(calls,2);assert(w.document.querySelector('#adminStatus').textContent.includes('1~1,000'));
assert.equal(w.document.querySelectorAll('#adminItemQuantity').length,1);assert(!button.disabled);
dom.window.close();console.log('PASS: admin self-recipient, repeated quantity grants, accurate receipt, duplicate-click guard and invalid quantity');
