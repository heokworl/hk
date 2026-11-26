/* Shared raid UI. All combat decisions and permissions are enforced by database RPCs. */
(()=>{
  'use strict';
  let room=null;
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const clamp=(n,max)=>Math.max(0,Math.min(max,Number(n)||0));
  const statusNames={waiting:'공략 대기',active:'전투 진행',victory:'토벌 성공',defeat:'공략 실패'};
  const bossShape=`<svg viewBox="0 0 320 200" role="img" aria-label="어둠 속 잔류 균열체"><path class="boss-shadow" d="M70 175 42 125 77 111 62 40 112 79 142 35 160 16 178 35 208 79 258 40 243 111 278 125 250 175 210 185 160 174 110 185Z"/><path class="boss-armor" d="m78 113 34-30 48 19 48-19 34 30-35 53-47-13-47 13Z"/><path class="boss-eye" d="m105 112 39 10-18 11Zm110 0-39 10 18 11Z"/><path class="boss-mark" d="m150 139 10-15 10 15-10 15Z"/><path class="boss-cut" d="m160 18-5 52 12 16-11 20m-78 8 35 51m129-51-35 51"/></svg>`;
  function labelError(error){
    if(/PGRST202|42883|42P01/.test(error?.code||''))return '전투 DB 설정이 필요합니다. raid-battle-controls-items.sql을 먼저 실행해 주세요.';
    return error?.message||String(error||'알 수 없는 오류');
  }
  function valid(r){return room===r&&!r.closed}
  function shell(r){
    r.container.classList.add('shared-raid');
    r.container.innerHTML=`<div class="raid-topline"><span class="raid-sync" role="status">연결 확인 중…</span><button type="button" class="filter-button raid-refresh">새로고침</button></div><p class="raid-error" role="alert"></p><div class="raid-view"><div class="raid-combat-layout"><div class="raid-main-content"><div class="raid-placeholder">전투 상태를 불러오는 중…</div></div>${inventoryPanel(r,true)}</div></div>`;
    r.container.querySelector('.raid-refresh').addEventListener('click',()=>refresh(r,true));
  }
  function say(r,message){if(valid(r))r.container.querySelector('.raid-error').textContent=message}
  function syncLabel(r,message){if(valid(r))r.container.querySelector('.raid-sync').textContent=message}
  function memberCard(m,turn,state){
    const text=m.blocked?'참여 제한':m.hp<=0?'전투 불능':state==='waiting'?'대기 중':state!=='active'?'전투 종료':m.acted?'행동 완료':'행동 대기';
    return `<li class="raid-member${m.hp<=0?' is-down':''}"><div class="raid-member-name"><strong>${escape(m.username)}</strong><span>${text}</span></div><label>HP <span>${m.hp} / 200</span><progress class="raid-hp" value="${clamp(m.hp,200)}" max="200"></progress></label><label>MP <span>${m.mp} / 200</span><progress class="raid-mp" value="${clamp(m.mp,200)}" max="200"></progress></label></li>`;
  }
  function inventoryPanel(r,disabled){
    const items=r.state?.inventory||[],targets=r.inventoryReady?(r.state?.members||[]).filter(m=>!m.blocked&&m.can_target!==false):[];
    disabled=disabled||!r.inventoryReady;
    const problem=r.inventoryProblem||(!r.state?'전투 접근 권한 확인 후 사용할 수 있습니다.':'');
    return `<aside class="raid-inventory"><div class="raid-section-heading"><h3>아이템 인벤토리</h3></div><p class="raid-inventory-note">공격 또는 아이템 중 턴당 하나만 선택할 수 있습니다. 아이템 효과는 전원 행동 완료 후 적용됩니다.</p><p class="raid-inventory-status" role="status">${escape(problem)}</p><div class="raid-inventory-list">${items.length?items.map(item=>{
      const previous=r.selectedTargets.get(item.item_id)||'';
      const selected=targets.some(target=>target.user_id===previous)?previous:'';
      if(!selected)r.selectedTargets.delete(item.item_id);
      return `<article class="raid-inventory-item"><div class="raid-inventory-title"><strong>${escape(item.item_name)}</strong><span>× ${item.quantity}</span></div><p>${escape(item.description)}</p><small>사용 가능 ${item.quantity}개${item.reserved?' · 예약 '+item.reserved+'개':''}</small><label>사용 대상<select data-raid-target="${escape(item.item_id)}" ${disabled||item.quantity<1?'disabled':''}><option value="">대상 선택</option>${targets.map(target=>`<option value="${escape(target.user_id)}" ${selected===target.user_id?'selected':''}>${escape(target.username)} · HP ${target.hp}/200 · MP ${target.mp}/200</option>`).join('')}</select></label><button type="button" class="button" data-raid-use="${escape(item.item_id)}" ${disabled||item.quantity<1||!selected?'disabled':''}>아이템 사용 예약</button></article>`;
    }).join(''):'<p class="raid-inventory-empty">'+(problem?'인벤토리 연결 확인 중입니다.':'보유 아이템이 없습니다.')+'</p>'}</div></aside>`;
  }
  function renderLogs(r){
    const list=r.container.querySelector('.raid-log-list');if(!list)return;
    const nearBottom=list.scrollHeight-list.scrollTop-list.clientHeight<55;
    const previousHeight=list.scrollHeight,previousTop=list.scrollTop;
    const rows=[...r.logs.values()].sort((a,b)=>Number(a.id)-Number(b.id));
    list.innerHTML=rows.length?rows.map(l=>`<li class="raid-log-${escape(l.kind)}"><span class="raid-log-turn">${l.turn_no}턴</span><span>${escape(l.message)}</span></li>`).join(''):'<li>공략을 시작하면 전투 기록이 표시됩니다.</li>';
    if(r.loadingOlder)list.scrollTop=previousTop+(list.scrollHeight-previousHeight);else if(nearBottom||r.firstLogs)list.scrollTop=list.scrollHeight;
    r.firstLogs=false;
    const older=r.container.querySelector('.raid-older');older.disabled=r.loadingOlder||!r.hasOlder;
    older.textContent=r.loadingOlder?'이전 기록 불러오는 중…':r.hasOlder?'이전 전투 기록':'모든 기록을 불러왔습니다';
  }
  function render(r){
    const s=r.state;if(!s||!valid(r))return;
    const previousLog=r.container.querySelector('.raid-log-list');
    const savedTop=previousLog?.scrollTop,nearBottom=!previousLog||previousLog.scrollHeight-previousLog.scrollTop-previousLog.clientHeight<55;
    const eligible=s.members.filter(m=>!m.blocked&&m.hp>0),ready=eligible.filter(m=>m.acted).length;
    const me=s.members.find(m=>m.user_id===r.userId);
    const attackDisabled=r.busy||s.state!=='active'||!me||me.blocked||me.hp<=0||me.acted;
    let actionText=s.state==='waiting'?'시작하면 현재 참여 명단이 확정됩니다.':s.state==='victory'?'보스를 처치했습니다. 관리자 보상 지급을 기다려 주세요.':s.state==='defeat'?'공략이 종료되었습니다.':me?.hp<=0?'HP가 0이어서 이번 턴 행동 대상에서 제외됩니다.':me?.acted?'이번 턴 행동을 예약했습니다. 나머지 참여자의 행동을 기다리는 중입니다.':'공격 또는 오른쪽 인벤토리의 아이템 사용 중 하나를 예약하세요.';
    const key=JSON.stringify([s.state,s.turn_no,s.boss_hp,s.boss_max_hp,s.members,s.inventory,r.inventoryReady,r.inventoryProblem,r.busy,s.can_start]);
    if(key!==r.renderKey){
      r.renderKey=key;
      r.container.querySelector('.raid-view').innerHTML=`<div class="raid-combat-layout"><div class="raid-main-content"><section class="raid-boss raid-state-${escape(s.state)}"><div class="raid-boss-heading"><span class="raid-state-label">${statusNames[s.state]||'확인 중'}</span><span class="raid-turn">TURN ${s.turn_no}</span></div><div class="raid-boss-art">${bossShape}</div><h3>${escape(s.boss_name)}</h3><div class="raid-boss-health"><span>보스 HP</span><strong>${s.boss_hp.toLocaleString('ko-KR')} / ${s.boss_max_hp.toLocaleString('ko-KR')}</strong><progress class="raid-hp" max="${s.boss_max_hp}" value="${s.boss_hp}" aria-label="보스 HP"></progress></div></section><section class="raid-turn-panel"><div class="raid-section-heading"><h3>턴 행동</h3><span>${s.state==='active'?ready+' / '+eligible.length+'명 행동 완료':s.members.length+'명 참여'}</span></div><p class="raid-action-note">${actionText}</p><div class="raid-action-buttons">${s.state==='waiting'?`<button type="button" class="button raid-start" ${r.busy||!s.can_start||eligible.length===0?'disabled':''}>현재 명단으로 공략 시작</button>`:`<button type="button" class="button raid-attack" ${attackDisabled?'disabled':''}>${r.busy?'처리 중…':me?.acted?'이번 턴 행동 완료':'공격 예약 · 피해 '+s.player_damage}</button>`}</div><p class="raid-rules">턴당 공격 / 아이템 중 1회 · 전원 행동 후 효과 적용 · 보스 생존 시 각 참여자에게 ${s.boss_damage} 피해 · HP 0은 행동 제외</p><ul class="raid-members">${s.members.map(m=>memberCard(m,s.turn_no,s.state)).join('')}</ul></section><section class="raid-log-panel"><div class="raid-section-heading"><h3>전투 기록</h3><span>참여자 공통 로그</span></div><button class="filter-button raid-older" type="button">이전 전투 기록</button><ol class="raid-log-list" aria-label="전투 기록"></ol></section></div>${inventoryPanel(r,attackDisabled)}</div>`;
      r.container.querySelector('.raid-start')?.addEventListener('click',()=>act(r,'start'));
      r.container.querySelector('.raid-attack')?.addEventListener('click',()=>act(r,'attack'));
      r.container.querySelector('.raid-older').addEventListener('click',()=>older(r));
      r.container.querySelectorAll('[data-raid-target]').forEach(select=>select.addEventListener('change',()=>{
        r.selectedTargets.set(select.dataset.raidTarget,select.value);
        const button=select.closest('.raid-inventory-item').querySelector('[data-raid-use]');
        button.disabled=attackDisabled||!select.value;
      }));
      r.container.querySelectorAll('[data-raid-use]').forEach(button=>button.addEventListener('click',()=>act(r,'item',button.dataset.raidUse,r.selectedTargets.get(button.dataset.raidUse))));
      renderLogs(r);
      const nextLog=r.container.querySelector('.raid-log-list');
      if(!nearBottom&&savedTop!=null)nextLog.scrollTop=savedTop;else nextLog.scrollTop=nextLog.scrollHeight;
    }else renderLogs(r);
  }
  async function refresh(r,manual=false){
    if(!valid(r)||!r.visible||document.visibilityState==='hidden')return;
    if(r.fetching){r.refreshAgain=true;return r.fetching}
    r.fetching=(async()=>{
      try{
        const {data,error}=await r.client.rpc('raid_get_state_v1',{p_quest_id:r.questId});
        if(!valid(r))return;
        if(error)throw error;
        if(!data||data.quest_id!==r.questId||!Array.isArray(data.members))throw Error('전투 상태를 확인하지 못했습니다.');
        if(r.state&&Number(data.revision)<Number(r.state.revision))return;
        r.inventoryReady=Array.isArray(data.inventory);
        r.inventoryProblem='';
        if(!r.inventoryReady){
          const inventory=await r.client.rpc('get_my_inventory');
          if(!valid(r))return;
          data.inventory=inventory.error?[]:(inventory.data||[]);
          r.inventoryProblem=inventory.error?'인벤토리 조회 오류: '+inventory.error.message:'아이템이 보이지만 턴 사용 DB 연결이 완료되지 않았습니다. raid-battle-controls-items.sql 전체를 실행해 주세요.';
        }
        const hpChanged=r.state&&JSON.stringify(r.state.members.map(m=>[m.user_id,m.hp,m.mp]))!==JSON.stringify(data.members.map(m=>[m.user_id,m.hp,m.mp]));
        const incoming=data.logs||[];
        if(r.logs.size&&incoming.length&&!incoming.some(l=>r.logs.has(String(l.id)))&&Number(incoming[0].id)>Math.max(...[...r.logs.keys()].map(Number))){
          // A long disconnect may skip more than one page of logs. Reset the window
          // so the older-history button can retrieve the entire missing range.
          r.logs.clear();r.hasOlder=Boolean(data.has_older_logs);r.firstLogs=true;
        }
        r.state=data;
        for(const l of data.logs||[])r.logs.set(String(l.id),l);
        if(r.hasOlder===null)r.hasOlder=Boolean(data.has_older_logs);
        render(r);say(r,'');
        if(hpChanged)r.onVitalsChanged?.();
        if(!r.channel)subscribe(r);
      }catch(error){
        if(!valid(r))return;
        say(r,labelError(error));
        if(error.code==='42501'||error.code==='28000'){
          r.state=null;r.logs.clear();r.renderKey='';r.inventoryReady=false;r.inventoryProblem='전투 참여 권한이 없어 아이템을 사용할 수 없습니다.';
          r.container.querySelector('.raid-view').innerHTML='<div class="raid-combat-layout"><div class="raid-main-content"><div class="raid-placeholder">전투에 접근할 수 없습니다.</div></div>'+inventoryPanel(r,true)+'</div>';
          syncLabel(r,'접근 권한 없음');stopChannel(r);
        }
      }
    })();
    try{await r.fetching}finally{
      r.fetching=null;
      if(r.refreshAgain&&valid(r)){r.refreshAgain=false;queueMicrotask(()=>refresh(r))}
    }
  }
  async function act(r,type,itemId=null,targetId=null){
    if(!valid(r)||r.busy||!r.state)return;
    if(type==='item'&&!targetId){say(r,'사용 대상을 선택해 주세요.');return}
    const expectedTurn=r.state.turn_no;
    if(type==='start'&&!window.confirm('현재 참여 명단으로 공략을 시작할까요? 시작 후에는 새로 참여할 수 없습니다.'))return;
    r.busy=true;render(r);say(r,'');
    try{
      const {data,error}=await r.client.rpc(type==='start'?'raid_start_v1':'raid_submit_choice_v2',type==='start'?{p_quest_id:r.questId}:{p_quest_id:r.questId,p_turn_no:expectedTurn,p_action:type,p_item_id:itemId,p_target_user_id:targetId});
      if(!valid(r))return;
      if(error)throw error;
      await refresh(r);
      const message={already_acted:'이미 이번 턴에 행동했습니다.',stale_turn:'다음 턴으로 넘어가 최신 상태를 불러왔습니다.',incapacitated:'HP가 0이어서 행동할 수 없습니다.',not_active:'현재 전투가 진행 중이지 않습니다.',not_owned:'사용 가능한 아이템 수량이 없습니다.',already_full:'대상의 HP·MP가 가득 차 있어 행동과 아이템을 소모하지 않았습니다.'}[data];
      if(message)say(r,message);
      else if(!['submitted','started','already_started'].includes(data))say(r,'행동 처리 결과를 확인하지 못했습니다. 새로고침해 주세요.');
    }catch(error){say(r,labelError(error))}
    finally{if(valid(r)){r.busy=false;render(r);r.onVitalsChanged?.()}}
  }
  async function older(r){
    if(!valid(r)||r.loadingOlder||!r.hasOlder||!r.logs.size)return;
    const before=Math.min(...[...r.logs.keys()].map(Number));
    r.loadingOlder=true;renderLogs(r);
    try{
      const {data,error}=await r.client.rpc('raid_get_logs_v1',{p_quest_id:r.questId,p_before_id:before});
      if(!valid(r))return;if(error)throw error;
      for(const l of data||[])r.logs.set(String(l.id),l);
      r.hasOlder=(data||[]).length===100;
      renderLogs(r);
    }catch(error){say(r,labelError(error))}
    finally{if(valid(r)){r.loadingOlder=false;renderLogs(r)}}
  }
  function stopChannel(r){if(r.channel){const channel=r.channel;r.channel=null;r.client.removeChannel(channel)}}
  function subscribe(r){
    if(!valid(r)||!r.visible||r.channel)return;
    const channel=r.client.channel('raid-battle:'+r.questId+':'+r.userId);
    r.channel=channel;
    channel.on('postgres_changes',{event:'*',schema:'public',table:'raid_battles',filter:'quest_id=eq.'+r.questId},()=>refresh(r)).subscribe(status=>{
      if(!valid(r)||r.channel!==channel)return;
      if(status==='SUBSCRIBED'){syncLabel(r,'실시간 연결됨');refresh(r)}
      else if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status))syncLabel(r,'실시간 재연결 중 · 5초마다 상태 확인');
    });
  }
  function destroy(){
    const r=room;if(!r)return;r.closed=true;clearInterval(r.timer);stopChannel(r);r.logs.clear();r.container.replaceChildren();room=null;
  }
  async function open(config){
    if(room&&room.questId===config.questId&&room.userId===config.userId&&room.container===config.container){
      room.onVitalsChanged=config.onVitalsChanged;room.visible=true;return refresh(room);
    }
    destroy();
    const r={client:config.client,questId:config.questId,userId:config.userId,container:config.container,onVitalsChanged:config.onVitalsChanged,closed:false,visible:true,state:null,busy:false,fetching:null,refreshAgain:false,channel:null,logs:new Map(),hasOlder:null,loadingOlder:false,renderKey:'',firstLogs:true,inventoryReady:false,inventoryProblem:'',selectedTargets:new Map()};
    room=r;shell(r);
    r.timer=setInterval(()=>refresh(r),5000);
    return refresh(r);
  }
  document.addEventListener('visibilitychange',()=>{if(room&&document.visibilityState==='visible')refresh(room)});
  window.addEventListener('online',()=>{if(room)refresh(room)});
  window.addEventListener('focus',()=>{if(room)refresh(room)});
  window.addEventListener('pagehide',destroy);
  window.CheonhoRaid={open,destroy,suspend(){if(room){room.visible=false;stopChannel(room)}},resume(){if(room){room.visible=true;refresh(room)}}};
})();
