/* Account-owned character cards and administrator-only event grants. */
(()=>{'use strict';
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const departments={azure:'청룡 [던전공략부]',white:'백호 [구조의료부]',black:'현무 [지원보급부]'};
 const paths={star:'m16 3 4 8 9 1-7 7 2 10-8-5-8 5 2-10-7-7 9-1Z',target:'M16 3v6m0 14v6M3 16h6m14 0h6M16 7a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm0 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z',gate:'M7 28V13a9 9 0 0 1 18 0v15M3 28h26M12 28V15a4 4 0 0 1 8 0v13',cross:'m16 3 11 5v9c0 6-6 10-11 13C11 27 5 23 5 17V8ZM16 10v12m-6-6h12',moon:'M24 23A12 12 0 0 1 9 5a12 12 0 1 0 15 18ZM24 3v8m-4-4h8'};
 const emblem=kind=>'<svg viewBox="0 0 32 32" aria-hidden="true"><path d="'+(paths[kind]||paths.star)+'"/></svg>';
 function create(api){
  const {client,getUser,getAdmin}=api;let character=null,catalog=[],seq=0,loading=null,saving=false,eventBusy=false,eventRequest=null,previewURL=null,portraitFile=null,clearPortrait=false,editorVersion=0,editorOriginalPath=null,cropImage=null,cropSeq=0,cropPending=false,cropDrag=null;
  const $=id=>document.getElementById(id),dialog=$('characterEditor'),form=$('characterForm');
  function portraitURL(path){if(!path)return '';try{const url=client.storage.from('character-portraits').getPublicUrl(path).data.publicUrl;return new URL(url).protocol==='https:'?url:''}catch{return ''}}
  function cardMarkup(){
   const c=character||{},title=c.titles?.find(t=>t.id===c.title_id),url=portraitURL(c.portrait_path);
   return '<div class="hunter-card-main"><div class="hunter-portrait">'+(url?'<img src="'+esc(url)+'" alt="캐릭터 이미지" loading="lazy">':emblem('gate')+'<span>NO PORTRAIT</span>')+'</div><div class="hunter-card-info"><span class="hunter-card-label">REGISTERED HUNTER</span><h3 class="id-card-name">'+esc(api.getName())+'</h3><p class="hunter-department">'+esc(departments[c.department]||'소속 부서 미등록')+'</p><div class="hunter-designations"><span class="hunter-rank">'+esc(c.rank||'—')+'<small>등급</small></span>'+(title?'<span class="hunter-title" title="'+esc(title.description)+'">'+emblem(title.emblem)+'<span>'+esc(title.label)+'</span></span>':'<span class="hunter-no-title">칭호 미설정</span>')+'</div><button type="button" class="hunter-edit" data-character-edit>캐릭터 수정 ↗</button></div></div>';
  }
  function bindCards(){document.querySelectorAll('[data-character-edit]').forEach(b=>b.addEventListener('click',openEditor));document.querySelectorAll('.hunter-portrait img').forEach(img=>img.addEventListener('error',()=>{img.parentElement.innerHTML=emblem('gate')+'<span>이미지 확인 필요</span>'},{once:true}))}
  async function loadCharacter(){
   const uid=getUser()?.id;if(!uid)return;if(loading?.uid===uid)return loading.promise;
   const request=++seq;const promise=(async()=>{try{const {data,error}=await client.rpc('get_my_character_v1');if(request!==seq||getUser()?.id!==uid)return;if(error)throw error;character=data;api.onCharacterChanged();return data}catch(error){if(request===seq)$('characterStatus').textContent='캐릭터 조회 오류: '+error.message;return null}finally{if(loading?.request===request)loading=null}})();loading={uid,request,promise};return promise;
  }
  function closeEditor(){if(saving)return;if(dialog.close)dialog.close();else dialog.removeAttribute('open');resetCrop()}
  function revokePreview(){if(previewURL){URL.revokeObjectURL(previewURL);previewURL=null}}
  function paintPreview(){if(portraitFile&&cropImage){$('characterPortraitPreview').innerHTML='<canvas width="180" height="233" aria-label="크롭 미리보기"></canvas>';drawCrop($('characterPortraitPreview').firstChild);return}const path=portraitFile?previewURL:clearPortrait?'':portraitURL(character?.portrait_path);$('characterPortraitPreview').innerHTML=path?'<img src="'+esc(path)+'" alt="캐릭터 이미지 미리보기">':emblem('gate');}
  async function openEditor(){
   if(!getUser())return;const uid=getUser().id;await loadCharacter();if(getUser()?.id!==uid)return;
   if(!character){$('characterStatus').textContent='캐릭터 DB 설정을 확인해 주세요. character-events-update.sql 실행 후 다시 시도해 주세요.';return}
   form.reset();editorVersion=character.version||0;editorOriginalPath=character.portrait_path||null;resetCrop();clearPortrait=false;$('characterName').value=api.getName();$('characterDepartment').value=character.department||'';$('characterRank').value=character.rank||'';
   $('characterTitle').innerHTML='<option value="">칭호 없음</option>'+(character.titles||[]).map(t=>'<option value="'+esc(t.id)+'">'+esc(t.label)+'</option>').join('');$('characterTitle').value=character.title_id||'';paintPreview();$('characterEditorStatus').textContent='';
   if(dialog.showModal)dialog.showModal();else dialog.setAttribute('open','');
  }
  $('characterClose').addEventListener('click',closeEditor);dialog.addEventListener('cancel',e=>{if(saving)e.preventDefault();else resetCrop()});
  function resetCrop(){++cropSeq;cropPending=false;cropImage?.close();cropImage=null;cropDrag=null;portraitFile=null;revokePreview();$('characterCropPanel').hidden=true;for(const [id,value] of [['characterCropZoom',1],['characterCropX',50],['characterCropY',50]])$(id).value=value;}
  function cropRect(){const ratio=112/145,zoom=Number($('characterCropZoom').value)||1,w=Math.min(cropImage.width,cropImage.height*ratio)/zoom,h=w/ratio;return {x:(cropImage.width-w)*Number($('characterCropX').value)/100,y:(cropImage.height-h)*Number($('characterCropY').value)/100,w,h};}
  function drawCrop(canvas){if(!cropImage)return;const r=cropRect(),context=canvas.getContext('2d');context.clearRect(0,0,canvas.width,canvas.height);context.drawImage(cropImage,r.x,r.y,r.w,r.h,0,0,canvas.width,canvas.height);}
  function updateCrop(){if(!cropImage)return;drawCrop($('characterCropCanvas'));$('characterCropZoomValue').textContent=Number($('characterCropZoom').value).toFixed(2)+'×';paintPreview();}
  for(const id of ['characterCropZoom','characterCropX','characterCropY'])$(id).addEventListener('input',updateCrop);
  const cropCanvas=$('characterCropCanvas');cropCanvas.addEventListener('pointerdown',event=>{if(!cropImage||saving)return;cropDrag={x:event.clientX,y:event.clientY,px:Number($('characterCropX').value),py:Number($('characterCropY').value),rect:cropRect()};cropCanvas.setPointerCapture?.(event.pointerId);event.preventDefault()});
  cropCanvas.addEventListener('pointermove',event=>{if(!cropDrag||!cropImage||saving)return;const bounds=cropCanvas.getBoundingClientRect(),r=cropDrag.rect;if(!bounds.width||!bounds.height)return;const dx=(event.clientX-cropDrag.x)*r.w/bounds.width,dy=(event.clientY-cropDrag.y)*r.h/bounds.height;const clamp=n=>Math.round(Math.max(0,Math.min(100,n))*10)/10;$('characterCropX').value=clamp(cropDrag.px-(cropImage.width>r.w?dx/(cropImage.width-r.w)*100:0));$('characterCropY').value=clamp(cropDrag.py-(cropImage.height>r.h?dy/(cropImage.height-r.h)*100:0));updateCrop()});
  for(const event of ['pointerup','pointercancel','lostpointercapture'])cropCanvas.addEventListener(event,()=>{cropDrag=null});
  $('characterImage').addEventListener('change',async()=>{const file=$('characterImage').files?.[0];if(!file)return;resetCrop();if(!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size>10*1024*1024){$('characterEditorStatus').textContent='PNG·JPG·WebP 이미지, 최대 10MB까지 선택할 수 있습니다.';$('characterImage').value='';paintPreview();return}
   portraitFile=file;clearPortrait=false;previewURL=URL.createObjectURL(file);paintPreview();cropPending=true;const request=cropSeq,uid=getUser()?.id;$('characterEditorStatus').textContent='이미지를 불러오는 중…';
   try{const decoded=await createImageBitmap(file);if(request!==cropSeq||uid!==getUser()?.id){decoded.close();return}if(decoded.width>16384||decoded.height>16384||!decoded.width||!decoded.height){decoded.close();throw Error('이미지 가로·세로는 16,384px 이하로 선택해 주세요.')}cropImage=decoded;cropPending=false;$('characterCropPanel').hidden=false;updateCrop();$('characterEditorStatus').textContent='이미지를 드래그하거나 위치·확대 슬라이더를 조절하세요. 보이는 영역이 그대로 저장됩니다.';
   }catch(error){if(request===cropSeq){resetCrop();$('characterImage').value='';paintPreview();$('characterEditorStatus').textContent='이미지 오류: '+error.message}}
  });
  $('characterImageRemove').addEventListener('click',()=>{resetCrop();clearPortrait=true;$('characterImage').value='';paintPreview()});
  async function preparePortrait(){
   if(!cropImage)throw Error('이미지를 불러온 뒤 크롭 영역을 선택해 주세요.');const canvas=document.createElement('canvas');canvas.width=448;canvas.height=580;drawCrop(canvas);const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/webp',.9));if(!blob||blob.type!=='image/webp'||blob.size>2097152)throw Error('이미지를 저장할 수 없습니다. 다른 이미지를 선택해 주세요.');return blob;
  }
  form.addEventListener('submit',async e=>{
   e.preventDefault();if(saving||!getUser()||!character||!form.reportValidity())return;if(cropPending){$('characterEditorStatus').textContent='이미지를 불러오는 중입니다. 잠시 후 저장해 주세요.';return;}const uid=getUser().id;const values={p_name:$('characterName').value.trim(),p_department:$('characterDepartment').value,p_rank:$('characterRank').value,p_title_id:$('characterTitle').value||null,p_portrait_path:clearPortrait?null:editorOriginalPath,p_version:editorVersion};const old=editorOriginalPath;const file=portraitFile;let uploaded=null,committed=false,saveAttempted=false,definiteRejection=false;saving=true;form.querySelectorAll('input,select,button').forEach(el=>el.disabled=true);$('characterEditorStatus').textContent='저장하는 중…';
   try{
    if(file){const blob=await preparePortrait(file);if(getUser()?.id!==uid)return;uploaded=uid+'/'+crypto.randomUUID()+'.webp';const r=await client.storage.from('character-portraits').upload(uploaded,blob,{contentType:'image/webp',upsert:false});if(r.error)throw r.error;values.p_portrait_path=uploaded;}
    if(getUser()?.id!==uid)return;saveAttempted=true;const {data,error}=await client.rpc('save_my_character_v2',values);if(error){definiteRejection=['40001','42501','22023','23503','23505'].includes(error.code);throw error;}committed=true;if(getUser()?.id!==uid)return;character=data;if(api.onNameChanged)await api.onNameChanged(data.username);if(getUser()?.id!==uid)return;api.onCharacterChanged();$('characterStatus').textContent='캐릭터 정보를 저장했습니다.';if(dialog.close)dialog.close();else dialog.removeAttribute('open');resetCrop();
    if(old&&old!==values.p_portrait_path)client.storage.from('character-portraits').remove([old]).catch(()=>{});
   }catch(error){if(getUser()?.id===uid)$('characterEditorStatus').textContent='저장 오류: '+(error.code==='23505'?'이미 사용 중인 이름입니다. 다른 이름을 입력해 주세요.':error.code==='PGRST202'?'이름 변경 DB 설정이 필요합니다. character-name-crop.sql을 실행해 주세요.':error.message);}
   finally{if(uploaded&&!committed&&(!saveAttempted||definiteRejection))client.storage.from('character-portraits').remove([uploaded]).catch(()=>{});saving=false;form.querySelectorAll('input,select,button').forEach(el=>el.disabled=false);}
  });
  async function loadGrantCatalog(){const uid=getUser()?.id;if(!getAdmin()){catalog=[];return}const {data,error}=await client.rpc('admin_get_grant_items_v1');if(getUser()?.id!==uid||!getAdmin())return;if(error){$('eventItemStatus').textContent='지급 아이템 조회 오류: '+error.message;return}catalog=data||[];api.onGrantCatalogChanged()}
  function fillUsers(users){const select=$('eventRecipient'),old=select.value;select.innerHTML='<option value="">캐릭터 선택</option>'+users.map(u=>'<option value="'+esc(u.user_id)+'">'+esc(u.username)+'</option>').join('');if(users.some(u=>u.user_id===old))select.value=old;}
  const eventForm=$('eventItemForm');eventForm.addEventListener('input',()=>{eventRequest=null});eventForm.addEventListener('change',()=>{eventRequest=null});
  eventForm.addEventListener('submit',async e=>{
   e.preventDefault();if(eventBusy||!getAdmin()||!eventForm.reportValidity())return;
   const uid=getUser()?.id;eventBusy=true;eventRequest=eventRequest||crypto.randomUUID();const args={p_request_id:eventRequest,p_user_id:$('eventRecipient').value,p_name:$('eventItemName').value.trim(),p_description:$('eventItemDescription').value.trim(),p_quantity:Number($('eventItemQuantity').value),p_hp:Number($('eventItemHP').value),p_mp:Number($('eventItemMP').value)};
   eventForm.querySelectorAll('input,textarea,select,button').forEach(el=>el.disabled=true);$('eventItemStatus').textContent='이벤트 아이템 생성·지급 중…';
   try{const {data,error}=await client.rpc('admin_create_and_grant_event_v1',args);if(error)throw error;if(getUser()?.id!==uid||!getAdmin())return;if(data?.status!=='granted')throw Error('지급 결과를 확인하지 못했습니다.');eventRequest=null;eventForm.reset();$('eventItemStatus').textContent=data.item_name+' '+data.quantity+'개 지급 완료 · 상점에 표시되지 않습니다.';await Promise.all([loadGrantCatalog(),api.afterGrant()]);}
   catch(error){if(getUser()?.id===uid)$('eventItemStatus').textContent='이벤트 지급 오류: '+(error.code==='23505'?'같은 이름의 아이템이 있습니다. 기존 아이템 추가 지급 메뉴를 이용하거나 다른 이름을 입력해 주세요.':error.message);}
   finally{eventBusy=false;eventForm.querySelectorAll('input,textarea,select,button').forEach(el=>el.disabled=false)}
  });
  return {cardMarkup,bindCards,loadCharacter,loadGrantCatalog,fillUsers,grantItems:()=>catalog,openEditor,reset(){++seq;character=null;catalog=[];loading=null;eventRequest=null;resetCrop();if(dialog.close)dialog.close();else dialog.removeAttribute('open');form.reset();eventForm.reset();$('characterStatus').textContent='';$('characterEditorStatus').textContent='';$('eventItemStatus').textContent='';$('eventRecipient').innerHTML='<option value="">캐릭터 선택</option>';}};
 }
 window.CheonhoGuild={create};
})();
