/* UX-1 R5: local presentation fixtures only. No model, upload, account or task adapter. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id), phone=$('phone'), conversation=$('conversation');
  const icon=n=>`<svg aria-hidden="true"><use href="#${n}"/></svg>`;
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const originalMenu=$('titleMenu').onclick, originalAttachment=$('attach').onclick;
  const baseScene=document.querySelector('[data-study="conversation"]');
  let phase='done', replayTimers=[], replayStart=null, pauseRequested=false, style='标准', pinned=false, composing=false;
  let readEpoch=0, toastTimer, editorOpen=false;
  const attachmentDrafts=new Map(), pinnedThreads=new Set();let attachmentThread='周末去山里';
  function syncThreadExtras(){const name=currentName();if(name===attachmentThread)return;attachmentThread=name;renderAttachment(attachmentDrafts.get(name));pinned=pinnedThreads.has(name);setPhase('done');phone.classList.remove('replay-complete');updateComposer();}
  function note(t){clearTimeout(toastTimer);$('toast').textContent=t;$('toast').hidden=false;$('live').textContent=t;toastTimer=setTimeout(()=>{$('toast').hidden=true;},2800);}
  function keepDraft(value){$('draft').value=value;$('draft').dispatchEvent(new Event('input',{bubbles:true}));updateComposer();}
  function addToDraft(value){const current=$('draft').value;keepDraft(current.trim()?current+'\n\n'+value:value);}
  function currentName(){return $('titleMenu').querySelector('small').textContent.trim()||'当前对话';}
  function hasReply(){return !document.querySelector('.assistant-message').hidden&&(phase==='done'||!!$('streamBody').textContent.trim());}
  function capture(){const r=conversation.getBoundingClientRect();const node=Array.from(conversation.querySelectorAll('.lead,#readingBody p,#readingBody tr,#streamBody p,.intelligence,.artifact,.pending-card')).find(n=>n.getClientRects().length&&n.getBoundingClientRect().bottom>r.top+4);return {node,offset:node?node.getBoundingClientRect().top-r.top:0,epoch:readEpoch};}
  function restore(a){if(!a?.node?.isConnected||a.epoch!==readEpoch)return;conversation.scrollTop+=a.node.getBoundingClientRect().top-conversation.getBoundingClientRect().top-a.offset;}
  ['wheel','touchstart'].forEach(k=>conversation.addEventListener(k,()=>readEpoch++,{passive:true}));
  const originalProcess=$('processToggle').onclick;
  $('processToggle').onclick=()=>{const a=capture();originalProcess();const until=performance.now()+900;function follow(){restore(a);if(performance.now()<until&&a.epoch===readEpoch)requestAnimationFrame(follow);}requestAnimationFrame(follow);};
  function keyboard(value){$('keyboardStudy').checked=value;phone.classList.toggle('keyboard',value);$('keyboardPlaceholder').hidden=!value;updateComposer();}
  $('keyboardStudy').onchange=e=>{const a=capture();keyboard(e.target.checked);restore(a);};
  function updateComposer(){const active=document.activeElement===$('draft');phone.classList.toggle('composing',composing||active||!!$('draft').value||phone.classList.contains('keyboard')||phone.classList.contains('phase-active'));$('send').disabled=!$('draft').value.trim();if(phone.classList.contains('composing')){$('draft').style.height='auto';$('draft').style.height=Math.min(144,Math.max(44,$('draft').scrollHeight))+'px';}else $('draft').style.height='44px';}
  $('draft').addEventListener('input',updateComposer);$('draft').addEventListener('focus',updateComposer);$('draft').addEventListener('blur',()=>requestAnimationFrame(updateComposer));
  const stop=document.createElement('button');stop.id='stopReplay';stop.className='stop-replay';stop.textContent='停止';stop.setAttribute('aria-label','停止正文回放，不暂停工作');$('send').before(stop);
  stop.onclick=()=>{if(['processing','searching','writing'].includes(phase))setPhase('stopped');};
  function resetTimers(){replayTimers.forEach(clearTimeout);replayTimers=[];}
  function updateTrace(){
    const rows=Array.from($('processTrack').children).filter(e=>!e.classList.contains('process-actions'));
    const details={processing:['正在整理周末范围与时间偏好','等待整理要求','等待读取资料'],searching:['已整理：不赶时间、保留返程余量','正在读取2份资料样例','等待资料读取结果'],writing:['要求已整理','已读取2份资料样例','正在整理当前正文'],failed:['要求已保留','资料读取失败；没有新读取事实','未完成；保留已显示内容'],stopped:['要求已保留','已显示资料保留','仅停止正文回放；工作状态独立']};
    const texts=details[phase]||['要求已整理','已读取2份资料样例','本次正文已整理；没有写入或预订'];
    rows.forEach((r,i)=>{r.querySelector('strong').textContent=['整理要求','读取资料','整理回答'][i];r.querySelector('small').textContent=texts[i];});
  }
  function setPhase(next){phase=next;phone.dataset.phase=phase;const active=['processing','searching','writing'].includes(phase);phone.classList.toggle('phase-active',active||phase==='failed');phone.classList.toggle('replay-complete',['stream-done','stopped'].includes(phase));$('phaseIntro').textContent=phase==='failed'?'没有读到所需资料。已显示内容仍然保留，你可以稍后继续核对。':'我先对照路程和停留时间，再整理一个宽松的安排。';$('phaseIntro').hidden=!active&&!['stopped','failed'].includes(phase);$('streamBody').hidden=!['writing','stream-done','stopped','failed'].includes(phase);$('stopText').disabled=!active;$('stopText').textContent=phase==='stopped'?'回放已停止':'停止本地回放';$('draft').placeholder=active?'补充要求，先留在草稿…':'和 cat 一起做点事…';
    const titles={processing:'正在整理要求',searching:'正在查看 2 份资料样例',writing:'正在整理回答',done:'已整理 · 查看过程','stream-done':'正文已结束 · 查看过程',stopped:'正文回放已停止',failed:'资料读取失败 · 可查看已读内容'};
    stop.disabled=!active;$('processTitle').textContent=titles[phase]||titles.done;updateTrace();updateComposer();if(['stopped','failed','done'].includes(phase))resetTimers();
  }
  $('stopText').onclick=()=>{setPhase('stopped');note('仅停止本地正文回放；没有停止或取消真实工作。');};
  $('pauseWork').onclick=()=>{pauseRequested=true;$('pauseWork').disabled=true;$('pauseWork').textContent='暂停申请已记录';note('演示：正在等待暂停回执；申请不等于已经暂停。');};
  function streamChunk(text){const atBottom=conversation.scrollHeight-conversation.scrollTop-conversation.clientHeight<48,a=capture();let p=$('streamBody').lastElementChild;if(!p||text==='\n'){p=document.createElement('p');$('streamBody').append(p);}if(text!=='\n')p.append(document.createTextNode(text));if(atBottom)conversation.scrollTop=conversation.scrollHeight;else{restore(a);$('jumpLatest').hidden=false;}}
  function replay(){resetTimers();replayStart=performance.now();$('streamBody').replaceChildren();setPhase('processing');replayTimers.push(setTimeout(()=>setPhase('searching'),1100),setTimeout(()=>{setPhase('writing');const chunks=['我更推荐龙王山。','路上多花一点时间，','但周日上午能留出空闲。','\n','如果更在意路程，','也可以选择莫干山。','先确定方向，','再核实天气和开放情况。','\n','这次只整理了比较，','没有创建日程或预订。'];chunks.forEach((s,i)=>replayTimers.push(setTimeout(()=>{if(phase==='writing')streamChunk(s);if(i===chunks.length-1&&phase==='writing'){setPhase('stream-done');$('processTitle').textContent=`已整理 · 本地回放 ${((performance.now()-replayStart)/1000).toFixed(1)}s`;$('live').textContent='本地正文回放结束；工作状态独立。';}},i*260)));},2300));}
  function afterPopup(anchor,action){$('popoverShade').onclick();let frames=0;function settle(){if($('popover').hidden){anchor?.focus({preventScroll:true});action();}else if(++frames<180)requestAnimationFrame(settle);else note('请先关闭当前菜单。');}requestAnimationFrame(settle);}
  function menu(anchor,title,actions,noteText=''){originalMenu();const el=$('popover');el.setAttribute('aria-label',title);el.innerHTML=`<div class="menu-heading">${esc(title)}</div>`+actions.map((a,i)=>`<button data-reference-action="${i}" ${a.disabled?'disabled':''} ${a.danger?'class="destructive"':''}>${icon(a.icon||'document')}<span>${esc(a.label)}</span></button>`).join('')+(noteText?`<div class="menu-note">${esc(noteText)}</div>`:'');const r=anchor.getBoundingClientRect(),p=phone.getBoundingClientRect();const w=Math.min(250,phone.clientWidth-24);el.style.width=w+'px';const h=Math.min(el.scrollHeight,phone.clientHeight-116);let top=r.bottom-p.top-phone.clientTop+8;if(top+h>phone.clientHeight-28)top=Math.max(60,r.top-p.top-phone.clientTop-h-8);el.style.left=Math.max(12,Math.min(phone.clientWidth-w-12,r.right-p.left-phone.clientLeft-w))+'px';el.style.top=top+'px';el.style.transformOrigin=top<r.bottom-p.top?'bottom right':'top right';el.querySelectorAll('button').forEach(b=>b.onclick=()=>afterPopup(anchor,actions[Number(b.dataset.referenceAction)].run||(()=>{})));el.querySelector('button:not(:disabled)')?.focus({preventScroll:true});}
  function sheet(title,body,buttons=[],kind='info'){keyboard(false);originalAttachment();$('sheet').dataset.referenceKind=kind;editorOpen=kind==='editor';$('sheetBody').innerHTML=`<h1 id="sheetTitle">${esc(title)}</h1>${body}`;$('sheetFooter').innerHTML=buttons.map((b,i)=>`<button class="${i===0?'primary':'reference-secondary'}" data-reference-sheet="${i}">${esc(b.label)}</button>`).join('')+'<div class="home-indicator"></div>';$('sheetFooter').querySelectorAll('button').forEach(b=>b.onclick=()=>buttons[Number(b.dataset.referenceSheet)].run());$('closeSheet').setAttribute('aria-label','关闭，保留草稿');$('closeSheet').focus({preventScroll:true});}
  function closeSheet(){if(!$('sheet').hidden)$('closeSheet').onclick();}
  new MutationObserver(()=>{if($('sheet').hidden){editorOpen=false;delete $('sheet').dataset.referenceKind;}else keyboard(false);}).observe($('sheet'),{attributes:true,attributeFilter:['hidden']});
  function responseText(){if(!hasReply())return '';return [$('phaseIntro').hidden?'':$('phaseIntro').textContent,phone.classList.contains('replay-complete')||phase==='writing'||phase==='failed'?$('streamBody').innerText:document.querySelector('.lead').innerText+'\n\n'+$('readingBody').innerText].filter(Boolean).join('\n\n');}
  function copy(){navigator.clipboard.writeText(responseText()).then(()=>note(phase==='writing'?'已复制当前已显示部分。':'已复制当前样例回答。')).catch(()=>note('剪贴板不可用，可通过回答菜单选择文字。'));}
  $('copyReply').innerHTML=icon('document');$('copyReply').onclick=copy;
  $('feedbackReply').setAttribute('aria-pressed','false');$('feedbackReply').onclick=()=>{const yes=$('feedbackReply').getAttribute('aria-pressed')!=='true';$('feedbackReply').setAttribute('aria-pressed',yes);note(yes?'反馈已留在本地样机。':'已撤回本地反馈。');};
  function share(){sheet('分享这条回答',`<div class="reference-body"><p>预览将分享的正文；没有工作控制、个人权限或审批授权。</p><p>${esc(responseText())}</p></div>`,[{label:'复制分享文本',run:copy},{label:'返回',run:closeSheet}],'share');}
  $('shareReply').onclick=share;
  function sources(index){sheet('资料来源',`<p class="sheet-deck">2份资料样例 · 关联当前回答</p><div class="reference-body">${[0,1].map(i=>`<section class="source-row"><div><strong>${i===0?'路线比较资料':'行前条件清单'}</strong><small>人工来源样例 ${i+1} · v1 · 2026-10-13</small><p>${i===0?'支持路程与停留时间的比较。':'提醒出发前核实天气、开放与折返条件。'}</p><small>这是本地设计资料，不是已读取的外部网页。${i===index?' 当前选中':''}</small></div></section>`).join('')}</div>`,[{label:'返回回答',run:closeSheet}],'sources');}
  $('sourcesAction').onclick=()=>sources(-1);document.querySelectorAll('[data-source]').forEach(b=>b.onclick=()=>sources(Number(b.dataset.source)));
  function messageMenu(){menu($('messageMenu'),'这条回答 · 当前已显示内容',[
    {label:'复制回答',icon:'document',run:copy},
    {label:'选择文字',icon:'edit',run:()=>{window.getSelection()?.selectAllChildren(phone.classList.contains('replay-complete')?$('streamBody'):$('readingBody'));note('已选择当前回答正文。');}},
    {label:'引用到输入器',icon:'edit',run:()=>{keepDraft('关于这份周末比较，我想继续：\n'+$('draft').value);$('editContext').hidden=false;$('editContext').querySelector('span').textContent='引用：这条周末比较';$('draft').focus({preventScroll:true});}},
    {label:'在新对话继续',icon:'plus',run:()=>{$('newChat').onclick();keepDraft('参考这份周末比较，我想继续讨论：');note('新对话仅带入引用草稿；没有继承审批授权。');}},
    {label:'查看来源',icon:'search',run:()=>sources(-1)},
    {label:'重新回答',icon:'arrow',disabled:true}
  ],'重新回答是能力候选，未接重试端口。');}
  $('messageMenu').onclick=messageMenu;
  function find(){sheet('在当前对话查找','<label for="conversationFind">查找文字</label><input id="conversationFind" placeholder="输入关键词"><p class="boundary-note">只查当前已加载内容。</p><div id="findResults" class="reference-body"></div>',[{label:'返回原位置',run:closeSheet}],'find');$('conversationFind').oninput=e=>{const q=e.target.value.trim(),t=responseText();$('findResults').textContent=!q?'':t.includes(q)?`当前已加载正文包含“${q}”。`:'当前已加载内容没有匹配。';};}
  function files(){sheet('这段对话的附件',hasReply()?'<div class="reference-body"><p>周末安排.md</p><p class="boundary-note">本地附件样例，没有上传记录。</p></div>':'<div class="reference-body"><p>这段对话还没有附件。</p></div>',[{label:'返回',run:closeSheet}],'files');}
  function threadMenu(){menu($('conversationMenu'),currentName(),[
    {label:'分享当前回答',icon:'arrow',run:share,disabled:!hasReply()},
    {label:pinned?'取消置顶':'置顶',icon:'check',run:()=>{pinned=!pinned;if(pinned)pinnedThreads.add(currentName());else pinnedThreads.delete(currentName());note(pinned?'演示对话已置顶。':'已取消演示置顶。');}},
    {label:'加入空间',icon:'plus',disabled:true},
    {label:'查看附件',icon:'document',run:files},
    {label:'在对话中查找',icon:'search',run:find},
    {label:'归档',icon:'document',run:()=>sheet('归档这段对话？','<div class="reference-body"><p>归档后从最近列表移走，仍可以在归档里找回。草稿和工作记录不会因为归档而删除。</p><p>当前是操作预览，不修改任何真实数据。</p></div>',[{label:'返回，保留对话',run:closeSheet}],'archive')},
    {label:'删除',icon:'close',danger:true,run:()=>sheet('删除这段对话？',`<div class="reference-body"><p>请核对对象：${esc(currentName())}。正式产品需要说明删除范围、恢复能力与仍在执行的工作。</p><p>当前只是确认界面预览，没有删除动作。</p></div>`,[{label:'取消，保留对话',run:closeSheet}],'delete')}
  ]);}
  $('conversationMenu').onclick=threadMenu;$('titleMenu').onclick=threadMenu;
  function renderAttachment(type){const chip=$('attachmentChip');chip.hidden=!type;if(!type){chip.replaceChildren();return;}chip.innerHTML=`${icon('document')}<span>${type==='image'?'山间插图 · 图片样例':'周末安排.md · 文件样例'}</span><button aria-label="移除附件">×</button>`;chip.querySelector('button').onclick=()=>{attachmentDrafts.delete(currentName());renderAttachment();updateComposer();};}
  function chooseAttachment(type){attachmentDrafts.set(currentName(),type);renderAttachment(type);closeSheet();composing=true;updateComposer();note('仅加入本地附件样例，没有选择或上传设备文件。');}
  function tools(){sheet('想怎样开始？','<button id="researchTool" class="picker-row">'+icon('search')+'<span>整理公开资料<small>先明确主题与范围</small></span></button><button id="fileTool" class="picker-row">'+icon('document')+'<span>提炼文件重点<small>带入资料后再提交</small></span></button>',[{label:'返回',run:closeSheet}],'tools');$('researchTool').onclick=()=>{addToDraft('请帮我整理公开资料，主题是：');closeSheet();};$('fileTool').onclick=()=>{addToDraft('请帮我提炼这份文件的重点：');closeSheet();};}
  function attachments(){menu($('attach'),'添加内容',[
    {label:'拍照',icon:'document',disabled:true},
    {label:'照片样例',icon:'document',run:()=>chooseAttachment('image')},
    {label:'文件样例',icon:'document',run:()=>chooseAttachment('file')},
    {label:'工具',icon:'search',run:tools}
  ],'拍照为候选；样例不读取设备或上传。');}
  $('attach').onclick=attachments;
  $('answerStyle').onclick=()=>{sheet('回答方式',`<p class="sheet-deck">只设置当前草稿的表达偏好，不切换模型。</p>${['标准','简洁','详细'].map(x=>`<button class="picker-row" data-style="${x}">${esc(x)}${x===style?' · 当前':''}</button>`).join('')}`,[{label:'返回',run:closeSheet}],'style');$('sheetBody').querySelectorAll('[data-style]').forEach(b=>b.onclick=()=>{style=b.dataset.style;$('answerStyle').textContent=style;closeSheet();});};
  $('expandDraft').onclick=()=>{sheet('编辑消息',`<label for="fullDraft">消息内容</label><textarea class="editor" id="fullDraft">${esc($('draft').value)}</textarea><p class="boundary-note">关闭会保留草稿；返回后再明确发送。</p>`,[{label:'保留草稿，返回输入器',run:closeSheet}],'editor');$('fullDraft').oninput=e=>keepDraft(e.target.value);};
  const controls=document.createElement('div');controls.className='phase-controls';controls.innerHTML='<button data-phase="processing">处理</button><button data-phase="searching">搜索</button><button data-phase="writing">正文</button><button data-phase="done">完成</button><button data-phase="failed">失败</button><button id="playR5">连续回放</button><button id="pauseReceipt">暂停回执</button>';document.querySelector('.fixture-label').after(controls);
  controls.querySelectorAll('[data-phase]').forEach(b=>b.onclick=()=>{resetTimers();$('streamBody').replaceChildren();setPhase(b.dataset.phase);if(phase==='writing')streamChunk('当前正在整理正文。你可以继续写草稿，阅读位置不会被抢走。');});$('playR5').onclick=replay;$('pauseReceipt').onclick=()=>{if(!pauseRequested){note('先在处理过程里申请暂停。');return;}$('pauseWork').textContent='已暂停工作 · 人工回执';note('本地回放暂停确认；不代表后台工作已经暂停。');};
  function scene(name){resetTimers();keyboard(false);composing=false;baseScene.onclick();phone.classList.remove('intelligence-scene');phone.classList.add('reading');phone.classList.remove('replay-complete');$('streamBody').replaceChildren();setPhase('done');document.querySelectorAll('[data-reference]').forEach(b=>b.classList.toggle('selected',b.dataset.reference===name));const tip={reading:'正文 17 · 行高 1.6 · 段间 24；来源就近出现。',processing:'过程是一行摘要。展开看事件；停止正文与暂停工作分开。',input:'草稿、工具和主动作位置稳定；键盘是几何占位。',message:'这条回答的复制、引用和来源。',thread:'会话管理与回答操作各有入口。',attachments:'附件来自同一入口；设备权限在真实选择时按需申请。',intelligence:'沿同一阅读路径试算，明确继续才进入草稿。',approval:'核对动作、对象和范围；决定区始终可达。',drawer:'跟手与反向沿原R4机制；关闭保留草稿。',detail:'成果阅读沿原R4返回机制。'};$('stageTip').textContent=tip[name];$('noteTitle').textContent='让正文成为主角。';$('noteText').textContent=tip[name];
    if(name==='processing'){replay();conversation.scrollTop=0;}else if(name==='input'){composing=true;keepDraft('把周末的时间安排得更松一点。\n周日上午留空，返程不要太晚。');keyboard(true);$('draft').focus({preventScroll:true});}else if(name==='message'){conversation.scrollTop=conversation.scrollHeight;$('messageMenu').focus({preventScroll:true});messageMenu();}else if(name==='thread'){$('conversationMenu').focus({preventScroll:true});threadMenu();}else if(name==='attachments'){$('attach').focus({preventScroll:true});attachments();}else if(name==='intelligence'){phone.classList.remove('reading');phone.classList.add('intelligence-scene');conversation.scrollTop=0;}else if(['approval','drawer','detail'].includes(name)){if(name==='approval')phone.classList.remove('reading');document.querySelector(`[data-study="${name}"]`).onclick();}else conversation.scrollTop=0;
    updateComposer();
  }
  document.querySelectorAll('[data-reference]').forEach(b=>b.onclick=()=>scene(b.dataset.reference));
  ['newChat','drawerNew','exitEdit','continuePlan','reviseArtifact'].forEach(id=>$(id).addEventListener('click',()=>requestAnimationFrame(updateComposer)));
  document.querySelectorAll('[data-thread]').forEach(b=>b.addEventListener('click',()=>{setPhase('done');phone.classList.remove('replay-complete');requestAnimationFrame(updateComposer);}));
  new MutationObserver(syncThreadExtras).observe($('titleMenu').querySelector('small'),{childList:true,subtree:true});
  window.catpawMobileReferenceState=()=>({phase,pauseRequested,pinned,style,editorOpen,localOnly:true,modelRequests:0});
  scene('reading');
})();
