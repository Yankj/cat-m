'use strict';
// Design harness only. All IDs, receipts and text are synthetic; no execution adapter.
const $ = id => document.getElementById(id);
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sceneNames = {decision:'对话与决定',empty:'第一次交代',result:'查收成果',approval:'确认日程',calculator:'直接试算',follow:'持续跟进',error:'失败与恢复',offline:'离线与草稿'};
const captions = {decision:'先读懂正在做什么，再决定下一步。',empty:'一句话就能开始。示例只填草稿。',result:'成果先被读懂，再被保存和继续修改。',approval:'动作、目标与后果，放在同一处。',calculator:'本地调整立即响应。明确继续，才提交。',follow:'有实质变化才出现。没有变化，就安静。',error:'失败有出路，已经完成的工作仍在。',offline:'草稿留在这里。联网不代表自动发送。'};
let s, timers = [], returnFocus, dialogKind = '', toastTimer;
const auditRows = [];
const mediaTheme = matchMedia('(prefers-color-scheme: dark)');
const mediaMotion = matchMedia('(prefers-reduced-motion: reduce)');
function record(message){ auditRows.push(message); $('auditLog').textContent = auditRows.slice(-12).join('\n'); }
function button(label,action,cls='text-button',extra=''){return `<button class="${cls}" data-action="${action}" ${extra}>${label}</button>`;}
function fresh(scene){return {scene,page:['result','follow','calculator','error'].includes(scene)?scene:'chat',selected:scene==='result'?'个人日常使用':'',flow:false,streaming:false,stopped:false,paragraphs:1,artifact:scene==='result',artifactRevision:2,approval:'waiting',eventTitle:'项目发布准备',eventTime:'2026年10月14日 · 10:00',eventDuration:15,eventRevision:1,submittedRevision:0,queue:[],queuePaused:false,chatDraft:scene==='offline'?'把这几份资料整理成一页报告，保留来源。':'',changeDraft:'',changing:false,changeTarget:'work',followPaused:false,quiet:true,frequency:'每天 09:00',condition:'发布说明出现与手机使用相关的实质变化',followDraft:null,followEnded:false,readFailed:scene==='error',memoryText:'报告先给结论，再保留来源',memoryDeleted:false,calc:{total:90,reserve:15,count:3,each:20},positions:{},history:[]};}
function clearTimers(){timers.forEach(clearTimeout);timers=[];}
function schedule(fn,ms){const id=setTimeout(fn,ms);timers.push(id);}
function reset(scene=s?.scene||'decision'){
  clearTimers();closeLayer(true);s=fresh(scene);$('draft').value='';$('keyboard').checked=false;setKeyboard(false);render();
  document.querySelectorAll('[data-scene]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.scene===scene)));
  $('sceneLabel').textContent=sceneNames[scene];$('stageCaption').textContent=captions[scene];record(`场景 ${scene} · 人工状态已重置`);
}
function saveDraft(){if(!s)return;if(s.changing)s.changeDraft=$('draft').value;else s.chatDraft=$('draft').value;}
function bind(root){root.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>action(b.dataset.action,b));}
function workLine(){
  const calendar=s.scene==='approval';const title=['approval','calculator'].includes(s.scene)?'发布准备日程':'个人研究助手比较';
  const status=s.scene==='calculator'?'时间试算 · 本地调整':calendar?(s.approval==='done'?'已核对演示日程':s.approval==='unknown'?'执行结果未确认':s.approval==='rejected'?'本次写入已拒绝':'等待你确认本次写入'):(s.stopped?'文字生成已停止':s.artifact?'报告已整理':'已整理资料 · '+(s.selected?'按你的侧重点继续':'等待一个决定'));
  return `<section class="work-line" aria-label="当前工作摘要"><div class="work-symbol" aria-hidden="true">${calendar?'▢':'≡'}</div><div><strong>${title}</strong><p id="workStatus">${status}</p></div>${button('查看',calendar?'approval':'work')}</section>`;
}
function choice(){
  if(s.selected)return `<section class="decision-summary enter" aria-label="已回答的决定"><span aria-hidden="true">✓</span><p>按${esc(s.selected)}场景比较</p>${button('修改','reopenChoice')}</section>`;
  return `<section class="decision enter" id="decisionCard" aria-labelledby="decisionTitle"><div class="decision-title"><span aria-hidden="true">↳</span>需要你决定</div><h3 id="decisionTitle">这份比较主要用在哪里？</h3><p>会影响评估重点，报告格式可随时改。</p><button class="option" data-action="choosePersonal"><div><strong>个人日常使用</strong><p>优先看省心程度与手机内的完整体验</p></div><span class="chevron" aria-hidden="true">›</span></button><button class="option" data-action="chooseTeam"><div><strong>团队产品立项</strong><p>优先看能力边界与交付条件</p></div><span class="chevron" aria-hidden="true">›</span></button></section>`;
}
function artifactCard(){return `<section class="result-card enter" aria-labelledby="resultTitle"><div class="result-meta"><span aria-hidden="true">✓</span><span>一页报告</span><span>·</span><span>v${s.artifactRevision}</span></div><h3 id="resultTitle">个人研究助手比较</h3><p>先验证完整的工作循环，再比较单点能力。</p><button class="text-button" data-action="result"><span>查看成果</span><span aria-hidden="true">↗</span></button><div class="caption">3 份人工资料 · 可回原工作修改</div></section>`;}
function calendarCard(){
  if(s.approval==='done')return `<section class="result-card enter"><div class="result-meta"><span aria-hidden="true">✓</span><span>演示回执已核对</span></div><h3>${esc(s.eventTitle)}</h3><p>${esc(s.eventTime)} · ${s.eventDuration}分钟</p>${button('查看回执','receipt')+button('查看本次内容','approval')}</section>`;
  if(s.approval==='unknown')return `<section class="decision enter"><div class="decision-title">执行结果未确认</div><h3>先核对是否已经创建</h3><p>不会再次创建同一日程。</p>${button('核对执行结果','reconcile','primary')}</section>`;
  if(s.approval==='rejected')return `<div class="decision-summary"><p>本次写入已拒绝，已整理内容保留。</p>${button('查看内容','approval')}</div>`;
  return `<section class="decision enter"><div class="decision-title">需要你确认</div><h3>${esc(s.eventTitle)}</h3><p>${esc(s.eventTime)} · ${s.eventDuration}分钟<br>新增日程，不发送邀请。</p>${button('审阅本次日程','approval','primary')}</section>`;
}
function chatHTML(){
  if(s.scene==='empty')return `<div class="empty"><h2>今天想交给我什么？</h2><p>一个问题，或一件想完成的事。<br>可以从还不完整的想法开始。</p><div class="examples"><button data-action="exampleReport">把三份资料整理成一页报告<span aria-hidden="true">↗</span></button><button data-action="exampleFollow">关注公开页面的实质变化<span aria-hidden="true">↗</span></button></div></div>`;
  if(s.scene==='offline')return `<div class="assistant-copy"><p>已打开的对话仍在这里。</p></div><section class="decision"><div class="decision-title">当前离线</div><h3>这条消息还没有提交</h3><p>已保存在本机。恢复连接后，先核对原请求。</p>${button('查看本机待发','queue','primary')}</section><p class="caption">可以继续编辑。联网不会自动重发结果未知的请求。</p>`;
  if(s.scene==='calculator')return `<div class="user-bubble">帮我安排发布准备，先留出足够的余量。</div><div class="assistant-copy"><p>可以先试算时间。确定后，再按这个方案继续准备。</p></div>${workLine()}${button('查看时间试算','calculator')}<p class="caption">本地试算不创建日程。修改要求仍须明确提交。</p>`;
  const calendar=s.scene==='approval';
  const request=calendar?'安排明天的发布准备，先给我看看。':'帮我比较这三份研究助手资料，整理成一页，保留来源。';
  const intro=calendar?'可以。我把日程内容整理好了，创建前由你确认。':'我会先看它们如何接住一件真实的工作，再把差异整理成一页。';
  return `<div class="user-bubble">${request}</div><div class="assistant-copy" id="streamCopy"><p>${intro}</p>${s.paragraphs>1?'<p>重点看三件事：中断后能否接上、结果能否修改、每个结论是否有依据。</p>':''}</div>${workLine()}<div id="decisionSlot">${calendar?calendarCard():choice()}</div>${!calendar&&s.streaming?'<div class="work-tools"><span id="streamStatus">正文仍在继续</span>'+button('停止生成','stopStream')+'</div>':''}<div id="afterChoice">${!calendar&&s.selected?'<p class="body-copy after-choice">'+(s.artifact?'已按你的侧重点整理好。下面是可继续修改的成果。':'收到。我会把手机内能否完整完成一件事放在前面。')+'</p>':''}</div><div id="artifactSlot">${!calendar&&s.artifact?artifactCard():''}</div>${!calendar?'<div class="source-row">'+button('查看 3 份人工资料','sources')+'</div>':''}`;
}
function reportHTML(){
  if(s.readFailed)return errorHTML();
  return `<article class="detail-enter"><h2>个人研究助手比较</h2><div class="report-meta"><span>一页报告 · v${s.artifactRevision}</span><span class="outline-tag">人工资料</span></div><p class="report-lead">先验证一件事：离开 App 之后，交代的工作还能接得上。</p><section class="report-section"><h3>先看完整的工作循环</h3><p class="body-copy">回答只是开始。可用的助手还要让你知道进展，保留中断前的成果，在需要决定时找得到你。</p></section><section class="report-section"><h3>优先验证的三个时刻</h3><div class="table-scroll"><table><thead><tr><th scope="col">时刻</th><th scope="col">要看到的行为</th></tr></thead><tbody><tr><th scope="row">需要你</th><td>当前决定可回答，关闭后能找回</td></tr><tr><th scope="row">离开再回来</th><td>同一件工作，同一份草稿与进度</td></tr><tr><th scope="row">拿到成果</th><td>有来源，可使用，也可继续修改</td></tr></tbody></table></div></section><section class="report-section"><h3>这个结论的边界</h3><p class="body-copy">这是根据三份人工设计资料整理的样例。真实模型、持续执行与手机体验仍需同版验证，不是竞品能力排名。</p></section><section class="report-section"><h3>资料与依据</h3>${sourceList()}</section><div class="report-tools">${button('使用这份成果','share')+button('查看版本','versions')}</div></article>`;
}
function sourceList(){return `<div class="source-list">${[['产品体验承诺','产品评审 R1'],['iPhone 工作循环','UX-1 设计合同'],['对话内直接操作','CGUI-1 设计合同']].map(([title,desc],i)=>`<button class="source-item" data-action="source${i}"><div><strong>${title}</strong><span>${desc} · 人工资料</span></div><span class="chevron" aria-hidden="true">›</span></button>`).join('')}</div>`;}
function calculatorHTML(){return `<article class="detail-enter"><p class="caption">准备日程 · 本地时间试算</p><h2 class="block-space">把时间安排得从容一点</h2><p class="follow-summary">先留出余量，再安排具体步骤。</p><section class="calculation-result" id="calcResult"><div class="large-number"><output id="remaining">15</output><span>分钟</span></div><p class="caption" id="calcDescription">剩余缓冲时间</p></section><form class="fields" id="calcForm" novalidate><div><label class="field-label" for="total"><span>总时长</span><output id="totalValue">90 分钟</output></label><input id="total" type="range" min="0" max="240" step="5" value="${s.calc.total}"></div><div><label class="field-label" for="reserve"><span>预留时间</span><output id="reserveValue">15 分钟</output></label><input id="reserve" type="range" min="0" max="120" step="5" value="${s.calc.reserve}"></div><div class="step-number"><label for="count" class="field-label">步骤数量</label><input id="count" type="number" min="0" max="200" step="1" value="${s.calc.count}"></div><div><label class="field-label" for="each"><span>每步时长</span><output id="eachValue">20 分钟</output></label><input id="each" type="range" min="0" max="120" step="5" value="${s.calc.each}"></div><p id="calcError" class="field-error" role="status" hidden></p></form><div class="formula">人工时间预算。剩余＝总时长−预留−步骤数×每步时长。试算不创建日程。<br>公式版本 duration_budget_v1 · ${button('重置参数','resetCalc')}</div></article>`;}
function followHTML(){return `<article class="detail-enter"><div class="follow-status" id="followStatus"><span aria-hidden="true">${s.followPaused||s.followEnded?'Ⅱ':'✓'}</span>${s.followEnded?'已结束':s.followPaused?'已暂停':'按约定跟进'}</div><h2>公开产品更新</h2><p class="follow-summary">只关注会改变手机使用体验的实质变化。</p><div class="detail-row"><span>检查频率</span><strong>${esc(s.frequency)}</strong></div><div class="detail-row"><span>时区</span><strong>Asia/Shanghai</strong></div><div class="detail-row"><span>下次检查</span><strong>${s.followEnded?'已结束':s.followPaused?'暂停期间不检查':'按保存的约定计算'}</strong></div><div class="detail-row"><span>静默时段</span><strong>${s.quiet?'22:00 至 08:00':'已关闭'}</strong></div><p class="quiet-note">没有变化不产生消息。静默期间保留成果，提醒按你的约定出现。以上为人工约定，没有实际调度。</p><section class="change-note"><h3>最近一次变化</h3><p class="body-copy">说明页增加了手机内修改跟进的入口。</p><p class="caption">人工变化样例 · 对照昨日资料</p>${button('查看变化成果','result')}</section>${s.followEnded?'':`<div class="control-pair">${button(s.followPaused?'恢复跟进':'暂停跟进','pauseFollow','soft-button')+button('结束跟进','endFollow','soft-button')}</div>`}</article>`;}
function errorHTML(){return `<section class="error-state detail-enter"><span aria-hidden="true">ⓘ</span><h2>暂时没能读取成果</h2><p>这份报告仍保留。重新读取即可继续，不会重新执行工作。</p>${button('重新读取成果','reread','primary')+button('返回原对话','chat')}<div class="saved-work"><h3>已经完成的工作</h3><p class="caption">个人研究助手比较 · 成果 v${s.artifactRevision}<br>已保留整理记录与资料引用</p></div></section>`;}
function render(){
  const pos=s.positions[s.page]||0;
  const chat=s.page==='chat';$('navLeft').setAttribute('aria-label',chat?'打开侧栏':'返回原位置');$('navLeft').innerHTML=chat?'<span aria-hidden="true">☰</span>':'<span aria-hidden="true">‹</span>';
  $('navTitle').textContent=chat?'Catpaw':{result:'成果',calculator:'时间试算',follow:'持续跟进',work:'工作',error:'成果',activity:'活动',memory:'记忆',settings:'设置'}[s.page]||'Catpaw';
  $('navSubtitle').hidden=!chat;$('navSubtitle').textContent=s.scene==='empty'?'':['approval','calculator'].includes(s.scene)?'发布准备日程':'个人研究助手比较';$('navRight').hidden=!chat;
  $('composerArea').hidden=!chat;$('detailFooter').hidden=!['result','follow','calculator'].includes(s.page);
  if(s.page==='chat')$('screen').innerHTML=chatHTML();
  else if(s.page==='result')$('screen').innerHTML=reportHTML();
  else if(s.page==='calculator')$('screen').innerHTML=calculatorHTML();
  else if(s.page==='follow')$('screen').innerHTML=followHTML();
  else if(s.page==='error')$('screen').innerHTML=errorHTML();
  else if(s.page==='work'&&s.scene==='calculator')$('screen').innerHTML=`<article class="detail-enter"><p class="caption">同一件工作</p><h2 class="block-space">发布准备日程</h2><p class="follow-summary">先预留缓冲，再按已选时间预算准备。</p><div class="detail-row"><span>当前状态</span><strong>时间试算待明确提交</strong></div><section class="report-section"><h3>准备方式</h3><p>核对总时长和预留</p><p class="secondary">按步骤安排每步时长</p><p class="secondary">如需创建日程，另行审阅精确写入</p></section>${button('返回时间试算','calculator','primary')+button('修改要求','change')}</article>`;
  else if(s.page==='work')$('screen').innerHTML=`<article class="detail-enter"><p class="caption">同一件工作</p><h2 class="block-space">个人研究助手比较</h2><p class="follow-summary">用一页报告，讲清楚完整工作循环的差异。</p><div class="detail-row"><span>当前状态</span><strong>${s.artifact?'成果已整理':s.selected?'按侧重点继续':'等待你选择侧重点'}</strong></div><section class="report-section"><h3>工作计划</h3><p>读取三份资料</p><p class="secondary">提炼可以验证的差异</p><p class="secondary">交付一页报告与来源</p></section><section class="report-section">${button('修改要求','change','primary')+button('回原对话处理决定','chat')+(s.artifact?button('查看成果','result'):'')}</section></article>`;
  else if(s.page==='activity')$('screen').innerHTML=`<article class="detail-enter"><h2>活动</h2><section class="report-section"><h3>需要你</h3>${s.scene==='approval'?calendarCard():choice()}</section>${s.artifact?'<section class="report-section"><h3>有新成果</h3>'+artifactCard()+'</section>':''}</article>`;
  else if(s.page==='memory')$('screen').innerHTML=`<article class="detail-enter"><h2>记忆</h2><p class="follow-summary">偏好可以查看、更正和忘记。</p><section class="result-card"><h3>${esc(s.memoryText)}</h3><p>来自本对话 · 当前演示范围</p>${button('查看与更正','memoryEdit')}</section></article>`;
  else if(s.page==='settings')$('screen').innerHTML=`<article class="detail-enter"><h2>设置</h2><div class="detail-row"><span>外观</span><strong>跟随系统</strong></div><p class="quiet-note">这份提案的外观与动态设置位于屏框外。原生设置使用系统控件，账号与模型处理许可保留现有合同。</p></article>`;
  if(s.page==='result')$('detailFooter').innerHTML=button('继续修改','revise','primary');
  if(s.page==='calculator')$('detailFooter').innerHTML=button('用此方案继续','continueCalc','primary','id="continueCalc"');
  if(s.page==='follow')$('detailFooter').innerHTML=button(s.followEnded?'查看历史成果':'编辑跟进约定',s.followEnded?'result':'editFollow','primary');
  bind($('screen'));bind($('detailFooter'));if(s.page==='calculator')bindCalculator();updateComposer();$('screen').scrollTop=pos;$('jump').hidden=true;
}
function navigate(page){saveDraft();s.positions[s.page]=$('screen').scrollTop;s.history.push(s.page);s.page=page;closeLayer();render();if(page!=='chat')$('screen').focus({preventScroll:true});record(`打开 ${page} · 同一演示工作`);}
function back(){saveDraft();s.positions[s.page]=$('screen').scrollTop;s.page=s.history.pop()||'chat';render();}
function updateComposer(){
  $('changeContext').hidden=!s.changing;$('changeTitle').textContent=s.changeTarget==='artifact'?'个人研究助手比较 · v'+s.artifactRevision:['approval','calculator'].includes(s.scene)?'发布准备日程':'个人研究助手比较';
  $('draft').value=s.changing?s.changeDraft:s.chatDraft;
  $('sendMeaning').textContent=s.changing?'提交修改':s.streaming?'排入队列':'';
  $('send').setAttribute('aria-label',s.changing?'提交对此工作的修改':s.streaming?'排入队列':'发送');
  $('send').disabled=!$('draft').value.trim();$('queue').hidden=s.queue.length===0;
  $('queue').innerHTML=`<span>${s.queue.length} 条待发 · ${s.queuePaused?'已暂停':'保存在本机'}</span><span aria-hidden="true">›</span>`;
  $('localStatus').hidden=s.scene!=='offline';$('localStatus').textContent='当前离线 · 草稿保存在本机';resizeDraft();
}
function resizeDraft(){const t=$('draft');t.style.height='auto';t.style.height=Math.min(t.scrollHeight,$('phone').classList.contains('keyboard-on')?80:$('phone').classList.contains('accessibility')?130:parseFloat(getComputedStyle(t).fontSize)*7.5)+'px';}
function preserveAnchor(fn){const screen=$('screen');const atBottom=screen.scrollHeight-screen.clientHeight-screen.scrollTop<50;const pos=screen.scrollTop;fn();if(atBottom&&s.flow)screen.scrollTop=screen.scrollHeight;else screen.scrollTop=pos;}
function updateChoice(){
 const oldCard=$('decisionSlot')?.querySelector('.decision');
 if(s.selected&&oldCard&&!$('reduce').checked&&!mediaMotion.matches){
  oldCard.querySelectorAll('button').forEach(b=>b.disabled=true);
  oldCard.style.animation='none';
  const fade=oldCard.animate([{opacity:1},{opacity:0}],{duration:180,easing:'ease-out',fill:'forwards'});
  fade.finished.then(()=>{if(oldCard.isConnected)replaceChoice();}).catch(()=>{});
 }else replaceChoice();
}
function replaceChoice(){preserveAnchor(()=>{const slot=$('decisionSlot');if(slot){slot.innerHTML=choice();bind(slot);}const status=$('workStatus');if(status)status.textContent='已整理资料 · '+(s.selected?'按你的侧重点继续':'等待一个决定');if($('afterChoice'))$('afterChoice').innerHTML=s.selected?'<p class="body-copy after-choice">收到。我会把'+(s.selected==='个人日常使用'?'手机内能否完整完成一件事':'能力边界与交付条件')+'放在前面。</p>':'';});}
function choose(value){s.selected=value;if(s.page==='chat')updateChoice();else render();record('决定已受理（演示）· 保留正在输入的草稿');if(!s.streaming)schedule(finishReport,650);}
function finishReport(){s.artifact=true;s.streaming=false;if(s.page==='chat'&&$('artifactSlot')){preserveAnchor(()=>{$('artifactSlot').innerHTML=artifactCard();bind($('artifactSlot'));if($('workStatus'))$('workStatus').textContent='报告已整理';const tools=$('screen').querySelector('.work-tools');if(tools)tools.remove();});}updateComposer();record('成果呈现（人工样例）· 非模型或工作执行证据');}
function playFlow(){reset('decision');s.flow=true;s.streaming=true;render();record('流回放开始 · 整段追加，无逐字动效');schedule(()=>{if(s.page==='chat'&&$('streamCopy'))preserveAnchor(()=>{$('streamCopy').insertAdjacentHTML('beforeend','<p>重点看三件事：中断后能否接上、结果能否修改、每个结论是否有依据。</p>');s.paragraphs=2;});},1300);schedule(()=>{s.streaming=false;if(s.selected)finishReport();else{const status=$('streamStatus');if(status)status.textContent='正文已结束 · 等待你决定';const stop=$('screen').querySelector('[data-action="stopStream"]');if(stop)stop.remove();updateComposer();record('正文结束 · 工作仍待决定');}},3900);}
function openSheet(title,body,footer='',kind=''){
  returnFocus=document.activeElement;dialogKind=kind;$('layer').hidden=false;$('layer').innerHTML=`<section class="sheet" role="dialog" aria-modal="true" aria-labelledby="dialogTitle"><div class="sheet-handle" aria-hidden="true"></div><header class="sheet-head"><h2 id="dialogTitle">${title}</h2><button class="icon-button" data-action="close" aria-label="关闭预览">×</button></header><div class="sheet-body">${body}</div>${footer?'<footer class="sheet-foot">'+footer+'</footer>':''}</section>`;bind($('layer'));setBackgroundInert(true);$('layer').querySelector('[data-action="close"]').focus({preventScroll:true});
}
function setBackgroundInert(value){['screen','composerArea','detailFooter','navLeft','navRight','jump','dismissKeyboard'].forEach(id=>{$(id).inert=value;});}
function saveFollowDraft(){if(dialogKind==='follow'&&$('frequency'))s.followDraft={frequency:$('frequency').value,condition:$('condition').value,quiet:$('followQuiet').checked};}
function closeLayer(silent=false){if(!$('layer'))return;saveFollowDraft();$('layer').hidden=true;$('layer').innerHTML='';setBackgroundInert(false);dialogKind='';if(!silent&&returnFocus?.isConnected)returnFocus.focus({preventScroll:true});}
function openApproval(){
  const done=s.approval==='done',rejected=s.approval==='rejected';
  if(s.approval==='unknown'){openUnknown();return;}
  const body=`<p class="caption">${done?'演示回执已核对':rejected?'本次写入已拒绝':'将在系统日历新增一个日程。'}</p><section class="approval-preview"><h3>${esc(s.eventTitle)}</h3><dl><dt>时间</dt><dd>${esc(s.eventTime)}</dd><dt>时长</dt><dd>${s.eventDuration}分钟</dd><dt>日历</dt><dd>个人 · 人工目标</dd></dl></section><div class="approval-impact"><h3>这次操作会做什么</h3><p>新增一个日程。不邀请其他人，不修改已有日程。</p></div><p class="approval-footnote">本次内容 v${s.eventRevision}。内容修改后需重新审阅。关闭预览会保留入口。</p>`;
  openSheet(done?'日程内容':rejected?'已拒绝的日程':'确认创建日程',body,done||rejected?button('返回原对话','close','primary'):button('确认创建','approve','primary')+button('修改内容','editEvent','soft-button')+button('拒绝这次写入','reject'),'approval');s.submittedRevision=s.eventRevision;
}
function openUnknown(){openSheet('先核对执行结果',`<div class="outcome unknown"><div class="outcome-symbol" aria-hidden="true">ⓘ</div><h3>还没有收到回执</h3><p>日程可能已经创建。先读取原操作结果，避免重复写入。</p></div>`,button('核对执行结果','reconcile','primary')+button('稍后核对','close'),'unknown');}
function openFollow(){const d=s.followDraft||{frequency:s.frequency,condition:s.condition,quiet:s.quiet};openSheet('编辑跟进约定',`<label for="frequency">检查频率</label><input id="frequency" value="${esc(d.frequency)}"><label for="condition">触发条件</label><textarea id="condition">${esc(d.condition)}</textarea><div class="detail-row"><span>时区</span><strong>Asia/Shanghai</strong></div><div class="detail-row"><span>停止条件</span><strong>你主动结束时停止</strong></div><label class="field-label" for="followQuiet"><span>静默 22:00 至 08:00</span><input type="checkbox" role="switch" id="followQuiet" ${d.quiet?'checked':''} style="width:24px;min-height:24px"></label><p class="caption">关闭会保留未保存草稿。保存后，才更新演示约定。</p>`,button('保存约定','saveFollow','primary'),'follow');}
function change(target='work'){saveDraft();s.positions[s.page]=$('screen').scrollTop;s.changeTarget=target;s.changing=true;closeLayer();s.page='chat';s.history=[];render();$('draft').focus({preventScroll:true});record('进入明确修改模式 · 聊天与修改各存草稿');}
function bindCalculator(){['total','reserve','count','each'].forEach(id=>{$(id).oninput=()=>{s.calc[id]=$(id).value===''?NaN:Number($(id).value);updateCalc();};});$('calcForm').onsubmit=e=>e.preventDefault();updateCalc();}
function updateCalc(){const {total,reserve,count,each}=s.calc;const valid=[total,reserve,each].every(v=>Number.isFinite(v)&&v>=0&&v<=10080)&&Number.isInteger(count)&&count>=0&&count<=200;['total','reserve','each'].forEach(id=>{$(id+'Value').textContent=(Number.isFinite(s.calc[id])?s.calc[id]:'未填')+' 分钟';});$('calcError').hidden=valid;$('calcError').textContent='步骤数量须为 0 至 200 的整数，时间须在 0 至 10080 分钟。';$('continueCalc').disabled=!valid;if(!valid){$('remaining').textContent='待补充';$('calcDescription').textContent='填写有效参数后试算';return;}const remaining=total-reserve-count*each;$('remaining').textContent=String(remaining);$('calcDescription').textContent=remaining<0?'超出预算 '+Math.abs(remaining)+' 分钟，请调整参数':'剩余缓冲时间';$('calcResult').classList.toggle('over',remaining<0);}
function toast(message){clearTimeout(toastTimer);$('toast').textContent=message;$('toast').hidden=false;toastTimer=setTimeout(()=>{$('toast').hidden=true;},2400);}
function drawer(){returnFocus=document.activeElement;dialogKind='drawer';$('layer').hidden=false;$('layer').innerHTML=`<aside class="drawer" role="dialog" aria-modal="true" aria-labelledby="drawerTitle"><div class="drawer-head"><h2 id="drawerTitle">Catpaw</h2><button class="icon-button" data-action="close" aria-label="关闭侧栏">×</button></div><div class="drawer-content"><div class="drawer-search"><input id="search" placeholder="搜索对话" aria-label="搜索对话"><button class="icon-button" id="clearSearch" aria-label="清除搜索" hidden>×</button></div>${button('＋ 新对话','new','drawer-row drawer-new')}<div id="drawerResults">${(s.scene==='approval'?['waiting','unknown'].includes(s.approval):s.scene==='decision'&&!s.selected)?'<button class="drawer-row" data-action="activity"><span>需要你</span><b>1</b></button>':''}${s.artifact?'<button class="drawer-row" data-action="result"><span>有新成果</span><b>1</b></button>':''}<p class="drawer-section">最近对话</p><button class="drawer-row current" data-action="chat"><span>${['approval','calculator'].includes(s.scene)?'发布准备日程':'个人研究助手比较'}</span></button>${s.previous?'<button class="drawer-row" data-action="previous"><span>上一份草稿</span></button>':''}<p class="drawer-section">工作与资料</p>${button('活动','activity','drawer-row')}<details><summary>资料与管理</summary>${button('工作','work','drawer-row')+button('成果','result','drawer-row')+button('跟进','follow','drawer-row')+button('记忆','memory','drawer-row')}</details></div></div><div class="drawer-bottom">${button('设置','settings','drawer-row')}</div></aside>`;bind($('layer'));setBackgroundInert(true);const initial=$('drawerResults').innerHTML;const search=()=>{const v=$('search').value.trim();$('clearSearch').hidden=!v;$('drawerResults').innerHTML=!v?initial:'个人研究助手比较'.includes(v)?button('个人研究助手比较','chat','drawer-row'):'<p class="search-empty">没有找到对话。清除搜索后返回。</p>';bind($('drawerResults'));};$('search').oninput=search;$('clearSearch').onclick=()=>{$('search').value='';search();$('search').focus();};$('search').focus({preventScroll:true});}
function queueSheet(){openSheet('本机待发消息',s.queue.length?s.queue.map((q,i)=>`<section class="queue-item"><p>${esc(q)}</p>${button('编辑','editQueue'+i)+button('移除','removeQueue'+i)}</section>`).join(''):'<p>没有待发消息。输入内容会先保留为草稿。</p>',s.queue.length?button(s.queuePaused?'继续队列（演示）':'暂停本机队列','pauseQueue','primary'):'','queue');}
function action(a,b){
  if(a==='close'){closeLayer();return;}
  if(a==='choosePersonal'){choose('个人日常使用');return;}if(a==='chooseTeam'){choose('团队产品立项');return;}
  if(a==='reopenChoice'){s.selected='';if(s.page==='chat')updateChoice();else render();return;}
  if(['result','work','calculator','follow','activity','memory','settings'].includes(a)){navigate(a);return;}
  if(a==='chat'){closeLayer();s.page='chat';render();return;}
  if(a==='exampleReport'||a==='exampleFollow'){s.chatDraft=a==='exampleReport'?'把这三份资料整理成一页报告，保留来源。':'关注这个公开页面，有实质变化再告诉我。';updateComposer();$('draft').focus();return;}
  if(a==='new'){saveDraft();const previous=s;reset('empty');s.previous=previous;return;}
  if(a==='previous'){if(s.previous){const previous=s.previous;closeLayer();s=previous;render();$('sceneLabel').textContent=sceneNames[s.scene];}else toast('这份提案尚没有另一份草稿。');return;}
  if(a==='stopStream'){clearTimers();s.streaming=false;s.stopped=true;render();record('停止生成 · 不取消演示工作');return;}
  if(a==='change'||a==='revise'){change(a==='revise'?'artifact':'work');return;}
  if(a==='sources'){openSheet('资料与依据',sourceList()+'<p class="caption">三份工作区设计资料的人工摘要，非外部调研引用。</p>');return;}
  if(/^source[0-2]$/.test(a)){const texts=['把交代的事变成可用成果，需要用户时说清楚，回来时接得上。','对话优先，任务与成果沿同对象展开，修改和返回保留草稿。','表图和固定公式本地交互，明确跟进才提交，写入仍需精确审批。'];openSheet('人工资料摘要','<p>'+texts[Number(a.slice(-1))]+'</p><p class="caption">这份提案展示依据如何被查阅，没有读取外部页面。</p>');return;}
  if(a==='approval'){openApproval();return;}
  if(a==='editEvent'){openSheet('修改日程内容',`<label for="eventTitle">标题</label><input id="eventTitle" value="${esc(s.eventTitle)}"><label for="eventTime">时间</label><input id="eventTime" value="${esc(s.eventTime)}"><p class="caption">保存后重新审阅，旧版本批准不可用于新内容。</p>`,button('保存并重新审阅','saveEvent','primary'),'eventEdit');return;}
  if(a==='saveEvent'){s.eventTitle=$('eventTitle').value.trim()||s.eventTitle;s.eventTime=$('eventTime').value.trim()||s.eventTime;s.eventRevision++;s.approval='waiting';closeLayer();render();openApproval();return;}
  if(a==='reject'){s.approval='rejected';closeLayer();render();record('本次演示写入已拒绝 · 不是关闭');return;}
  if(a==='approve'){
    if(s.submittedRevision!==s.eventRevision){openSheet('内容已更新','<p>请读取当前内容后重新审阅。</p>',button('重新审阅','approval','primary'));return;}
    s.approval='processing';openSheet('正在提交',`<p>等待执行回执。收到回执后才确认完成。</p><div class="skeleton" aria-hidden="true"><span></span><span></span></div><p class="caption">这是人工状态回放，可审阅回执丢失后的处理。</p>`,button('回放回执丢失','unknown','soft-button'),'processing');
    schedule(()=>{if(s.approval!=='processing')return;s.approval='done';if(s.page==='chat')render();if(dialogKind==='processing'){openSheet('日程已核对',`<div class="outcome"><div class="outcome-symbol" aria-hidden="true">✓</div><h3>${esc(s.eventTitle)}</h3><p>${esc(s.eventTime)} · ${s.eventDuration}分钟<br>人工回执，无真实日历写入。</p></div>`,button('返回同一工作','close','primary'),'receipt');}record('收到演示回执 · 一次完成反馈');},2000);return;
  }
  if(a==='unknown'){s.approval='unknown';render();openUnknown();record('演示结果未知 · 没有再次写入动作');return;}
  if(a==='reconcile'){s.approval='done';render();openSheet('原操作已核对','<div class="outcome"><div class="outcome-symbol" aria-hidden="true">✓</div><h3>同一日程，已找到</h3><p>人工回执：原操作关联一个演示日程。仅恢复结果交付，没有再次创建。</p></div>',button('返回同一工作','close','primary'),'receipt');return;}
  if(a==='receipt'){openSheet('本次演示回执',`<p>${esc(s.eventTitle)}</p><p class="caption">内容 v${s.eventRevision}，同一演示操作与日程。本提案没有真实系统对象。</p>`);return;}
  if(a==='share'){openSheet('使用这份成果','<p>原生产品在这里复制正文与来源，或打开系统分享。</p><p class="caption">网页提案可选择以下完整文本，不写剪贴板或伪称已导出文件。</p><label for="shareText">当前版本正文</label><textarea id="shareText" readonly>个人研究助手比较 v'+s.artifactRevision+'\n先验证完整的工作循环：决定可找回、中断能继续、成果有来源且能修改。\n依据：产品评审 R1、UX-1、CGUI-1。全部为人工设计资料。</textarea>');return;}
  if(a==='versions'){openSheet('成果版本','<p>当前 v'+s.artifactRevision+' · 同一演示成果</p><p class="caption">修改请求携带预期版本。版本变化时保留草稿，重新选择当前版本后继续。</p>',button('回放版本冲突','conflict','soft-button'));return;}
  if(a==='conflict'){saveDraft();s.artifactRevision++;openSheet('版本变化，草稿已保留',`<p>当前成果更新为 v${s.artifactRevision}。你的修改草稿不会覆盖新版本。</p><p class="caption">${esc(s.changeDraft||'尚未输入修改要求。')}</p>`,button('按当前版本继续修改','revise','primary'));return;}
  if(a==='reread'){s.readFailed=false;s.page='result';render();record('重新读取 · 不重新执行工作');return;}
  if(a==='resetCalc'){s.calc={total:90,reserve:15,count:3,each:20};render();return;}
  if(a==='continueCalc'){const c=s.calc;change('work');s.changeDraft=`按总时长 ${c.total} 分钟、预留 ${c.reserve} 分钟、${c.count} 步、每步 ${c.each} 分钟继续准备。`;updateComposer();record('参数带回同工作草稿 · 仍须显式提交');return;}
  if(a==='pauseFollow'){s.followPaused=!s.followPaused;render();return;}
  if(a==='editFollow'){openFollow();return;}
  if(a==='saveFollow'){saveFollowDraft();const d=s.followDraft;s.frequency=d.frequency.trim()||s.frequency;s.condition=d.condition;s.quiet=d.quiet;closeLayer();s.followDraft=null;render();toast('约定已保存（演示）');return;}
  if(a==='endFollow'){openSheet('结束这次跟进','<p>不再开始新的检查，已经得到的成果保留。</p>',button('确认结束','confirmEnd','primary')+button('继续保留','close'),'endFollow');return;}
  if(a==='confirmEnd'){s.followEnded=true;closeLayer();render();return;}
  if(a==='memoryEdit'){openSheet('更正记忆','<label for="memoryDraft">内容</label><textarea id="memoryDraft">'+esc(s.memoryText)+'</textarea><p class="caption">来自本对话，仅限人工演示。关闭不会修改。</p>',button('保存更正（演示）','saveMemory','primary'));return;}
  if(a==='saveMemory'){s.memoryText=$('memoryDraft').value.trim()||s.memoryText;closeLayer();render();toast('更正已保存（演示）');return;}
  if(a==='queue'){queueSheet();return;}
  if(a==='pauseQueue'){s.queuePaused=!s.queuePaused;updateComposer();queueSheet();return;}
  if(a.startsWith('removeQueue')){s.queue.splice(Number(a.replace('removeQueue','')),1);updateComposer();queueSheet();return;}
  if(a.startsWith('editQueue')){const i=Number(a.replace('editQueue',''));openSheet('编辑待发消息',`<label for="queueDraft">消息内容</label><textarea id="queueDraft">${esc(s.queue[i])}</textarea>`,button('保存待发内容','saveQueue'+i,'primary'),'queueEdit');return;}
  if(a.startsWith('saveQueue')){s.queue[Number(a.replace('saveQueue',''))]=$('queueDraft').value;queueSheet();updateComposer();return;}
}
function setKeyboard(value){$('phone').classList.toggle('keyboard-on',value);$('keyboardSpace').hidden=!value;resizeDraft();}
function appearance(){const mode=$('appearance').value;$('phone').dataset.theme=mode==='system'?(mediaTheme.matches?'dark':'light'):mode;}
function typeSize(){const v=Number($('typeSize').value);$('phone').style.setProperty('--body',v+'px');$('phone').classList.toggle('large',v===22);$('phone').classList.toggle('accessibility',v===30);resizeDraft();}
$('draft').oninput=()=>{saveDraft();$('send').disabled=!$('draft').value.trim();resizeDraft();};
$('draft').onkeydown=e=>{if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)&&!e.isComposing){e.preventDefault();$('send').click();}};
$('send').onclick=()=>{const text=$('draft').value.trim();if(!text)return;if(s.changing){s.changeDraft='';s.changing=false;updateComposer();openSheet('修改要求已受理（演示）','<p>将在安全点应用到同一件工作。已执行效果仍保留。</p><p class="caption">这里只展示受理状态，不宣称已经改变正在执行的步骤。</p>');record('受理修改 · 未宣称执行完成');}else if(s.scene==='empty'){openSheet('首次发送时确认处理方式','<p>原生产品会检查必需的账号、配置和模型处理许可。草稿保留。</p><p class="caption">提案不会发送真实请求。</p>');}else{s.queue.push(text);s.chatDraft='';updateComposer();record('已保存在本机待发 · 无网络请求');}};
$('exitChange').onclick=()=>{saveDraft();s.changing=false;updateComposer();record('退出修改 · 恢复聊天草稿');};
$('navLeft').onclick=()=>s.page==='chat'?drawer():back();$('navRight').onclick=()=>action('new');
$('attach').onclick=()=>openSheet('添加附件','<p>原生产品从已接通的图片来源选择，预览与移除位于同一输入器。</p><p class="caption">提案不读取相册、文件或申请权限。</p>');
$('queue').onclick=queueSheet;$('screen').onscroll=()=>{if(s.page==='chat'&&s.scene!=='empty')$('jump').hidden=$('screen').scrollHeight-$('screen').clientHeight-$('screen').scrollTop<50;};
$('jump').onclick=()=>{$('screen').scrollTo({top:$('screen').scrollHeight,behavior:mediaMotion.matches||$('reduce').checked?'instant':'smooth'});};
$('layer').onclick=e=>{if(e.target===$('layer'))closeLayer();};
document.addEventListener('keydown',e=>{if($('layer').hidden)return;if(e.key==='Escape'){e.preventDefault();closeLayer();}if(e.key==='Tab'){const list=[...$('layer').querySelectorAll('button,input,textarea,select,summary')].filter(el=>!el.disabled&&!el.hidden&&el.getClientRects().length);if(!list.length)return;const first=list[0],last=list.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}});
document.querySelectorAll('[data-scene]').forEach(b=>b.onclick=()=>reset(b.dataset.scene));
$('playFlow').onclick=playFlow;$('reset').onclick=()=>reset();$('appearance').onchange=appearance;mediaTheme.addEventListener('change',appearance);
$('width').onchange=()=>{const width=$('width').value+'px';$('phone').style.setProperty('--phone-width',width);document.querySelector('.stage').style.setProperty('--phone-width',width);};
$('typeSize').onchange=typeSize;$('reduce').onchange=()=>{$('phone').classList.toggle('reduce',$('reduce').checked);};$('solid').onchange=()=>{$('phone').classList.toggle('solid',$('solid').checked);};$('keyboard').onchange=()=>setKeyboard($('keyboard').checked);$('dismissKeyboard').onclick=()=>{$('keyboard').checked=false;setKeyboard(false);};
appearance();reset('decision');
