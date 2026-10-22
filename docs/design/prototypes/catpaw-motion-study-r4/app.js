/* UX-1 R4: isolated presentation study. Every object and receipt is a local fixture. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const M = window.catMotion;
  const phone = $('phone'), root = $('root'), conversation = $('conversation');
  const clamp = (n, a, b) => Math.max(a, Math.min(b, n));
  const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const icon = name => `<svg aria-hidden="true"><use href="#${name}"/></svg>`;
  const reduced = () => $('reduced').checked || matchMedia('(prefers-reduced-motion: reduce)').matches;
  let drawerRest = 0, drawerBase = 0, detailRest = 0, detailBase = 0;
  let sheetRest = 350, sheetBase = 350, sheetKind = null, popupAnchor = null;
  let imageSource = null, imageStart = null, imageEnd = null, imageDragBase = 1, imageDragRest = 1;
  let currentThread = '周末去山里', currentDraft = '', editDraft = '', editMode = false;
  let approvalTitle = '周末去龙王山', approvalDraft = approvalTitle, approvalStatus = 'pending', approvalRevision = 1;
  let textStopped = false, textEnded = false, streamPlaying = false, workPaused = false, paragraphCount = 0, toastTimer, sheetTapSuppressedUntil = 0;
  let lastFocus = null, userScrollEpoch = 0;
  const threads = new Map([[currentThread,{draft:'',scroll:0}]]);
  const focusables = el => Array.from(el.querySelectorAll('button:not(:disabled),input,textarea,a[href],[tabindex="0"]')).filter(n => !n.hidden && n.getClientRects().length && !n.closest('[hidden]'));
  const height = () => phone.clientHeight, width = () => phone.clientWidth;
  const drawerWidth = () => $('drawer').getBoundingClientRect().width || Math.min(320, width() * .86);
  const largeY = () => 62;
  const mediumY = () => Math.round(height() * .43);
  function announce(t) { $('live').textContent = t; }
  function telemetry(t) { $('telemetry').textContent = t; }
  function toast(t) { clearTimeout(toastTimer); $('toast').textContent=t; $('toast').hidden=false; announce(t); toastTimer=setTimeout(()=>{$('toast').hidden=true;},2600); }
  function backgroundAccess() {
    const rootCovered = !$('drawer').hidden || !$('sheet').hidden || !$('popover').hidden || !$('zoom').hidden || !$('detail').hidden;
    root.inert=rootCovered;
    $('detail').inert=!$('sheet').hidden || !$('popover').hidden || !$('zoom').hidden;
  }
  function restoreFocus(fallback='openDrawer') {
    backgroundAccess();
    const valid=n=>n&&n.isConnected&&!n.closest('[hidden],[inert]')&&n.getClientRects().length;
    const candidate=valid(lastFocus)?lastFocus:valid($(fallback))?$(fallback):focusables(foreground())[0];
    candidate?.focus({preventScroll:true});
  }
  function rememberFocus() { if(document.activeElement && phone.contains(document.activeElement)) lastFocus=document.activeElement; }
  function foreground() {
    if(!$('zoom').hidden) return $('zoom');
    if(!$('popover').hidden) return $('popover');
    if(!$('sheet').hidden) return $('sheet');
    if(!$('drawer').hidden) return $('drawer');
    if(!$('detail').hidden) return $('detail');
    return root;
  }
  // One foreground owner. Explicit study navigation may replace a presentation;
  // normal open/close actions always redirect the same persistent spring.
  function dismissOther(except) {
    if(except!=='drawer') { drawerSpring.set(0); $('drawer').hidden=$('drawerShade').hidden=true; drawerRest=0; }
    if(except!=='sheet') { sheetSpring.set(height()); $('sheet').hidden=$('sheetShade').hidden=true; sheetKind=null; }
    if(except!=='popup') { popupSpring.set(0); $('popover').hidden=$('popoverShade').hidden=true; }
    if(except!=='zoom') { zoomSpring.set(0); $('zoom').hidden=true; if(imageSource) imageSource.style.opacity=''; imageSource=null; }
    backgroundAccess();
  }
  const drawerSpring=M.spring({initial:0,stiffness:440,damping:42,reducedMotion:reduced,onUpdate:x=>{
    $('drawer').dataset.position=x.toFixed(3);
    const w=drawerWidth(),p=clamp(x/w,0,1);
    $('drawer').style.transform=`translate3d(${x-w}px,0,0)`;
    $('drawerShade').style.opacity=.27*p;
    if($('detail').hidden) root.style.transform=`translate3d(${p*32}px,0,0)`;
    telemetry(`drawer x=${x.toFixed(1)} / ${w.toFixed(1)} · continuous`);
  },onSettle:x=>{
    $('drawer').dataset.motion='settled';
    if(x===0 && drawerSpring.target===0) { $('drawer').hidden=$('drawerShade').hidden=true; restoreFocus(); }
  }});
  function openDrawer() {
    if(!$('detail').hidden) return;
    rememberFocus(); dismissOther('drawer'); $('drawer').hidden=$('drawerShade').hidden=false;
    drawerRest=drawerWidth(); $('drawer').dataset.motion='moving';backgroundAccess(); drawerSpring.to(drawerRest); $('closeDrawer').focus({preventScroll:true});
  }
  function closeDrawer() { drawerRest=0;$('drawer').dataset.motion='moving';drawerSpring.to(0); }
  function drawerCanStart(e) {
    if(!$('detail').hidden || !$('sheet').hidden || !$('popover').hidden || !$('zoom').hidden) return false;
    if(e.target.closest('input,textarea,select,[contenteditable],input[type=range]')) return false;
    const edge=e.clientX-phone.getBoundingClientRect().left<=26;
    return !$('drawer').hidden || edge;
  }
  M.pan(phone,{axis:'x',shouldStart:drawerCanStart,onStart:()=>{
    rememberFocus(); $('drawer').hidden=$('drawerShade').hidden=false;
    drawerSpring.stop(); drawerBase=drawerSpring.value;$('drawer').dataset.motion='dragging';backgroundAccess();
  },onMove:g=>{
    const w=drawerWidth(),raw=drawerBase+g.dx;
    const x=raw<0?M.rubberBand(raw,w,.18):raw>w?w+M.rubberBand(raw-w,w,.18):raw;
    drawerSpring.set(x);
  },onEnd:g=>{ drawerRest=M.decideSnap(drawerSpring.value,clamp(g.vx,-1800,1800),[0,drawerWidth()],.18);$('drawer').dataset.motion='moving';drawerSpring.to(drawerRest,g.vx); },onCancel:()=>{$('drawer').dataset.motion='moving';drawerSpring.to(drawerRest);}});
  $('openDrawer').onclick=openDrawer; $('closeDrawer').onclick=closeDrawer; $('drawerShade').onclick=closeDrawer;
  const detailSpring=M.spring({initial:0,stiffness:430,damping:42,precision:.001,velocityPrecision:.01,reducedMotion:reduced,onUpdate:p=>{
    $('detail').dataset.progress=p.toFixed(5);
    p=clamp(p,0,1); $('detail').style.transform=`translate3d(${(1-p)*width()}px,0,0)`;
    root.style.transform=`translate3d(${-p*width()*.23}px,0,0)`;
  },onSettle:p=>{$('detail').dataset.motion='settled';if(p===0 && detailSpring.target===0) { $('detail').hidden=true;root.style.transform='';restoreFocus('openDetail');} }});
  function openDetail() {
    rememberFocus(); dismissOther('detail'); $('detail').hidden=false;detailRest=1;$('detail').dataset.motion='moving';backgroundAccess();detailSpring.to(1);$('backDetail').focus({preventScroll:true});
  }
  function closeDetail() { detailRest=0;$('detail').dataset.motion='moving';detailSpring.to(0); }
  M.pan($('detail'),{axis:'x',shouldStart:e=>e.clientX-phone.getBoundingClientRect().left<=28 && !e.target.closest('input,textarea,button') && $('sheet').hidden && $('zoom').hidden && $('popover').hidden,onStart:()=>{detailSpring.stop();detailBase=detailSpring.value;$('detail').dataset.motion='dragging';},onMove:g=>{detailSpring.set(clamp(detailBase-g.dx/width(),0,1));},onEnd:g=>{
    const x=(1-detailSpring.value)*width(); const dest=M.decideSnap(x,clamp(g.vx,-1800,1800),[0,width()],.18);
    detailRest=dest===width()?0:1;$('detail').dataset.motion='moving';detailSpring.to(detailRest,-g.vx/width());
  },onCancel:()=>{$('detail').dataset.motion='moving';detailSpring.to(detailRest);}});
  $('openDetail').onclick=openDetail; $('backDetail').onclick=closeDetail;
  const sheetSpring=M.spring({initial:844,stiffness:440,damping:43,reducedMotion:reduced,onUpdate:y=>{
    $('sheet').dataset.position=y.toFixed(3);
    const top=clamp(y,largeY()-12,height()); $('sheet').style.top=top+'px';$('sheet').style.height=Math.max(0,height()-top)+'px';
    $('sheetShade').style.opacity=.32*clamp((height()-y)/(height()-mediumY()),0,1);
    telemetry(`sheet top=${top.toFixed(1)} · target=${sheetSpring?.target?.toFixed(1) ?? '—'}`);
  },onSettle:y=>{$('sheet').dataset.motion='settled';if(y===height()&&sheetSpring.target===height()){$('sheet').hidden=$('sheetShade').hidden=true;sheetKind=null;restoreFocus('openApproval');}}});
  function openSheet(kind='approval', detent) {
    const wasHidden=$('sheet').hidden;
    if(wasHidden) rememberFocus();
    dismissOther('sheet');sheetKind=kind;renderSheet();
    $('sheet').hidden=$('sheetShade').hidden=false; backgroundAccess();
    if(wasHidden) sheetSpring.set(height());
    sheetRest=detent ?? (kind==='approval'&&!$('largeText').checked?mediumY():largeY());
    $('sheet').dataset.motion='moving';sheetSpring.to(sheetRest);$('closeSheet').focus({preventScroll:true});
  }
  function closeSheet() { if(sheetKind==='edit') approvalDraft=$('eventTitle')?.value ?? approvalDraft;sheetRest=height();$('sheet').dataset.motion='moving';sheetSpring.to(sheetRest); }
  M.pan($('sheetHandle'),{axis:'y',shouldStart:e=>!e.target.closest('button'),onStart:()=>{sheetSpring.stop();sheetBase=sheetSpring.value;$('sheet').dataset.motion='dragging';},onMove:g=>{
    const raw=sheetBase+g.dy, y=raw<largeY()?largeY()+M.rubberBand(raw-largeY(),height(),.2):raw;
    sheetSpring.set(y);
  },onEnd:g=>{
    sheetTapSuppressedUntil=performance.now()+250;
    const options=sheetKind==='edit'||$('largeText').checked?[largeY(),height()]:[largeY(),mediumY(),height()];
    sheetRest=M.decideSnap(sheetSpring.value,clamp(g.vy,-1700,1700),options,.14);$('sheet').dataset.motion='moving';sheetSpring.to(sheetRest,g.vy);
  },onCancel:()=>{$('sheet').dataset.motion='moving';sheetSpring.to(sheetRest);}});
  $('closeSheet').onclick=closeSheet; $('sheetShade').onclick=closeSheet;
  function toggleDetent(){sheetRest=sheetSpring.target===largeY()&&!$('largeText').checked&&sheetKind==='approval'?mediumY():largeY();$('sheet').dataset.motion='moving';sheetSpring.to(sheetRest);announce(sheetRest===largeY()?'面板已展开':'面板已收至中档');}
  $('sheetDetent').addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();toggleDetent();}});
  $('sheetDetent').onclick=()=>{if(performance.now()>sheetTapSuppressedUntil)toggleDetent();};
  $('openApproval').onclick=()=>openSheet('approval');
  function renderSheet() {
    let body='',footer='';
    if(sheetKind==='approval') {
      const resolved=approvalStatus!=='pending';
      body=`<p class="approval-kicker">${icon('calendar')}需要你的确认</p><h1 id="sheetTitle">把出发时间<br>记到日历里？</h1><p class="sheet-deck">只创建下面这一项。看清楚，再决定。</p><div class="event-preview"><strong>${esc(approvalTitle)}</strong><p class="event-time">10月17日，周六 · 08:30—09:00</p><p>个人日历 · 提前30分钟提醒</p></div><dl class="approval-fields"><div><dt>处理方</dt><dd>本机日历</dd></div><div><dt>影响</dt><dd>新增1个事件<br>不预订、不通知其他人</dd></div><div><dt>对象版本</dt><dd>v${approvalRevision} · 当前内容</dd></div></dl><p class="boundary-note">关闭或稍后处理会保留这项确认。你也可以修改内容，重新核对之后再确认。</p><p class="boundary-note">当前是人工演示。这里不会申请日历权限，也不会创建真实事件。</p>`;
      footer=`<button id="confirmEvent" class="primary" ${resolved?'disabled':''}>${icon('calendar')}${resolved?(approvalStatus==='declined'?'已拒绝这项演示':'演示回执已记录'):'确认创建这项日程'}</button><div class="sheet-secondary"><button id="editEvent" ${resolved?'disabled':''}>修改</button><button id="laterEvent">${resolved?'关闭':'稍后'}</button><button id="rejectEvent" ${resolved?'disabled':''}>拒绝</button></div><div class="home-indicator"></div>`;
    } else if(sheetKind==='edit') {
      body=`<p class="approval-kicker">修改确认内容</p><h1 id="sheetTitle">按你的想法来。</h1><p class="sheet-deck">修改会形成新版本，返回后重新核对。</p><label for="eventTitle">日程标题</label><input id="eventTitle" value="${esc(approvalDraft)}" maxlength="80"><p id="sheetError" class="sheet-error"></p><div class="event-preview"><strong>时间与提醒</strong><p>10月17日 · 08:30—09:00<br>个人日历 · 提前30分钟提醒</p></div><p class="boundary-note">关闭后保留未提交的标题草稿；不会创建日程。</p>`;
      footer=`<button id="saveEvent" class="primary">保存修改，返回核对</button><div class="sheet-secondary"><button id="editBack">返回核对</button><button id="editLater">稍后继续</button></div><div class="home-indicator"></div>`;
    } else if(sheetKind==='queue') {
      body=`<p class="approval-kicker">本地待发</p><h1 id="sheetTitle">先把想法留住。</h1><p class="sheet-deck">样机没有发送服务。这段文字保存在当前页面里。</p><label for="queuedText">待发内容</label><textarea id="queuedText">${esc($('draft').value)}</textarea><p class="boundary-note">刷新会重置。产品版接入既有草稿与队列服务，不能把本地保存显示成已发送。</p>`;
      footer=`<button id="saveQueue" class="primary">保存到草稿</button><div class="sheet-secondary"><button id="queueBack">返回对话</button></div><div class="home-indicator"></div>`;
    } else {
      body=`<p class="approval-kicker">你的空间</p><h1 id="sheetTitle">${sheetKind==='attachments'?'用顺手的方式表达。':'偏好与记忆'}</h1><p class="sheet-deck">${sheetKind==='attachments'?'原生版使用系统照片／文件选择器，保留附件身份和草稿。此设计样机没有接入选择器。':'这次试算只作用于当前安排。保存偏好需要明确动作，来源和删除入口可随时找回。'}</p><p class="boundary-note">这里只呈现入口层级；不会读取设备文件或改变记忆。</p>`;
      footer=`<button id="infoBack" class="primary">返回</button><div class="home-indicator"></div>`;
    }
    $('sheetBody').innerHTML=body; $('sheetFooter').innerHTML=footer;
    $('sheetBody').scrollTop=0;
    $('confirmEvent')?.addEventListener('click',()=>{
      if(approvalStatus!=='pending') return; approvalStatus='synthetic-receipt';renderSheet();updatePending();$('closeSheet').focus({preventScroll:true});toast('人工回放：演示回执已记录，未创建真实日程');
    });
    $('editEvent')?.addEventListener('click',()=>openSheet('edit',largeY()));
    $('laterEvent')?.addEventListener('click',closeSheet);
    $('rejectEvent')?.addEventListener('click',()=>{if(approvalStatus==='pending'){approvalStatus='declined';updatePending();closeSheet();toast('这项演示已拒绝；关闭与拒绝分别记录');}});
    $('eventTitle')?.addEventListener('input',e=>{approvalDraft=e.target.value;$('sheetError').textContent='';});
    $('saveEvent')?.addEventListener('click',()=>{
      const title=$('eventTitle').value.trim();if(!title){$('sheetError').textContent='给这项日程一个标题。';$('eventTitle').focus();return;}
      approvalDraft=approvalTitle=title;approvalRevision++;approvalStatus='pending';updatePending();openSheet('approval',largeY());announce('已保存演示新版本，待重新确认');
    });
    $('editBack')?.addEventListener('click',()=>{approvalDraft=$('eventTitle').value;openSheet('approval',largeY());});
    $('editLater')?.addEventListener('click',closeSheet);
    $('saveQueue')?.addEventListener('click',()=>{$('draft').value=$('queuedText').value;saveDraft();closeSheet();toast('已留在本地草稿，尚未发送');});
    $('queueBack')?.addEventListener('click',closeSheet);$('infoBack')?.addEventListener('click',closeSheet);
  }
  function updatePending() {
    $('pendingCard').querySelector('h3').textContent=approvalStatus==='pending'?'把出发时间记下来？':approvalStatus==='declined'?'这项确认已拒绝':'演示回执已记录';
    $('pendingCard').querySelector('span').textContent=approvalStatus==='pending'?'需要你确认':'人工演示状态';
    $('openApproval').innerHTML=`${approvalStatus==='pending'?'查看并确认':'查看原决定'} ${icon('chevron')}`;
    $('drawerPending').lastElementChild.textContent=approvalStatus==='pending'?'1':'0';$('drawerPending').hidden=approvalStatus!=='pending';
  }
  const popupSpring=M.spring({initial:0,stiffness:600,damping:48,precision:.001,velocityPrecision:.01,reducedMotion:reduced,onUpdate:p=>{
    $('popover').dataset.progress=p.toFixed(5);
    $('popover').style.opacity=clamp(p,0,1);$('popover').style.transform=`scale(${.94+.06*p}) translateY(${(1-p)*-5}px)`;
    $('popoverShade').style.opacity=clamp(p,0,1);
  },onSettle:p=>{if(p===0&&popupSpring.target===0){$('popover').hidden=$('popoverShade').hidden=true;restoreFocus();}}});
  function openPopup(anchor,kind='artifact') {
    rememberFocus();dismissOther('popup');popupAnchor=anchor;$('popover').hidden=$('popoverShade').hidden=false;
    const actions=kind==='conversation'?['查看当前工作','打开侧栏','新对话']:kind==='intelligence'?['查看数据口径','按当前偏好继续','重置偏好']:['继续修改','查看确认事项','复制内容'];
    $('popover').innerHTML=actions.map((a,i)=>`<button data-menu-action="${i}">${a}${icon(i===0?'edit':i===1?'document':'more')}</button>`).join('');
    const rect=anchor.getBoundingClientRect(),pr=phone.getBoundingClientRect();
    const left=clamp(rect.right-pr.left-phone.clientLeft-220,12,width()-232);
    const below=rect.bottom-pr.top-phone.clientTop+8; const menuH=156;
    const top=below+menuH<height()-25?below:Math.max(52,rect.top-pr.top-phone.clientTop-menuH-8);
    $('popover').style.left=left+'px';$('popover').style.top=top+'px';
    $('popover').style.transformOrigin=`${clamp(rect.left-pr.left-left,20,200)}px ${top<below?'bottom':'top'}`;
    backgroundAccess();popupSpring.to(1);focusables($('popover'))[0]?.focus({preventScroll:true});
    $('popover').querySelectorAll('button').forEach(b=>b.onclick=()=>{
      const n=Number(b.dataset.menuAction);closePopup(true);
      if(kind==='conversation'){ if(n===0)openDetail();else if(n===1)openDrawer();else newConversation(); }
      else if(kind==='intelligence'){if(n===0)toast('人工口径：安静与路程按同一权重线性组合，偏好分/100');else if(n===1)continueWithPreference();else setWeight(70);}
      else {if(n===0)revise();else if(n===1)openSheet('approval');else {const text=$('detailScroll').innerText;navigator.clipboard.writeText(text).then(()=>toast('已复制当前人工内容与说明')).catch(()=>toast('无法访问剪贴板；可在成果详情选择正文复制'));}}
    });
  }
  function closePopup(immediate=false) { if(immediate){popupSpring.set(0);$('popover').hidden=$('popoverShade').hidden=true;backgroundAccess();}else popupSpring.to(0); }
  $('popoverShade').onclick=()=>closePopup();$('titleMenu').onclick=()=>openPopup($('titleMenu'),'conversation');$('cardMenu').onclick=()=>openPopup($('cardMenu'),'intelligence');$('detailMenu').onclick=()=>openPopup($('detailMenu'));
  let longPressTimer, longPressOrigin, suppressArtifactClick=false;
  $('artifactCard').addEventListener('pointerdown',e=>{if(e.button!==0)return;longPressOrigin=[e.clientX,e.clientY];suppressArtifactClick=false;longPressTimer=setTimeout(()=>{suppressArtifactClick=true;openPopup($('artifactCard'));},550);});
  $('artifactCard').addEventListener('pointermove',e=>{if(longPressOrigin&&Math.hypot(e.clientX-longPressOrigin[0],e.clientY-longPressOrigin[1])>8)clearTimeout(longPressTimer);});
  ['pointerup','pointercancel','pointerleave'].forEach(k=>$('artifactCard').addEventListener(k,()=>{clearTimeout(longPressTimer);if(suppressArtifactClick)setTimeout(()=>{suppressArtifactClick=false;},400);}));
  $('artifactCard').addEventListener('click',e=>{if(suppressArtifactClick){e.preventDefault();e.stopImmediatePropagation();}},true);
  $('artifactCard').addEventListener('contextmenu',e=>{e.preventDefault();openPopup($('artifactCard'));});
  function localRect(el) {const r=el.getBoundingClientRect(),p=phone.getBoundingClientRect();return{x:r.left-p.left-phone.clientLeft,y:r.top-p.top-phone.clientTop,w:r.width,h:r.height,radius:el===$('detailImage')?0:20};}
  const zoomSpring=M.spring({initial:0,stiffness:410,damping:40,precision:.001,velocityPrecision:.01,reducedMotion:reduced,onUpdate:p=>{
    $('zoom').dataset.progress=p.toFixed(5);
    if(!imageStart||!imageEnd) return;
    const t=clamp(p,0,1), geometry=reduced()?1:t, mix=(a,b)=>a+(b-a)*geometry, img=$('zoomImage');img.style.opacity=reduced()?t:1;
    img.style.left=mix(imageStart.x,imageEnd.x)+'px';img.style.top=mix(imageStart.y,imageEnd.y)+'px';img.style.width=mix(imageStart.w,imageEnd.w)+'px';img.style.height=mix(imageStart.h,imageEnd.h)+'px';img.style.borderRadius=mix(imageStart.radius,0)+'px';
    $('zoomBg').style.opacity=t; $('closeZoom').style.opacity=t; $('zoom').querySelector('p').style.opacity=t;
  },onSettle:p=>{$('zoom').dataset.motion='settled';if(p===0&&zoomSpring.target===0){$('zoom').hidden=true;if(imageSource)imageSource.style.opacity='';imageSource=null;restoreFocus('imageThumb');}}});
  function openImage(source) {
    if(!source) return;rememberFocus();dismissOther('zoom');imageSource=source;imageStart=localRect(source);
    const w=width(),h=w*2/3;imageEnd={x:0,y:(height()-h)/2,w,h,radius:0};
    $('zoomImage').src=source.querySelector('img').src;$('zoom').hidden=false;source.style.opacity=0;$('zoom').dataset.motion='moving';backgroundAccess();zoomSpring.to(1);$('closeZoom').focus({preventScroll:true});
  }
  function closeImage(velocity) {if(imageSource?.getClientRects().length)imageStart=localRect(imageSource);$('zoom').dataset.motion='moving';zoomSpring.to(0,typeof velocity==='number'?velocity:undefined);}
  M.pan($('zoom'),{axis:'y',shouldStart:e=>!e.target.closest('button'),onStart:()=>{imageDragRest=zoomSpring.target;zoomSpring.stop();imageDragBase=zoomSpring.value;$('zoom').dataset.motion='dragging';},onMove:g=>{zoomSpring.set(clamp(imageDragBase-g.dy/height(),0,1));},onEnd:g=>{
    const projected=zoomSpring.value-clamp(g.vy,-1600,1600)*.15/height();
    const reversingUp=g.dy < -20 && g.vy<=0;
    const dismiss=!reversingUp && projected<.8;
    if(dismiss)closeImage(-g.vy/height());else{$('zoom').dataset.motion='moving';zoomSpring.to(1,-g.vy/height());}
  },onCancel:()=>{$('zoom').dataset.motion='moving';zoomSpring.to(imageDragRest);}});
  $('imageThumb').onclick=()=>openImage($('imageThumb'));$('detailImage').onclick=()=>openImage($('detailImage'));$('closeZoom').onclick=closeImage;
  function captureAnchor() {
    const rect=conversation.getBoundingClientRect();
    const nodes=conversation.querySelectorAll('.user-message,.process-summary,.lead,.answer,.intelligence,.result-head,.artifact,.pending-card,.stream-paragraph');
    const candidates=Array.from(nodes).filter(n=>n.getBoundingClientRect().bottom>rect.top+4);
    const node=candidates[0];return{node,offset:node?node.getBoundingClientRect().top-rect.top:0,epoch:userScrollEpoch};
  }
  function restoreAnchor(a) {if(!a?.node?.isConnected||a.epoch!==userScrollEpoch)return;const delta=a.node.getBoundingClientRect().top-conversation.getBoundingClientRect().top-a.offset;conversation.scrollTop+=delta;}
  let processAnchor,processExpanded=false;
  const processSpring=M.spring({initial:0,stiffness:550,damping:47,reducedMotion:reduced,onUpdate:h=>{$('processTrack').style.height=Math.max(0,h)+'px';restoreAnchor(processAnchor);},onSettle:h=>{if(h===0&&!processExpanded)$('processTrack').hidden=true;}});
  $('processToggle').onclick=()=>{
    processAnchor=captureAnchor();processExpanded=!processExpanded;$('processToggle').setAttribute('aria-expanded',processExpanded);
    $('processTrack').hidden=false;const old=$('processTrack').style.height;$('processTrack').style.height='auto';const natural=$('processTrack').getBoundingClientRect().height;$('processTrack').style.height=old;
    processSpring.to(processExpanded?natural:0);announce(processExpanded?'过程已展开':'过程已收起');
  };
  function updateProcessTitle(){const text=textStopped?'正文已停止':streamPlaying?'正在补充行前清单':textEnded?'正文流已结束':'已整理两种安排';$('processTitle').textContent=workPaused?`工作已暂停 · ${text}`:text;}
  $('stopText').onclick=()=>{textStopped=true;streamPlaying=false;$('stopText').disabled=true;$('stopText').textContent='正文已停止';updateProcessTitle();toast('停止正文不等于取消工作');};
  $('pauseWork').onclick=()=>{workPaused=!workPaused;$('pauseWork').textContent=workPaused?'恢复工作':'暂停工作';updateProcessTitle();toast(workPaused?'人工回放：工作在安全点暂停':'人工回放：工作恢复');};
  let followBottom=false;
  ['wheel','touchstart','pointerdown'].forEach(e=>conversation.addEventListener(e,()=>{userScrollEpoch++;}, {passive:true}));
  conversation.addEventListener('scroll',()=>{
    followBottom=conversation.scrollHeight-conversation.scrollTop-conversation.clientHeight<48;
    if(followBottom)$('jumpLatest').hidden=true;
  },{passive:true});
  function appendParagraph(){
    if(textStopped){toast('正文已经停止。重置样机可重新回放。');return;}
    const atBottom=conversation.scrollHeight-conversation.scrollTop-conversation.clientHeight<48,a=captureAnchor();
    const p=document.createElement('p');p.className='stream-paragraph';paragraphCount++;
    p.textContent=`${paragraphCount===1?'再留一点余量：如果天气不适合，就把步道改成附近散步。':paragraphCount===2?'你选好之后，我会把同一份安排里的时间和清单一起更新。':'已补充一段人工正文，用来检查新增内容时的阅读位置。'} 这里的正文回放不会发起请求。`;
    $('streamTail').append(p);if(atBottom)conversation.scrollTop=conversation.scrollHeight;else{restoreAnchor(a);$('jumpLatest').hidden=false;}
    announce('增加了一段人工正文');
  }
  $('appendStream').onclick=appendParagraph;
  $('streamPulse').onclick=()=>{
    if(streamPlaying)return;if(textStopped){toast('正文已停止，重置后可重新回放。');return;}
    streamPlaying=true;textEnded=false;updateProcessTitle();$('streamPulse').disabled=true;$('streamPulse').textContent='正文正在补充…';
    [900,1900,2900].forEach((delay,index)=>setTimeout(()=>{
      if(streamPlaying&&!textStopped)appendParagraph();
      if(index===2){if(!textStopped)textEnded=true;streamPlaying=false;$('streamPulse').disabled=false;$('streamPulse').textContent='回放流式补充';updateProcessTitle();announce('人工正文回放结束，工作状态独立');}
    },delay));
  };
  $('jumpLatest').onclick=()=>{conversation.scrollTo({top:conversation.scrollHeight,behavior:reduced()?'instant':'smooth'});$('jumpLatest').hidden=true;};
  function setWeight(n) {
    if(!Number.isFinite(Number(n)))return;const w=clamp(Number(n),0,100);$('weight').value=w;$('weightValue').textContent=w+'%';
    // This bounded fixture has integer dimensions/weights and exact hundredths.
    // Production retains weighted_comparison_v1's decimal/bankers contract.
    const a=(95*w+65*(100-w))/100,b=(65*w+95*(100-w))/100;
    $('scoreA').textContent=a.toFixed(2);$('scoreB').textContent=b.toFixed(2);$('barA').style.width=a+'%';$('barB').style.width=b+'%';
    document.querySelectorAll('[data-priority]').forEach(el=>el.setAttribute('aria-pressed',(el.dataset.priority==='relaxed')===(w>=50)));
  }
  $('weight').oninput=e=>setWeight(e.target.value);document.querySelectorAll('[data-priority]').forEach(el=>el.onclick=()=>setWeight(el.dataset.priority==='relaxed'?70:30));
  function saveDraft(){if(editMode)editDraft=$('draft').value;else{currentDraft=$('draft').value;const item=threads.get(currentThread)||{};threads.set(currentThread,{...item,draft:currentDraft,scroll:conversation.scrollTop});}}
  $('draft').addEventListener('input',saveDraft);
  function continueWithPreference(){saveDraft();editMode=true;editDraft=`按当前偏好继续：安静程度权重 ${$('weight').value}%，保留周日上午的空闲时间。`;$('draft').value=editDraft;$('editContext').hidden=false;$('draft').focus({preventScroll:true});toast('条件已进入原工作草稿，尚未提交');}
  $('continuePlan').onclick=continueWithPreference;
  function revise(){if(!$('detail').hidden)closeDetail();saveDraft();editMode=true;$('draft').value=editDraft||'我想调整这份周末安排：';$('editContext').hidden=false;toast('修改草稿已关联同一成果，尚未提交');}
  $('reviseArtifact').onclick=revise;
  $('exitEdit').onclick=()=>{saveDraft();editMode=false;$('editContext').hidden=true;$('draft').value=currentDraft;};
  $('send').onclick=()=>{$('draft').value.trim()?openSheet('queue',largeY()):toast('先写一句你想交代的事。');};$('attach').onclick=()=>openSheet('attachments',largeY());
  function switchThread(name) {
    saveDraft();threads.get(currentThread).scroll=conversation.scrollTop;currentThread=name;
    if(!threads.has(name))threads.set(name,{draft:'',scroll:0});currentDraft=threads.get(name).draft;editMode=false;$('editContext').hidden=true;$('draft').value=currentDraft;
    $('titleMenu').querySelector('small').innerHTML=`${esc(name)} ${icon('chevron')}`;
    const fixture=name==='周末去山里';conversation.querySelector('.user-message').hidden=conversation.querySelector('.assistant-message').hidden=!fixture;
    let preview=conversation.querySelector('.thread-preview');if(!preview){preview=document.createElement('div');preview.className='thread-preview';conversation.append(preview);}preview.hidden=fixture;
    if(!fixture)preview.innerHTML=`<p class="lead">${name==='新对话'?'今天想交给我什么？':esc(name)}</p><p class="answer">${name==='新对话'?'先说一句想法，具体的事情我们一起理清。':'这是另一段对话的人工导航样例。返回后恢复各自草稿和阅读位置。'}</p>`;
    conversation.scrollTop=threads.get(name).scroll;document.querySelectorAll('.thread').forEach(b=>b.classList.toggle('current',b.dataset.thread===name));closeDrawer();
  }
  function newConversation(){switchThread('新对话');toast('已进入新对话，上一段草稿保留');}
  $('newChat').onclick=newConversation;$('drawerNew').onclick=newConversation;
  document.querySelectorAll('[data-thread]').forEach(b=>b.onclick=()=>switchThread(b.dataset.thread));
  $('drawerSearch').oninput=e=>{let count=0;document.querySelectorAll('[data-thread]').forEach(b=>{b.hidden=!b.dataset.thread.includes(e.target.value);if(!b.hidden)count++;});$('searchEmpty').hidden=count>0;};
  $('drawerPending').onclick=()=>{dismissOther('none');openSheet('approval');};$('drawerActivity').onclick=()=>{dismissOther('none');openDetail();};$('drawerSettings').onclick=()=>openSheet('settings',largeY());
  const studyNotes={conversation:['连贯，才自然。','正文、过程与智能交互共享一条阅读路径。调参数立即更新结果，明确继续才进入草稿。'],drawer:['抓住它，就能改变方向。','直接位移和弹簧共用同一个位置。慢拖看距离，快拖看速度，途中能反向接手。'],detail:['返回，也可以改主意。','从左边缘拖动详情，反向拖回会取消返回。完成以后回到同一成果、同一阅读位置。'],approval:['决定，始终在手边。','抓手上下拖动在两档之间吸附。正文可以滚动，确认区固定在底部；关闭只结束查看。'],image:['每一次展开，都有来路。','同一图片从缩略图展开。下拉可以返回，也可以反向回到大图；关闭时缩回来源。'],menu:['动作贴着对象出现。','浮层在触发按钮旁展开，长按成果显示对象菜单。可用的动作始终属于眼前这个对象。']};
  function study(name) {
    dismissOther('none');if(!$('detail').hidden){detailSpring.set(0);$('detail').hidden=true;root.style.transform='';}
    backgroundAccess();if(currentThread!=='周末去山里')switchThread('周末去山里');
    document.querySelectorAll('[data-study]').forEach(b=>b.classList.toggle('selected',b.dataset.study===name));
    const notes=studyNotes[name];$('noteTitle').textContent=notes[0];$('noteText').textContent=notes[1];$('stageTip').textContent=notes[1];
    if(name==='drawer')openDrawer();else if(name==='detail'){conversation.scrollTop=$('artifactCard').offsetTop-150;openDetail();}
    else if(name==='approval'){conversation.scrollTop=$('pendingCard').offsetTop-120;openSheet('approval');}
    else if(name==='image'){conversation.scrollTop=$('artifactCard').offsetTop-170;openImage($('imageThumb'));}
    else if(name==='menu'){conversation.scrollTop=$('intelligenceCard').offsetTop-40;openPopup($('cardMenu'),'intelligence');}
    else conversation.scrollTop=0;
  }
  document.querySelectorAll('[data-study]').forEach(b=>b.onclick=()=>study(b.dataset.study));
  $('dark').onchange=e=>phone.classList.toggle('dark',e.target.checked);$('solid').onchange=e=>phone.classList.toggle('solid',e.target.checked);
  $('largeText').onchange=e=>{const a=captureAnchor();phone.classList.toggle('large',e.target.checked);restoreAnchor(a);if(!$('sheet').hidden){sheetRest=largeY();sheetSpring.to(sheetRest);}if(processExpanded){$('processTrack').style.height='auto';processSpring.set($('processTrack').getBoundingClientRect().height);}};
  $('reduced').onchange=()=>{document.body.classList.toggle('reduced',reduced());if(reduced())[drawerSpring,detailSpring,sheetSpring,popupSpring,zoomSpring,processSpring].forEach(s=>{if(s.moving)s.to(s.target,0);});};
  $('reset').onclick=()=>location.reload();
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){if(!$('zoom').hidden)closeImage();else if(!$('popover').hidden)closePopup();else if(!$('sheet').hidden)closeSheet();else if(!$('drawer').hidden)closeDrawer();else if(!$('detail').hidden)closeDetail();}
    if(e.key==='Tab'){const front=foreground();if(front===root)return;const list=focusables(front);if(!list.length)return;const first=list[0],last=list.at(-1);if(!front.contains(document.activeElement)){e.preventDefault();(e.shiftKey?last:first).focus();}else if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}
  });
  setWeight(70);sheetSpring.set(height());drawerSpring.set(0);detailSpring.set(0);backgroundAccess();
  // Read-only observational state for review; no remote action adapter exists.
  window.catpawStudyState=()=>({drawer:{value:drawerSpring.value,target:drawerSpring.target,moving:drawerSpring.moving,hidden:$('drawer').hidden},detail:{value:detailSpring.value,target:detailSpring.target,hidden:$('detail').hidden},sheet:{value:sheetSpring.value,target:sheetSpring.target,kind:sheetKind,hidden:$('sheet').hidden},zoom:{value:zoomSpring.value,target:zoomSpring.target,hidden:$('zoom').hidden},approvalStatus,approvalTitle,approvalDraft,approvalRevision,textStopped,workPaused,currentThread,editMode,paragraphCount,scrollTop:conversation.scrollTop});
})();
