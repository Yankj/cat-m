'use strict';
// R3 extends the owned R2 design harness. Fixtures never call execution services.
const baseline = {reset,render,chatHTML,action,openSheet,closeLayer,drawer,openApproval,updateComposer,artifactCard};
Object.assign(sceneNames,{drawer:'侧滑抽屉',process:'流式过程',cards:'流中 Agent 卡',intelligence:'Intelligence UI',overlay:'浮层与编辑',hil:'Human in the loop'});
Object.assign(captions,{drawer:'拖动有回弹；切换不丢草稿。',process:'进展可核对，决定不藏进过程。',cards:'正文继续时，正在填写的字段保持稳定。',intelligence:'直接看、选、试算；明确继续才交给 Agent。',overlay:'关掉视图，仍能接回未完成的编辑。',hil:'关闭、稍后、拒绝与批准，各有明确的结果。'});
const extendedScenes = new Set(['drawer','process','cards','intelligence','overlay','hil']);
const baseCalculatorBinding=bindCalculator;
bindCalculator=function(){
 baseCalculatorBinding();
 [['total','总时长',240],['reserve','预留时间',120],['each','每步时长',120]].forEach(([id,label,usualMax])=>{
  const row=document.createElement('div');row.innerHTML=`<label class="field-label" for="${id}Exact">${label} · 精确输入</label><input id="${id}Exact" type="number" inputmode="decimal" min="0" max="10080" step="any" value="${s.calc[id]}">`;
  $(id).after(row);
  const numeric=$(id+'Exact'),slider=$(id),originalInput=slider.oninput;
  slider.oninput=()=>{originalInput();numeric.value=slider.value;};
  numeric.oninput=()=>{s.calc[id]=numeric.value===''?NaN:Number(numeric.value);if(Number.isFinite(s.calc[id])){slider.max=Math.max(usualMax,s.calc[id]);slider.value=s.calc[id];}updateCalc();};
 });
};
let resettingR3=false,lastRenderedScene='',lastRenderedPage='';
let layerEpoch=0,layerClosing=false,layerAnimations=[],layerOrigin=null,currentPanel=null,parentPanel=null,gesture=null,suppressClickUntil=0;
const toolsets={
 drawer:[['打开抽屉','drawerOpen'],['回放切换再返回','draftRoundtrip']],
 process:[['推进一段','processTick'],['回放断线','processDisconnect'],['回放流结束','processEnd'],['到安全点','processCheckpoint']],
 cards:[['卡片就绪','cardReady'],['正文继续','cardText'],['回放后台正文流','cardStream'],['迟到旧事件','cardOld'],['安全点生效','cardApply'],['成果生成','cardArtifact']],
 intelligence:[['新数据版本','dataVersion'],['不支持的组件','dataFallback']],
 overlay:[['消息操作菜单','messageMenu'],['审批浮层','approval'],['回放连续开合','rapidLayers']],
 hil:[['外部更新版本','hilVersion'],['待决过期','hilExpire'],['结果未知','hilUnknown'],['核对成功／交付失败','hilDelivery'],['稍后再回来','hilReturn']]
};
const hints={drawer:'从手机左侧正文边缘右拖；短拖松开回弹。抽屉内从标题区左拖关闭。详情页使用返回，侧栏不抢系统返回。',process:'回放按钮只注入人工事件；过程不显示隐藏推理。停止文字与暂停工作是两个操作。',cards:'先使卡片就绪，再填写。正文继续和旧事件都不能替换字段；受理后仍须等安全点确认。',intelligence:'甲／乙及分数均为人工算法真值。权重 3:1 得 70/67.5，1:3 得 50/82.5。所有表图试算仅本地。',overlay:'关闭、遮罩、Esc 或下拖把编辑留为草稿；“放弃草稿”需确认。资料详情在同一浮层内返回。',hil:'两个待决对象分开处理。核对结果读取原操作，未知状态没有再次创建入口。'};
function r3State(){return {processStep:0,processOpen:false,processStatus:'running',processLines:['已读取资料标题与公开摘要'],processPaused:false,processPauseRequested:false,processResumeRequested:false,processAnswered:false,cardStage:'partial',cardTitle:'',cardNote:'',cardChoice:'一页报告',cardReceipt:false,formError:'',weights:[3,1],chartMode:'bar',point:'',dataVersion:1,dataPending:false,fallback:false,filter:'',sort:'desc',hilState:'waiting',hilRevision:1,hilViewed:0,hilOperation:0,hilLater:false,hilSecond:false,hilTitle:'项目发布准备',hilEditDraft:null,overlayDraft:'先给结论，再列出依据。',overlaySaved:'先给结论，再列出依据。',overlayTab:'edit'};}
reset=function(scene=s?.scene||'process'){
 resettingR3=true;try{baseline.reset(scene);}finally{resettingR3=false;}s.r3=r3State();$('liveNote').textContent='';if(extendedScenes.has(scene)){s.page='chat';render();}updateTools();
};
function updateTools(){const rows=toolsets[s.scene]||[];$('demoControls').innerHTML=rows.map(([label,a])=>button(label,a,'')).join('');bind($('demoControls'));$('demoHint').textContent=hints[s.scene]||'R2 场景保留。R3 为所有浮层补充关闭过渡、焦点恢复和草稿保存。';}
function announce(text){$('liveNote').textContent=text;}
function isReduced(){return mediaMotion.matches||$('reduce').checked;}
function cancelLayerAnimations(){layerAnimations.forEach(a=>a.cancel());layerAnimations=[];}
function animatePanel(el,from,to,ms){if(isReduced()||!el)return;const a=el.animate([from,to],{duration:ms,easing:'cubic-bezier(.2,.8,.2,1)',fill:'none'});layerAnimations.push(a);}
function savePanelDraft(){
 saveFollowDraft();if(!s?.r3)return;
 if(dialogKind==='overlay-edit'&&$('overlayDraft'))s.r3.overlayDraft=$('overlayDraft').value;
 if(dialogKind==='hil-edit'&&$('hilEditTitle'))s.r3.hilEditDraft=$('hilEditTitle').value;
}
openSheet=function(title,body,footer='',kind=''){
 savePanelDraft();const wasOpen=!$('layer').hidden&&!layerClosing;
 if(!wasOpen){layerOrigin=document.activeElement;parentPanel=null;}
 layerEpoch++;layerClosing=false;cancelLayerAnimations();$('layer').classList.remove('closing');$('layer').style.opacity='';
 baseline.openSheet(title,body,footer,kind);returnFocus=layerOrigin;
 currentPanel={title,body,footer,kind};
 const handle=$('layer').querySelector('.sheet-handle');handle.setAttribute('aria-hidden','true');
 animatePanel($('layer').firstElementChild,{transform:'translateY(32px)',opacity:.4},{transform:'translateY(0)',opacity:1},280);
 if(!wasOpen)animatePanel($('layer'),{opacity:0},{opacity:1},180);
 $('layer').dataset.presentation=kind||'sheet';
};
closeLayer=function(silent=false){
 if(!$('layer')||$('layer').hidden)return;
 savePanelDraft();const epoch=++layerEpoch;cancelLayerAnimations();
 const finish=()=>{if(epoch!==layerEpoch)return;baseline.closeLayer(true);$('layer').classList.remove('closing');layerClosing=false;currentPanel=null;parentPanel=null;$('layer').style.opacity='';$('layer').removeAttribute('data-presentation');if(!silent){const dest=layerOrigin?.isConnected?layerOrigin:$('navLeft');dest.focus({preventScroll:true});}record('浮层已关闭 · 草稿保留 · 无领域提交');};
 if(silent||isReduced()){finish();return;}
 layerClosing=true;$('layer').classList.add('closing');
 const panel=$('layer').firstElementChild;panel.inert=true;
 animatePanel(panel,{transform:panel.style.transform||'translate(0)',opacity:1},{transform:dialogKind==='drawer'?'translateX(-100%)':'translateY(32px)',opacity:0},220);
 animatePanel($('layer'),{opacity:Number($('layer').style.opacity||1)},{opacity:0},180);
 setTimeout(finish,220);
};
drawer=function(){
 saveDraft();layerOrigin=$('navLeft');layerEpoch++;layerClosing=false;cancelLayerAnimations();$('layer').classList.remove('closing');$('layer').style.opacity='';
 baseline.drawer();returnFocus=layerOrigin;currentPanel=null;parentPanel=null;$('layer').dataset.presentation='drawer';
 if(extendedScenes.has(s.scene)){$('drawerResults').querySelector('.current span').textContent=workTitle();}
 // Opening navigation must not summon the keyboard merely to search.
 $('layer').querySelector('[data-action="close"]').focus({preventScroll:true});
 animatePanel($('layer').firstElementChild,{transform:'translateX(-100%)'},{transform:'translateX(0)'},280);
 animatePanel($('layer'),{opacity:0},{opacity:1},180);
};
function r3PendingCount(){if(!extendedScenes.has(s.scene))return s.scene==='approval'?['waiting','unknown'].includes(s.approval)?1:0:s.scene==='decision'&&!s.selected?1:0;const r=s.r3;if(s.scene==='hil')return (['waiting','expired','unknown'].includes(r.hilState)?1:0)+(r.hilSecond?0:1);if(s.scene==='process')return r.processAnswered?0:1;if(s.scene==='cards')return r.cardStage==='ready'?1:0;return s.scene==='drawer'?1:0;}
function workTitle(){return s.scene==='hil'?'发布准备日程':s.scene==='intelligence'?'研究助手方案比较':s.scene==='overlay'?'一页报告修改':'公开资料整理';}
function r3Work(status){return `<section class="work-line" aria-label="当前工作摘要"><div class="work-symbol" aria-hidden="true">≡</div><div><strong>${workTitle()}</strong><p>${status}</p></div>${button('查看','r3Work')}</section>`;}
function processHTML(){const r=s.r3;const statuses={running:'正在整理三份资料',disconnected:'连接中断，正在核对原工作',ended:'文字流已结束，工作仍未结束',paused:'已在安全点暂停',pauseRequested:'已申请暂停，等待安全点',textStopped:'文字生成已停止，工作仍可继续'};const stateLabel=r.processResumeRequested?'已申请恢复，等待确认':r.processPauseRequested?'已申请暂停，等待安全点':r.processPaused?'工作已暂停'+(r.processStatus==='ended'?' · 正文流已结束':''):statuses[r.processStatus];
 return `<div class="user-bubble">整理这三份公开资料，给我一页可用的报告。</div><div class="assistant-copy" id="r3Stream"><p>我会保留资料依据，并把需要你决定的内容单独列出来。</p>${r.processStep?'<p>已核对主题与日期；接下来会对照相同的问题整理差异。</p>':''}</div>${r3Work(stateLabel)}<section class="process-block"><button class="process-toggle" data-action="toggleProcess" aria-expanded="${r.processOpen}" aria-controls="processHistory"><span class="process-indicator" aria-hidden="true"></span><span id="processCurrent">${r.processLines.at(-1)}</span><span aria-hidden="true">${r.processOpen?'⌃':'⌄'}</span></button><div id="processHistory" class="process-history" ${r.processOpen?'':'hidden'}><ol>${r.processLines.map(x=>`<li>${esc(x)}</li>`).join('')}</ol><p class="caption">可核对的执行摘要；不展示内部推理文本。</p><div class="process-controls">${button('停止文字生成','processStop')+button(r.processPaused?'恢复工作':'暂停工作',r.processPaused?'processResume':'processPause')}</div></div></section>${r.processAnswered?'<section class="decision-summary"><p>侧重点已受理：个人日常使用</p>'+button('修改','processReopen')+'</section>':'<section class="decision"><div class="decision-title">需要你补充</div><h3>优先面向谁整理？</h3><p>资料读取可以继续；需要你的回答才能确定评估重点。</p>'+button('个人日常使用','processAnswer','primary')+'</section>'}${r.processStatus==='disconnected'?'<p class="process-state">输入与已读内容保留。核对同一工作后恢复，不重新发起。</p>'+button('核对原工作','processReconnect','soft-button'):''}<div class="source-row">${button('查看资料与依据','sources')}</div>`;
}
function cardsHTML(){const r=s.r3;let card;
 if(r.cardStage==='partial')card=`<section class="component-card" id="agentCard"><p class="caption">正在准备补充信息</p><h3>把报告要求整理清楚</h3><div class="skeleton" aria-hidden="true"><span></span><span></span></div><p>字段尚未完整，当前不可提交。</p></section>`;
 else if(['accepted','applied'].includes(r.cardStage))card=`<section class="decision-summary" id="agentCard"><span aria-hidden="true">${r.cardStage==='applied'?'✓':'↳'}</span><p>${r.cardStage==='applied'?'要求已在安全点生效':'已受理，等待安全点生效'}</p>${button('查看要求','viewCard')}</section>`;
 else card=`<section class="decision" id="agentCard"><div class="decision-title">需要你补充</div><h3>这份报告怎么交付？</h3><p>只补充会影响结果的信息。</p><form class="agent-form" id="agentForm" novalidate><label for="cardTitle">报告标题</label><input id="cardTitle" value="${esc(r.cardTitle)}" autocomplete="off"><label for="cardNote">特别关注什么？（选填）</label><textarea id="cardNote">${esc(r.cardNote)}</textarea><div class="segment" aria-label="交付形式">${['一页报告','对照表'].map(x=>button(x,x==='一页报告'?'formatReport':'formatTable','','aria-pressed="'+(r.cardChoice===x)+'"')).join('')}</div><p id="formError" class="field-error" role="status" ${r.formError?'':'hidden'}>${esc(r.formError)}</p>${button('提交补充信息','cardSubmit','primary')}</form></section>`;
 return `<div class="user-bubble">整理成能直接使用的成果，保留来源。</div><div class="assistant-copy" id="r3Stream"><p>我正在整理报告要求，正文会继续更新。</p></div>${r3Work(r.cardStage==='applied'?'按已生效要求继续':r.cardStage==='accepted'?'等待安全点':r.cardStage==='partial'?'补充卡准备中':'等待你补充')}<div id="cardSlot">${card}</div><details class="process-block"><summary class="process-toggle">查看当前计划</summary><ol class="plan-list"><li><span>✓</span><strong>已读取三份资料</strong></li><li><span>↳</span><strong>整理要求与比较维度</strong></li><li><span>○</span><strong>生成报告与来源</strong></li></ol>${button('修改计划要求','change')}</details><div id="cardArtifactSlot">${r.cardReceipt?artifactCard():''}</div>`;
}
function scores(){const [a,b]=s.r3.weights;return [bankers(80*a+40*b,a+b),bankers(60*a+90*b,a+b)];}
function bankers(n,d){const scaled=n*100,q=Math.floor(scaled/d),rem=scaled-q*d;return (q+(rem*2>d||(rem*2===d&&q%2)?1:0))/100;}
function weightsValid(){return s.r3.weights.every(x=>Number.isInteger(x)&&x>=0&&x<=100)&&s.r3.weights[0]+s.r3.weights[1]>0;}
function chartHTML(){const r=s.r3;if(!weightsValid())return '<p class="process-state">补齐有效权重后再计算。</p>';const values=scores();
 if(r.chartMode==='table')return `<div class="table-scroll"><table><caption class="sr-only">人工方案对照，数据 v${r.dataVersion}</caption><thead><tr><th>方案</th><th>质量／分</th><th>省心／分</th><th>加权／分</th></tr></thead><tbody>${['甲','乙'].map((x,i)=>`<tr><th scope="row">${x}</th><td>${[80,60][i]}</td><td>${[40,90][i]}</td><td>${values[i]}</td></tr>`).join('')}</tbody></table></div>`;
 if(r.chartMode==='line')return `<div class="line-chart" aria-label="原始维度分数连线图，两个类别，不代表时间"><svg viewBox="0 0 300 220" preserveAspectRatio="none" aria-hidden="true"><polyline points="36,44 264,132" fill="none" stroke="currentColor" stroke-width="2"/><polyline points="36,88 264,22" fill="none" stroke="currentColor" stroke-width="2" stroke-dasharray="5 4"/></svg>${[['甲',80,40],['乙',60,90]].map(([x,a,b],i)=>[a,b].map((v,j)=>button(x,'point'+i+j,'',`style="left:${j?88:12}%;top:${100-v}%" aria-label="${x} · ${j?'省心':'质量'} · ${v}分" aria-pressed="${r.point===x+' · '+(j?'省心':'质量')+' · '+v+'分'}"`)).join('')).join('')}</div><div class="line-labels"><span>质量</span><span>省心</span></div><p class="caption">连线帮助对应方案；类别间不表示连续趋势。甲实线，乙虚线。</p>`;
 return `<div class="bar-chart" aria-label="加权分数条图">${['甲','乙'].map((x,i)=>`<button class="chart-row" data-action="point${i}" aria-pressed="${r.point===x+' · 加权 '+values[i]+'分'}"><strong>${x}</strong><div class="bar-track" aria-hidden="true"><div class="bar-fill" style="transform:scaleX(${values[i]/100})"></div></div><output aria-live="off">${values[i]}</output></button>`).join('')}</div><p class="caption">加权分数／分 · 0–100；所有分数为人工输入。</p>`;
}
function intelligenceHTML(){const r=s.r3;
 return `<div class="user-bubble">先比较质量和省心程度，再看不同权重的结果。</div><div class="assistant-copy"><p>可以直接调整权重。这里的甲、乙和分数是人工算法样例。</p></div>${r3Work('本地比较 · 数据 v'+r.dataVersion)}<section class="component-card"><h3>同一组数据，换个角度看</h3><div class="segment" aria-label="呈现方式">${[['bar','条图'],['line','连线图'],['table','表格']].map(([mode,label])=>button(label,'chart'+mode,'','aria-pressed="'+(r.chartMode===mode)+'"')).join('')}</div><div id="chartSlot">${chartHTML()}</div><p class="point-readout" id="pointReadout">${r.point?esc(r.point)+' · 人工数据 v'+r.dataVersion:'点选一个方案或数据点，查看值与依据。'}</p><div class="local-fields"><label for="qualityWeight">质量权重 <input id="qualityWeight" type="number" min="0" max="100" step="1" value="${r.weights[0]}"></label><label for="easeWeight">省心权重 <input id="easeWeight" type="number" min="0" max="100" step="1" value="${r.weights[1]}"></label><p class="field-error" id="weightError" role="status" hidden>权重须为 0–100 的整数，合计大于 0。</p></div><p class="caption">Σ（分数×权重）÷Σ权重，显示两位银行家舍入。weighted_comparison_v1。</p><div class="component-tools">${button('完整表格','fullTable')+button('依据与假设','intelligenceSource')+button('重置参数','resetWeights')}</div>${r.dataPending?'<div class="process-state">资料已有新版本。当前仍显示旧数据与旧参数。</div>'+button('读取新版本并重置','acceptData','soft-button'):''}${r.fallback?'<div class="process-state">该组件暂不支持。原始说明与资料保留，可以继续阅读。</div>':''}<div class="component-tools">${button('按这些条件继续','intelligenceContinue','primary')}</div></section>`;
}
function overlayHTML(){return `<div class="user-bubble">把一页报告的结论写得更直接。</div><div class="assistant-copy"><p>可以先改这一段，再回原工作继续。</p></div>${r3Work('报告 v2 · 可继续修改')}<section class="result-card"><h3>一页报告 · 结论段</h3><p>${esc(s.r3.overlaySaved)}</p><div class="component-tools">${button('编辑结论','overlayEdit')+button('更多操作','messageMenu')}</div></section><div class="source-row">${button('查看资料与依据','sources')}</div><p class="caption">未保存的文字关闭后仍作为本机草稿。保存是本地编辑；交给 Agent 修改须另行明确提交。</p>`;}
function hilHTML(){const r=s.r3;const label={waiting:'需要你确认本次写入',expired:'本次确认已过期',processing:'已提交，等待回执',unknown:'执行结果未确认',done:'执行结果已核对',rejected:'本次写入已拒绝',deliveryFailed:'操作已成功，结果暂未交付'}[r.hilState];return `<div class="user-bubble">安排发布准备，再把报告按我选的重点整理。</div><div class="assistant-copy"><p>有两件事需要你参与。日程写入只在你确认后提交。</p></div>${r3Work(label)}<section class="decision"><div class="decision-title">${r.hilLater?'已留到稍后':'需要你'} · ${r.hilSecond?1:2} 件事</div><div class="hil-object"><h3>发布准备日程</h3><p>明天 10:00 · 15 分钟<br>个人日历 · 新增，不发送邀请 · v${r.hilRevision}</p><p>${label}</p>${button(r.hilState==='unknown'?'核对原操作':r.hilState==='deliveryFailed'?'重新读取回执':'审阅本次内容','hilReview','primary')}</div>${r.hilSecond?'<div class="decision-summary"><p>报告重点已回答：手机内的完整体验</p></div>':'<div class="hil-object"><h3>报告比较重点</h3><p>这个回答只改变报告侧重点。</p>'+button('优先手机内的完整体验','hilSecond','soft-button')+'</div>'}</section>${r.hilState==='done'?'<p class="agent-status">回执已核对。后续工作仍以自己的实际状态继续。</p>':''}`;}
chatHTML=function(){if(resettingR3||!extendedScenes.has(s.scene))return baseline.chatHTML();if(s.scene==='process')return processHTML();if(s.scene==='cards')return cardsHTML();if(s.scene==='intelligence')return intelligenceHTML();if(s.scene==='overlay')return overlayHTML();if(s.scene==='hil')return hilHTML();return `<div class="user-bubble">整理公开资料，稍后回来继续。</div><div class="assistant-copy"><p>工作和草稿都沿原对话接回。</p></div>${r3Work('等待你补充侧重点')}<section class="decision"><h3>从同一件事继续</h3><p>侧栏用于找回最近对话与待决事项。</p>${button('打开侧栏','drawerOpen','primary')}</section>`;};
artifactCard=function(){if(s.scene!=='cards')return baseline.artifactCard();return `<section class="result-card enter"><div class="result-meta"><span aria-hidden="true">✓</span><span>${esc(s.r3.cardChoice)}</span><span>· v2</span></div><h3>${esc(s.r3.cardTitle)}</h3><p>已按你确认的要求整理，正文与依据可以继续修改。</p>${button('查看成果预览','r3Artifact')}<p class="caption">人工成果样例 · 原工作内交付</p></section>`;};
updateComposer=function(){baseline.updateComposer();if(extendedScenes.has(s.scene)&&s.changing)$('changeTitle').textContent=workTitle()+(s.changeTarget==='artifact'?' · v2':'');};
render=function(){if(!resettingR3&&lastRenderedScene===s.scene&&lastRenderedPage===s.page)s.positions[s.page]=$('screen').scrollTop;baseline.render();lastRenderedScene=s.scene;lastRenderedPage=s.page;if(extendedScenes.has(s.scene)&&s.page==='chat'){$('navSubtitle').textContent=workTitle();}if(s.r3&&s.page==='chat'){bindR3Fields();}if(s.page==='memory'){if(s.memoryDeleted)$('screen').innerHTML='<h2>记忆</h2><p class="memory-forgotten">这条记忆已忘记（演示）。来源对话仍保留。</p>';else{$('screen').querySelector('.result-card').insertAdjacentHTML('beforeend',button('忘记这条记忆','forgetMemory'));bind($('screen'));}}$('edgeZone').hidden=s.page!=='chat';};
function bindR3Fields(){if($('agentForm')){$('agentForm').onsubmit=e=>e.preventDefault();$('cardTitle').oninput=()=>{s.r3.cardTitle=$('cardTitle').value;if(s.r3.cardTitle.trim()){s.r3.formError='';$('formError').hidden=true;$('cardTitle').removeAttribute('aria-invalid');}};$('cardNote').oninput=()=>s.r3.cardNote=$('cardNote').value;}if($('qualityWeight'))['qualityWeight','easeWeight'].forEach((id,i)=>{$(id).oninput=()=>{s.r3.weights[i]=$(id).value===''?NaN:Number($(id).value);updateIntelligence();};});}
function updateIntelligence(){const r=s.r3;const valid=r.weights.every(x=>Number.isInteger(x)&&x>=0&&x<=100)&&r.weights[0]+r.weights[1]>0;$('weightError').hidden=valid;$('screen').querySelector('[data-action="intelligenceContinue"]').disabled=!valid;if(valid){r.point='';$('chartSlot').innerHTML=chartHTML();bind($('chartSlot'));$('pointReadout').textContent='参数已更新。点选数据查看值与依据。';}else{$('chartSlot').innerHTML='<p class="process-state">补齐有效权重后再计算，旧结果不可提交。</p>';}record('本地权重调整 · 0 新请求');}
function refreshCard(){const el=document.createElement('div');el.innerHTML=cardsHTML();const next=el.querySelector('#cardSlot').innerHTML;preserveAnchor(()=>{$('cardSlot').innerHTML=next;bind($('cardSlot'));bindR3Fields();const status=$('screen').querySelector('.work-line p');if(status)status.textContent=s.r3.cardStage==='applied'?'按已生效要求继续':s.r3.cardStage==='accepted'?'已受理，等待安全点':s.r3.cardStage==='ready'?'等待你补充':'补充卡准备中';});}
function editOverlay(){openSheet('编辑报告结论',`<label for="overlayDraft">结论</label><textarea id="overlayDraft">${esc(s.r3.overlayDraft)}</textarea><p class="caption">关闭会保留草稿。保存后更新本地预览。</p>`,button('保存本地编辑','overlaySave','primary')+button('放弃未保存草稿','overlayDiscard'),'overlay-edit');}
function fullTable(){if(!weightsValid()){toast('补齐有效权重后查看加权结果');return;}openSheet('完整对照表',`<div class="table-toolbar"><label for="tableFilter">筛选方案</label><input id="tableFilter" value="${esc(s.r3.filter)}" placeholder="甲或乙"><label for="tableSort">按加权分数排序</label><select id="tableSort"><option value="desc">从高到低</option><option value="asc">从低到高</option></select></div><p class="table-count" id="tableCount"></p><div class="table-scroll" id="fullTableSlot"></div><p class="caption">全量 2 行，不是只对预览排序。人工输入，数据 v${s.r3.dataVersion}。</p>`,button('清除筛选','clearFilter','soft-button'),'table');$('tableSort').value=s.r3.sort;$('tableFilter').oninput=()=>{s.r3.filter=$('tableFilter').value;updateFullTable();};$('tableSort').onchange=()=>{s.r3.sort=$('tableSort').value;updateFullTable();};updateFullTable();}
function updateFullTable(){const vals=scores();const rows=['甲','乙'].map((x,i)=>({x,i,v:vals[i]})).filter(x=>x.x.includes(s.r3.filter.trim())).sort((a,b)=>(s.r3.sort==='desc'?-1:1)*(a.v-b.v));$('tableCount').textContent=`显示 ${rows.length} / 2 行 · 质量、省心、加权分／分`;$('fullTableSlot').innerHTML=rows.length?`<table><thead><tr><th>方案</th><th>质量</th><th>省心</th><th>加权</th></tr></thead><tbody>${rows.map(({x,i,v})=>`<tr><th scope="row">${x}</th><td>${[80,60][i]}</td><td>${[40,90][i]}</td><td>${v}</td></tr>`).join('')}</tbody></table>`:'<p class="process-state">没有匹配的行。清除筛选后恢复完整数据。</p>';}
function openHil(){const r=s.r3;if(r.hilState==='unknown'){openSheet('先核对原操作','<p>可能已经创建。读取原操作结果后再决定下一步。</p>',button('核对执行结果','hilReconcile','primary')+button('稍后核对','hilLater'),'hil-unknown');return;}if(r.hilState==='deliveryFailed'){openSheet('操作已成功，结果待恢复','<p>原操作已有成功回执。这里只重新读取成果，不重复创建。</p>',button('重新读取原回执','hilReadReceipt','primary'),'hil-delivery');return;}r.hilViewed=r.hilRevision;const pending=r.hilState==='waiting';openSheet(pending?'确认本次创建':'本次日程内容',`<section class="approval-preview"><h3>发布准备日程</h3><dl><dt>目标</dt><dd>个人日历</dd><dt>时间</dt><dd>2026年10月14日 10:00</dd><dt>时长</dt><dd>15 分钟</dd><dt>内容</dt><dd>${esc(r.hilTitle)} · v${r.hilRevision}</dd></dl></section><div class="approval-impact"><h3>本次影响</h3><p>新增 1 条日程，不邀请其他人，不修改现有日程。</p></div><p class="caption">${r.hilState==='expired'?'已过期，原确认不可提交。重新准备会生成待审阅的新版本。':pending?'关闭或稍后保留原待决入口。':r.hilState==='processing'?'已受理，等待原操作回执。':r.hilState==='rejected'?'本次写入已拒绝，其他工作保留。':'原操作回执已核对。'}</p>`,pending?button('确认创建','hilApprove','primary')+button('修改内容','hilEdit','soft-button')+button('稍后决定','hilLater')+button('拒绝这次写入','hilReject'):r.hilState==='expired'?button('重新准备并审阅','hilPrepare','primary'):button('返回同一工作','close','primary'),'hil-review');}
function openMenu(){layerOrigin=document.activeElement;layerEpoch++;layerClosing=false;cancelLayerAnimations();savePanelDraft();$('layer').classList.remove('closing');$('layer').hidden=false;dialogKind='menu';$('layer').dataset.presentation='menu';$('layer').innerHTML=`<section class="action-menu" role="dialog" aria-modal="true" aria-labelledby="menuTitle"><header><h2 id="menuTitle">这条成果</h2>${button('×','close','icon-button','aria-label="关闭操作菜单"')}</header>${button('查看可复制正文','share')+button('修改这段内容','overlayEdit')+button('查看资料与依据','sources')}</section>`;bind($('layer'));setBackgroundInert(true);$('layer').querySelector('[data-action="close"]').focus();animatePanel($('layer').firstElementChild,{transform:'translateY(8px)',opacity:0},{transform:'translateY(0)',opacity:1},180);}
action=function(a,b){const r=s.r3;
 if(a==='approval'&&s.scene==='overlay'){reset('approval');openApproval();return;}
 if(a==='activity'&&extendedScenes.has(s.scene)){closeLayer();s.page='chat';render();announce('已回到原对话的待决事项');return;}
 if(a==='work'&&extendedScenes.has(s.scene)){action('r3Work');return;}
 if(a==='drawerOpen'){drawer();return;}
 if(a==='new')s.positions[s.page]=$('screen').scrollTop;
 if(a==='draftRoundtrip'){saveDraft();s.positions[s.page]=$('screen').scrollTop;const prior=s;reset('empty');s.previous=prior;record('已切换新对话 · 用侧栏“上一份草稿”恢复');return;}
 if(a==='previous'){baseline.action(a,b);updateTools();document.querySelectorAll('[data-scene]').forEach(x=>x.setAttribute('aria-pressed',String(x.dataset.scene===s.scene)));$('stageCaption').textContent=captions[s.scene];return;}
 if(a==='r3Artifact'){openSheet(s.r3.cardTitle,'<p>先验证中断恢复、报告修改与来源可查，再按要求整理成可用成果。</p><p class="caption">人工报告 v2，完整原生编辑与导出仍按成果合同实现。</p>',button('继续修改同一成果','revise','primary'));return;}
 if(a==='r3Work'){openSheet(workTitle(),'<p>同一工作里的要求、待决与成果分别保留。关闭详情不会停止执行。</p><ol class="plan-list"><li>读取公开资料</li><li>等待必要补充</li><li>整理报告与来源</li></ol>',button('修改工作要求','change','primary')+button('返回原对话','close'),'work');return;}
 if(a==='toggleProcess'){r.processOpen=!r.processOpen;$('processHistory').hidden=!r.processOpen;b.setAttribute('aria-expanded',String(r.processOpen));return;}
 if(a==='processTick'){r.processStep++;r.processLines.push('已核对第 '+Math.min(r.processStep+1,3)+' 份资料的日期与主题');$('r3Stream').insertAdjacentHTML('beforeend','<p>补充：资料描述的使用条件有差异，报告会单独标明。</p>');$('processCurrent').textContent=r.processLines.at(-1);$('processHistory').querySelector('ol').insertAdjacentHTML('beforeend','<li>'+r.processLines.at(-1)+'</li>');record('追加一段正文 · 待决卡未卸载');return;}
 if(['processDisconnect','processEnd','processReconnect','processCheckpoint','processStop','processPause','processResume'].includes(a)){if(a==='processPause')r.processPauseRequested=true;else if(a==='processResume')r.processResumeRequested=true;else if(a==='processCheckpoint'){if(r.processPauseRequested){r.processPaused=true;r.processPauseRequested=false;}else if(r.processResumeRequested){r.processPaused=false;r.processResumeRequested=false;}}else r.processStatus={processDisconnect:'disconnected',processEnd:'ended',processReconnect:'running',processStop:'textStopped'}[a];render();announce(r.processPaused?'工作已在安全点暂停':'工作状态已更新');return;}
 if(a==='processReopen'){r.processAnswered=false;render();return;}
 if(a==='processAnswer'){r.processAnswered=true;render();openSheet('侧重点已受理','<p>优先个人日常使用。文字与工作按各自状态继续。</p>',button('返回','close','primary'));return;}
 if(a==='cardReady'){if(r.cardStage!=='partial'){toast('这张卡已经就绪');return;}r.cardStage='ready';refreshCard();announce('补充信息卡已可填写');return;}
 if(a==='cardText'){const focused=document.activeElement,screen=$('screen'),anchor=focused?.closest('#agentCard')?focused:$('agentCard'),before=anchor?.getBoundingClientRect().top,visible=anchor&&before>=screen.getBoundingClientRect().top&&before<=screen.getBoundingClientRect().bottom,atBottom=screen.scrollHeight-screen.clientHeight-screen.scrollTop<50;$('r3Stream').insertAdjacentHTML('beforeend','<p>资料中提到的限制会保留在报告末尾。</p>');if(visible)screen.scrollTop+=anchor.getBoundingClientRect().top-before;else if(atBottom)screen.scrollTop=screen.scrollHeight;record('正文继续 · 卡片节点与阅读锚点保留');if(focused?.isConnected)focused.focus({preventScroll:true});return;}
 if(a==='cardStream'){const epoch=s;[1200,2400,3600].forEach(ms=>schedule(()=>{if(s===epoch&&s.scene==='cards'&&$('r3Stream'))action('cardText');},ms));record('三段后台正文流已回放 · 卡片节点保留');return;}
 if(a==='cardOld'){record('旧 sequence/revision 事件已忽略 · 用户字段未覆盖');toast('迟到的旧事件已忽略');return;}
 if(a==='formatReport'||a==='formatTable'){r.cardChoice=a==='formatReport'?'一页报告':'对照表';$('agentForm').querySelectorAll('.segment button').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));return;}
 if(a==='cardSubmit'){if(!r.cardTitle.trim()){r.formError='请填写报告标题。';$('formError').hidden=false;$('formError').textContent=r.formError;$('cardTitle').setAttribute('aria-invalid','true');$('cardTitle').focus();return;}r.cardStage='accepted';refreshCard();announce('要求已受理，等待安全点');return;}
 if(a==='cardApply'){if(r.cardStage!=='accepted'){toast('先提交补充信息，再回放安全点');return;}r.cardStage='applied';refreshCard();announce('要求已在安全点生效');return;}
 if(a==='cardArtifact'){if(r.cardStage!=='applied'){toast('先回放要求生效，再查看成果');return;}r.cardReceipt=true;s.artifact=true;$('cardArtifactSlot').innerHTML=artifactCard();bind($('cardArtifactSlot'));announce('有一份新成果');return;}
 if(a==='viewCard'){openSheet('已提交的报告要求',`<p>${esc(r.cardTitle)} · ${esc(r.cardChoice)}</p><p>${esc(r.cardNote||'没有额外关注点')}</p><p class="caption">${r.cardStage==='accepted'?'等待安全点':'已在安全点生效'}</p>`);return;}
 if(a.startsWith('chart')){r.chartMode=a.slice(5);$('chartSlot').innerHTML=chartHTML();bind($('chartSlot'));$('screen').querySelectorAll('.segment button').forEach(x=>x.setAttribute('aria-pressed',String(x.dataset.action===a)));return;}
 if(/^point\d\d?$/.test(a)){const i=Number(a[5]),j=a.length>6?Number(a[6]):null;r.point=['甲','乙'][i]+(j===null?' · 加权 '+scores()[i]+'分':' · '+['质量','省心'][j]+' · '+[[80,40],[60,90]][i][j]+'分');$('pointReadout').textContent=r.point+' · 分／100 · 人工输入 · 数据 v'+r.dataVersion;$('chartSlot').querySelectorAll('button').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));return;}
 if(a==='fullTable'){fullTable();return;}if(a==='clearFilter'){r.filter='';$('tableFilter').value='';updateFullTable();return;}
 if(a==='resetWeights'){r.weights=[3,1];r.point='';$('qualityWeight').value=3;$('easeWeight').value=1;updateIntelligence();return;}
 if(a==='intelligenceSource'){openSheet('依据与计算假设','<p>人工方案甲：质量 80 分、省心 40 分。人工方案乙：质量 60 分、省心 90 分。不是竞品评分。</p><p>条图显示加权结果，连线图显示同版本原始维度分数。权重只改变本地算法结果，不改变资料事实。</p><p class="caption">无真实网页来源。真实产品缺资料时必须显示缺口，不生成分数。</p>');return;}
 if(a==='intelligenceContinue'){if(!weightsValid()){toast('先补齐有效权重');return;}change('work');s.changeDraft='按质量权重 '+r.weights[0]+'、省心权重 '+r.weights[1]+' 继续比较；保留原始分数、来源与局限。';updateComposer();record('明确跟进回同工作草稿 · 尚未提交');return;}
 if(a==='dataVersion'){r.dataPending=true;render();return;}if(a==='acceptData'){r.dataVersion++;r.dataPending=false;r.weights=[3,1];r.point='';r.filter='';r.sort='desc';render();record('演示新版本同值数据 · 显式重置局部状态');return;}if(a==='dataFallback'){r.fallback=true;render();return;}
 if(a==='overlayEdit'){editOverlay();return;}if(a==='overlaySave'){savePanelDraft();r.overlaySaved=r.overlayDraft;closeLayer();render();return;}
 if(a==='overlayDiscard'){savePanelDraft();openSheet('放弃未保存的修改？','<p>将恢复到上次保存的结论。已经保存的报告保留。</p>',button('放弃这份草稿','discardConfirmed','primary')+button('继续编辑','overlayEdit'),'discard');return;}
 if(a==='discardConfirmed'){r.overlayDraft=r.overlaySaved;closeLayer();return;}
 if(a==='messageMenu'){openMenu();return;}if(a==='rapidLayers'){openSheet('资料预览','<p>第一次预览。</p>');closeLayer();openSheet('编辑报告结论','<p>已取消旧关闭回调，这份浮层继续可操作。</p>',button('开始编辑','overlayEdit','primary'),'rapid');return;}
 if(a==='sources'){openSheet('资料与依据',sourceList()+'<p class="caption">工作区人工设计资料摘要。</p>','','sources');return;}
 if(/^source[0-2]$/.test(a)){parentPanel={...currentPanel,scroll:$('layer').querySelector('.sheet-body').scrollTop};openSheet('资料摘要','<p>同一资料的可读摘要，返回保留原列表位置。</p><p class="caption">人工摘要，不是外部网页阅读记录。</p>',button('返回资料列表','panelBack','primary'),'source-detail');return;}
 if(a==='panelBack'){const p=parentPanel;if(p){parentPanel=null;openSheet(p.title,p.body,p.footer,p.kind);$('layer').querySelector('.sheet-body').scrollTop=p.scroll||0;}else closeLayer();return;}
 if(a==='hilReview'){openHil();return;}if(a==='hilSecond'){r.hilSecond=true;render();return;}
 if(a==='hilLater'){r.hilLater=true;closeLayer();render();record('原待决仍保留 · 没有拒绝或批准');return;}
 if(a==='hilReturn'){r.hilLater=false;render();openHil();return;}
 if(a==='hilVersion'){r.hilRevision++;if(!$('layer').hidden&&dialogKind==='hil-review'){$('layer').querySelector('.sheet-body').insertAdjacentHTML('afterbegin','<p class="field-error" role="status">内容已更新。请重新审阅当前版本。</p>');const confirm=$('layer').querySelector('[data-action="hilApprove"]');if(confirm){confirm.disabled=true;confirm.insertAdjacentHTML('afterend',button('重新审阅当前版本','hilReview','soft-button'));bind($('layer'));}}else render();return;}
 if(a==='hilExpire'){r.hilState='expired';render();if(!$('layer').hidden)openHil();return;}
 if(a==='hilPrepare'){r.hilState='waiting';r.hilRevision++;openHil();render();return;}
 if(a==='hilEdit'){openSheet('修改本次内容',`<label for="hilEditTitle">日程标题</label><input id="hilEditTitle" value="${esc(r.hilEditDraft??r.hilTitle)}"><p class="caption">关闭保留修改草稿；保存后必须重新批准新版本。</p>`,button('保存并重新审阅','hilSaveEdit','primary'),'hil-edit');return;}
 if(a==='hilSaveEdit'){savePanelDraft();if(!r.hilEditDraft.trim()){toast('请填写标题');return;}r.hilTitle=r.hilEditDraft.trim();r.hilEditDraft=null;r.hilRevision++;r.hilState='waiting';openHil();render();return;}
 if(a==='hilReject'){r.hilState='rejected';closeLayer();render();return;}
 if(a==='hilApprove'){if(r.hilState!=='waiting'||r.hilViewed!==r.hilRevision){openHil();return;}r.hilOperation++;r.hilState='processing';openSheet('已提交，等待回执','<p>原操作已经受理，执行结果还没有确认。</p><p class="caption">人工回放不会创建日程。可关闭，回来仍读取同一操作。</p>',button('回放未知结果','hilUnknown','soft-button')+button('回放成功回执','hilReconcile','soft-button'),'hil-processing');render();record('演示确认一次 · 关联原操作 #'+r.hilOperation);return;}
 if(a==='hilUnknown'){if(!['processing','unknown'].includes(r.hilState)){toast('先审阅并提交，再回放结果未知');return;}r.hilState='unknown';render();openHil();return;}
 if(a==='hilReconcile'){r.hilState='done';render();openSheet('原操作已核对','<div class="outcome"><h3>日程已创建</h3><p>同一演示操作 #'+r.hilOperation+'，没有再次创建。</p></div>',button('返回同一工作','close','primary'),'hil-receipt');announce('原操作执行结果已核对');return;}
 if(a==='hilDelivery'){if(!['processing','unknown','done'].includes(r.hilState)){toast('先回放原操作提交');return;}r.hilState='deliveryFailed';render();openHil();return;}if(a==='hilReadReceipt'){action('hilReconcile');return;}
 if(a==='forgetMemory'){openSheet('忘记这条记忆？','<p>移除这条偏好，来源对话与成果仍保留。</p>',button('确认忘记（演示）','forgetMemoryConfirmed','primary')+button('继续保留','close'),'forget');return;}if(a==='forgetMemoryConfirmed'){s.memoryDeleted=true;closeLayer();render();return;}
 baseline.action(a,b);
};
// Direct manipulation uses one scoped recognizer; editable/horizontal content is excluded.
const edge=document.createElement('div');edge.id='edgeZone';edge.className='edge-zone';edge.setAttribute('aria-hidden','true');$('phone').append(edge);
$('phone').addEventListener('pointerdown',e=>{
 if(e.button!==0||layerClosing)return;const target=e.target;
 const opening=$('layer').hidden&&s.page==='chat'&&target.closest('#screen')&&e.clientX-$('phone').getBoundingClientRect().left<=22&&!target.closest('input,textarea,select,button,.table-scroll');
 const closing=dialogKind==='drawer'&&target.closest('.drawer')&&!target.closest('input,textarea,button,summary');
 const sheet=!$('layer').hidden&&target.closest('.sheet-handle');
 if(!opening&&!closing&&!sheet)return;
 gesture={id:e.pointerId,x:e.clientX,y:e.clientY,lastX:e.clientX,lastY:e.clientY,t:performance.now(),lastT:performance.now(),vx:0,vy:0,mode:opening?'open':closing?'drawer':'sheet',active:false,delta:0};
});
$('phone').addEventListener('pointermove',e=>{
 if(!gesture||gesture.id!==e.pointerId)return;const g=gesture,dx=e.clientX-g.x,dy=e.clientY-g.y;
 if(!g.active){if(Math.max(Math.abs(dx),Math.abs(dy))<8)return;const horizontal=Math.abs(dx)>Math.abs(dy)*1.4;if((g.mode!=='sheet'&&(!horizontal||(g.mode==='open'&&dx<0)))||(g.mode==='sheet'&&(horizontal||dy<0))){gesture=null;return;}g.active=true;$('phone').setPointerCapture(e.pointerId);if(g.mode==='open')drawer();cancelLayerAnimations();}
 e.preventDefault();const panel=$('layer').firstElementChild;const dt=Math.max(1,performance.now()-g.lastT);g.vx=(e.clientX-g.lastX)/dt*1000;g.vy=(e.clientY-g.lastY)/dt*1000;g.lastX=e.clientX;g.lastY=e.clientY;g.lastT=performance.now();
 const w=panel.getBoundingClientRect().width;g.delta=g.mode==='open'?Math.min(w,Math.max(0,dx)):g.mode==='drawer'?Math.min(w,Math.max(0,-dx)):Math.max(0,dy);
 panel.style.transform=g.mode==='sheet'?`translateY(${g.delta}px)`:`translateX(${g.mode==='open'?g.delta-w:-g.delta}px)`;
 $('layer').style.opacity=String(g.mode==='open'?g.delta/w:Math.max(.2,1-g.delta/(g.mode==='sheet'?450:w)));
},{passive:false});
function endGesture(e,cancelled){if(!gesture||gesture.id!==e.pointerId)return;const g=gesture;gesture=null;if(!g.active)return;suppressClickUntil=performance.now()+350;const panel=$('layer').firstElementChild,w=panel.getBoundingClientRect().width;const velocity=performance.now()-g.lastT>100?0:(g.mode==='sheet'?g.vy:g.mode==='open'?g.vx:-g.vx);const finish=!cancelled&&(g.delta>(g.mode==='sheet'?120:w*.45)||velocity>700);const hide=g.mode==='open'?!finish:finish;const from=panel.style.transform;if(hide){closeLayer();}else{panel.style.transform='';$('layer').style.opacity='';animatePanel(panel,{transform:from},{transform:'translate(0)'},220);}record((cancelled?'手势取消 · ':finish?'越过阈值 · ':'短拖回弹 · ')+(hide?'已关闭':'保持展开'));}
$('phone').addEventListener('pointerup',e=>endGesture(e,false));$('phone').addEventListener('pointercancel',e=>endGesture(e,true));
$('phone').addEventListener('click',e=>{if(performance.now()<suppressClickUntil){e.preventDefault();e.stopImmediatePropagation();}},true);
$('navLeft').onclick=()=>s.page==='chat'?drawer():back();
$('playFlow').onclick=()=>{reset('process');action('processTick');};
$('reset').onclick=()=>reset();document.querySelectorAll('[data-scene]').forEach(b=>b.onclick=()=>reset(b.dataset.scene));
reset('process');
