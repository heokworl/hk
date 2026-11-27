import {installGuildFixture} from './guild-ui-fixture.mjs';
import {JSDOM} from 'jsdom';import {readFileSync} from 'node:fs';import assert from 'node:assert/strict';
for(const file of ['index.html','raid.html'])for(const admin of [false,true]){
 const html=readFileSync(new URL('../'+file,import.meta.url),'utf8');
 const ids=[...html.matchAll(/(?:id:'|"id":")(test_raid_[a-z0-9_]+)/g)].map(m=>m[1]);assert(ids.includes('test_raid_solo_v2'));assert(ids.includes('test_raid_solo_v3'));
 const dom=new JSDOM(html,{runScripts:'outside-only',url:'https://test/'+file,pretendToBeVisual:true}),w=dom.window;w.setInterval=()=>1;w.matchMedia=()=>({matches:false});let callback;
 const client={auth:{onAuthStateChange(cb){callback=cb},async getSession(){return {data:{session:null},error:null}}},async rpc(name){let data=[];
 if(name==='get_my_wallet')data={username:admin?'관리자':'ABLE',balance:0,is_admin:admin};
 if(name==='get_member_stats_v3')data={hp:200,mp:200};
 if(name==='get_quest_status')data=ids.map(quest_id=>({quest_id,participant_count:0,has_joined:false,awarded:false}));
 if(name==='get_quest_details_v3')data=ids.map(quest_id=>({quest_id,category:'raid',participants:[],blocked:false,recruitment_closed:false,raid_entry_enabled:false}));
 return {data,error:null}}};installGuildFixture(w,client,html);w.supabase={createClient:()=>client};for(const m of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(m[1].trim())w.eval(m[1]);const settle=()=>new Promise(r=>setTimeout(r,70));await settle();callback('SIGNED_IN',{user:{id:admin?'admin':'user',user_metadata:{display_name:'회원'}}});await settle();
 assert(w.document.querySelector('#homeContent').textContent.includes('폐쇄 승강장 잔류체 토벌'));assert(w.document.querySelector('#homeContent').textContent.includes('지하 보관고 균열 봉쇄'));assert(w.document.querySelectorAll('.home-block:last-child .home-row').length>3);
 w.document.querySelector('[data-page="quests"]').click();assert(w.document.querySelector('[data-category="all"]').classList.contains('active'));
 for(const id of ['test_raid_solo_v2','test_raid_solo_v3']){const b=w.document.querySelector('[data-quest="'+id+'"]');assert(b);assert(!b.disabled);const card=b.closest('.quest-card');assert.equal(Boolean(card.querySelector('.quest-admin-gates')),admin);assert.equal(card.textContent.includes('관리자 관전'),admin);}
 w.document.querySelector('[data-category="daily"]').click();assert(!w.document.querySelector('[data-quest="test_raid_solo_v2"]'));w.document.querySelector('[data-category="raid"]').click();assert(w.document.querySelector('[data-quest="test_raid_solo_v2"]'));
 dom.window.close();
}
console.log('PASS: both pages show both new quests for regular users and admins; default all, full home raid list, enabled join, admin-only controls, category filters');
