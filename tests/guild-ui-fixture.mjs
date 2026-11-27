import {readFileSync} from 'node:fs';
// Supply the new endpoints for legacy tests; their original RPC mocks stay intact.
export function installGuildFixture(w,client,html){
 const list=Function('return '+html.match(/const quests=(\[[\s\S]*?\]);/)[1])();const original=client.rpc.bind(client);
 client.rpc=async(name,args)=>{
  if(name==='get_visible_quests_v1')return {data:list.map(q=>({quest_id:q.id})),error:null};
  if(name==='get_my_character_v1')return {data:{department:null,rank:null,title_id:null,portrait_path:null,version:0,titles:[]},error:null};
  if(name==='admin_get_grant_items_v1')return original('get_shop_items');
  if(name==='admin_get_used_items_for_member_v1'){const r=await original('admin_get_used_items');return {...r,data:(r.data||[]).filter(x=>x.user_id===args.p_user_id)}}
  return original(name,args);
 };
 if(w.HTMLDialogElement){w.HTMLDialogElement.prototype.close=function(){this.removeAttribute('open')};w.HTMLDialogElement.prototype.showModal=function(){this.setAttribute('open','')}}
 w.eval(readFileSync(new URL('../guild-character.js',import.meta.url),'utf8'));
}
