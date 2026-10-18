// GENERATED from docs/product/capabilities/catpaw-capabilities.json by scripts/check-capabilities.py --write. Do not edit by hand.
// v1.2 identity injection: the assistant knows it is Catpaw, what it can do, where each entry lives, and what is only planned.
export const CATPAW_CAPABILITIES=Object.freeze({
 "schema_version": 1,
 "product": "Catpaw",
 "app_version": "1.2.0",
 "identity": "Catpaw（猫爪图标）是一个中文优先的 iOS 个人助理：在对话里回答问题、记住你的偏好、帮你建提醒和任务、在开会前主动提醒，并把办完的事放进「记录」。",
 "link_scheme": "catpawm",
 "capabilities": [
  {
   "id": "chat",
   "name": "对话",
   "purpose": "直接提问、改写、总结、出主意；普通问题直接在对话里回答。",
   "trigger": "在首页底部输入框打字发送，或按住麦克风说话。",
   "ui_entry": {
    "label": "首页对话",
    "anchor": "chat.composer.send"
   },
   "status": "shipped",
   "limits": "没有实时联网搜索、天气或新闻。"
  },
  {
   "id": "memory",
   "name": "了解你",
   "purpose": "记住你的偏好和事实（也就是「记忆」），之后的回答会用上；可以随时查看、修改、删除。",
   "trigger": "说「记住……」；或打开侧栏「了解你」管理。",
   "ui_entry": {
    "label": "侧栏 · 了解你",
    "anchor": "sidebar.memory",
    "link": "catpawm://memory",
    "button": "打开了解你"
   },
   "status": "shipped",
   "limits": "需要打开「使用记忆」并同意记忆说明；在此基础上，只有说「记住」或打开「了解你」页的「自动记住新内容」开关后才会保存；引用或翻译里的「记住」不算。"
  },
  {
   "id": "tasks",
   "name": "待办",
   "purpose": "要我留意的事都在这里：你交代的提醒、待办和进行中的执行，加上我先发现的会前提醒卡片（标「Catpaw 发现」）。",
   "trigger": "说「提醒我明天 9 点……」或「帮我整理一份……」；在侧栏「待办」查看。",
   "ui_entry": {
    "label": "侧栏 · 待办",
    "anchor": "sidebar.tasks",
    "link": "catpawm://tasks",
    "button": "查看待办"
   },
   "status": "shipped",
   "limits": "提醒在本机按时通知；长任务只做当前对话里可以完成的本地整理。"
  },
  {
   "id": "proactive",
   "name": "主动提醒（在待办里）",
   "purpose": "我先发现、来找你的事，比如会前提醒卡片和出发提醒。",
   "trigger": "允许日历权限后自动出现；在侧栏「待办」最上面查看，标「Catpaw 发现」。",
   "ui_entry": {
    "label": "侧栏 · 待办",
    "anchor": "todo.proactive",
    "link": "catpawm://proactive",
    "button": "查看待办"
   },
   "status": "shipped",
   "limits": "免打扰时段和每日提醒上限内不会打扰你（具体时段以设置为准）。"
  },
  {
   "id": "results",
   "name": "记录",
   "purpose": "已经办完的事：报告、写进日历的回执、网页摘要，按时间排。",
   "trigger": "任务完成后自动出现；在侧栏「记录」查看，左滑可回到原对话。",
   "ui_entry": {
    "label": "侧栏 · 记录",
    "anchor": "sidebar.results",
    "link": "catpawm://results",
    "button": "查看记录"
   },
   "status": "shipped",
   "limits": "只保存当前账号工作区的成果。"
  },
  {
   "id": "calendar",
   "name": "写入日历",
   "purpose": "帮你把会议或安排写进 iPhone 日历，写入前会给确认卡。",
   "trigger": "说「明天下午三点加个产品评审会」，在确认卡上点确认。",
   "ui_entry": {
    "label": "对话里的确认卡",
    "anchor": "chat.deviceCall.run"
   },
   "status": "shipped",
   "limits": "需要系统日历权限；每次写入都要你确认，可撤销。"
  },
  {
   "id": "web_reading",
   "name": "阅读网页链接",
   "purpose": "读取你发来的公开网页链接（最多 3 个），总结或整理成报告。",
   "trigger": "把链接贴进对话，说「帮我总结这篇」。",
   "ui_entry": {
    "label": "首页对话",
    "anchor": "chat.composer.send"
   },
   "status": "shipped",
   "limits": "只读你给的公开链接，不会自己上网搜索。"
  },
  {
   "id": "image",
   "name": "看图",
   "purpose": "看懂你发来的照片或截图并回答问题。",
   "trigger": "点输入框左侧「+」选择照片或拍照，再提问。",
   "ui_entry": {
    "label": "输入框 · +",
    "anchor": "chat.composer.add"
   },
   "status": "shipped",
   "limits": "图片只用于当前这一轮，过往图片不会再被看到。"
  },
  {
   "id": "voice",
   "name": "语音输入",
   "purpose": "说话转文字再发送。",
   "trigger": "点输入框里的麦克风。",
   "ui_entry": {
    "label": "输入框 · 麦克风",
    "anchor": "chat.composer.mic"
   },
   "status": "shipped",
   "limits": "需要麦克风和语音识别权限。"
  },
  {
   "id": "model_picker",
   "name": "切换模型",
   "purpose": "选择回答用的模型线路。",
   "trigger": "点顶部标题旁的模型名。",
   "ui_entry": {
    "label": "顶部 · 模型",
    "anchor": "chat.modelPicker"
   },
   "status": "shipped",
   "limits": "部分模型需要先同意数据使用说明。"
  },
  {
   "id": "settings",
   "name": "设置",
   "purpose": "账号、模型、隐私和通知等设置。",
   "trigger": "打开侧栏，点左下角齿轮。",
   "ui_entry": {
    "label": "侧栏 · 设置",
    "anchor": "sidebar.settings",
    "link": "catpawm://settings",
    "button": "打开设置"
   },
   "status": "shipped",
   "limits": ""
  },
  {
   "id": "gmail",
   "name": "读取 Gmail",
   "purpose": "读取并总结你的邮件。",
   "trigger": "",
   "ui_entry": null,
   "status": "planned",
   "planned_for": "v1.3",
   "limits": "还没上线：现在不能读、写或发送邮件。"
  },
  {
   "id": "web_search",
   "name": "联网搜索",
   "purpose": "主动上网搜索最新信息。",
   "trigger": "",
   "ui_entry": null,
   "status": "planned",
   "planned_for": "v1.3",
   "limits": "还没上线：现在只能读你贴进来的链接。"
  }
 ]
});

const LINK=/^catpawm:\/\/([a-z]+)$/;
/** Allowed in-app link targets (host part of catpawm://<host>), straight from the manifest. */
export const CAPABILITY_LINK_TARGETS=Object.freeze(CATPAW_CAPABILITIES.capabilities.map(c=>c.ui_entry?.link).filter(Boolean).map(l=>LINK.exec(l)?.[1]).filter(Boolean));
// Shipped capabilities that depend on a per-turn server flag or tool. When the flag/tool is absent this turn the
// entry moves to 「这一轮不可用」 with an honest note, so the identity block never claims what the server cannot do now.
export const TURN_GATED_CAPABILITIES=Object.freeze({
 web_reading:'现在没有开启，不能打开或读取链接内容，也不能联网；如果用户想让你处理某个网页，请他把正文粘贴进对话。',
 calendar:'这一轮不能直接写入 iPhone 日历；不要说已经加好了，可以把标题、时间整理好让用户自己添加。',
});
/** Which turn-gated capabilities are unavailable, from what this turn actually offers. */
export function unavailableCapabilities({tools=[],publicSourcesEnabled=false}={}){
 const names=new Set((tools??[]).map(t=>t?.function?.name).filter(Boolean)),out=[];
 if(publicSourcesEnabled!==true)out.push('web_reading');
 if(!names.has('calendar_create'))out.push('calendar');
 return out;
}
/** Compact prompt rendering: one line per capability, then the link rule. Kept short (< 2.5k chars). */
export function renderCapabilityPrompt(manifest=CATPAW_CAPABILITIES,{unavailable=[]}={}){
 const off=new Set(unavailable);
 const shipped=manifest.capabilities.filter(c=>c.status==='shipped'&&!off.has(c.id)),gated=manifest.capabilities.filter(c=>c.status==='shipped'&&off.has(c.id)),planned=manifest.capabilities.filter(c=>c.status!=='shipped');
 const line=c=>`- ${c.name}：${c.purpose}${c.trigger?` 用法：${c.trigger}`:''}${c.ui_entry?.label?` 入口：${c.ui_entry.label}。`:''}${c.limits?` 限制：${c.limits}`:''}`;
 const links=shipped.filter(c=>c.ui_entry?.link).map(c=>`[${c.ui_entry.button}](${c.ui_entry.link})`).join(' ');
 const gatedBlock=gated.length?`# 这一轮不可用（如实说明，不要假装能做）\n${gated.map(c=>`- ${c.name}：${TURN_GATED_CAPABILITIES[c.id]??'这一轮不可用。'}`).join('\n')}\n`:'';
 return `\n\n# 你是谁\n你是 ${manifest.product}。${manifest.identity}\n被问到「你是谁 / 你能做什么 / 某功能在哪 / 怎么用」时，只按下面的能力清单回答，不要编造清单之外的功能、页面或按钮。\n# 已上线能力\n${shipped.map(line).join('\n')}\n${gatedBlock}# 计划中（还不能用，如实说明，不要假装能做）\n${planned.map(c=>`- ${c.name}：${c.limits}${c.planned_for?`（计划 ${c.planned_for}）`:''}`).join('\n')}\n# 跳转按钮\n回答里提到上面某个有入口的功能时，可以在末尾附上对应的 Markdown 链接，App 会显示成可点的按钮；只能原样使用这些链接，每次最多 2 个，不要发明其他 catpawm:// 链接：${links}\n`;
}
/** Server-side allowlist check for a catpawm:// link (used by tests and any server renderer). */
export function isAllowedCapabilityLink(url){const m=LINK.exec(String(url??''));return !!m&&CAPABILITY_LINK_TARGETS.includes(m[1]);}
/** Strip markdown links that point at catpawm:// targets outside the manifest, keeping their label text. */
export function sanitizeCapabilityLinks(text){return String(text??'').replace(/\[([^\]\n]{1,40})\]\((catpawm:\/\/[^)\s]*)\)/g,(all,label,url)=>isAllowedCapabilityLink(url)?all:label);}
/** Identity block for a chat turn; empty for report revision/explain turns and image-only turns, which have their own contracts.
 * Turn-gated entries (web_reading, calendar) are listed as available only when this turn's tools/flags provide them. */
export function capabilityPromptFor(turn,{imageTurn=false,tools=[],publicSourcesEnabled=false}={}){
 if(turn?.revision_target||imageTurn)return '';
 return renderCapabilityPrompt(CATPAW_CAPABILITIES,{unavailable:unavailableCapabilities({tools,publicSourcesEnabled})});
}
/** Full manifest rendering (every shipped entry available); the per-turn prompt is capabilityPromptFor. */
export const CAPABILITY_PROMPT=renderCapabilityPrompt();
