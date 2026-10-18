// Deterministic, conservative detector for an explicit "remember this" command in the CURRENT user message.
// Used only when auto_save is off (UI promise: 「关闭后只在你明确要求时记住」). False negatives are acceptable
// (nothing is saved, and the reply says so honestly); false positives are not.
// v54 R2 (NoBug P1-1): the command must OPEN the message (only polite/filler prefixes before the verb), or be a
// short bare 「…，记住」 tail. A 记住/remember after a colon, quote or newline is quoted, translated, forwarded or
// pasted text and never counts. Task verbs (翻译/总结/转发/translate/summarize…) anywhere disable it, as do
// questions, negations, reminders (「记住明天3点开会」, "remember to …") and any other 记得 wording.
const MAX_CHARS = 500;
// Questions or recall checks ("记住了吗", "你还记得…", "do you remember …?") never count as a command.
const QUESTION = /[?？]|[吗么嘛呢](?:[\s。！!，,~～…]*$|[\s。！!，,~～…])|什么|啥|谁|哪|多少|怎么|为什么|为啥|是不是|是否|有没有|记不记|能不能记|能记住|可以记住吗|记住没|还记得|do\s+you\s+remember|did\s+you\s+remember|can\s+you\s+remember|could\s+you\s+remember|you\s+remember/i;
// Negation / undo: "不要记住", "别记", "不用记", "忘掉", "don't remember".
const NEGATION = /(?:不要|别|不用|不必|无需|不需要|没必要|千万别)\s*(?:帮我|给我|替我)?\s*记|忘掉|忘记|删掉|不要保存|don'?t\s+remember|do\s+not\s+remember|forget/i;
// Working on someone else's text: the 记住 inside it belongs to that text, not to the user.
const TASK = /翻译|译成|译为|润色|总结|摘要|概括|归纳|改写|重写|仿写|续写|校对|分析|转发|转述|引用|解释|朗读|translat|summar|rewrite|rephrase|paraphras|proofread|polish|analy[sz]|forward|\bfwd?:|\bquot(?:e|ing)\b|explain|tl;?dr/i;
// Time-bound items are reminders, not stable memories (「记住明天下午3点开会」, "remember … tomorrow").
const REMINDER = /明天|后天|今天|今晚|今早|明早|明晚|待会|一会|稍后|下周|下个月|\d{1,2}\s*点|tomorrow|tonight|today|later\s+today|next\s+week/i;
// Allowed lead-ins before the verb at the very start of the message.
const LEAD = String.raw`^(?:(?:嗯|好的|好|ok|那就|那|以后都|以后|今后|从现在起|从今以后|请|麻烦|你|帮我|给我|替我|帮忙)[\s，,、]*){0,4}`;
const ZH_VERB = new RegExp(LEAD + String.raw`(?:记住|记下来|记下|记一下|记录一下|记着)(?!了|过|住|没|不)[\s，,：:、哦啊吧啦~～!！]*(\S[\s\S]*)?$`);
// 「把这个记下来：X」 needs the colon and the content in the same message.
const ZH_THIS = new RegExp(LEAD + String.raw`把(?:这个|这条|这些|下面的?|以下(?:内容)?)记(?:下来|住|一下)[：:]\s*(\S[\s\S]*)$`);
// 记得 is usually a reminder (「记得带伞」) or a recall question; only 「记得：X」 and 「记得我喜欢/不吃…」 count.
const ZH_JIDE = new RegExp(LEAD + String.raw`(?:要)?记得(?:[：:]\s*(\S[\s\S]*)|(我(?:喜欢|不喜欢|爱吃|不爱吃|讨厌|偏好|习惯|不吃|不喝|对\S{1,12}过敏)[\s\S]*))$`);
// Short bare tail command about the user: 「我开会喜欢提前10分钟，记住」 (one line, no colon, quotes or reported
// speech such as 他说…, ≤120 chars, and the content mentions 我).
const ZH_TAIL = /^([^：:「」『』“”"《》\n]{4,116})[，,。\s]+(?:你)?记住(?:哦|啊|吧|啦)?[。!！~～]*$/;
// English: "remember that …", "remember my …", "please remember: …"; "remember to …" is a reminder.
const EN = /^(?:(?:ok(?:ay)?|so|and|also)[\s,]+)?(?:please[\s,]+|pls[\s,]+)?(?:remember|memori[sz]e|note\s+down|keep\s+in\s+mind|save\s+(?:this|that)\s+(?:to|in)\s+(?:your\s+)?memory)(?:\s*[:：,-]\s*(?!to\b)(\S[\s\S]*)|\s+((?:that|my|i|i'm|i've|i\s+am)\b[\s\S]*))$/i;
function content(m) { return m ? (m[1] ?? m[2] ?? '').trim() : ''; }
export function explicitRememberIntent(text) {
  if (typeof text !== 'string') return false;
  const t = text.slice(0, MAX_CHARS).normalize('NFKC').trim();
  if (!t || QUESTION.test(t) || NEGATION.test(t) || TASK.test(t)) return false;
  const jide = t.match(ZH_JIDE);
  if (/记得/.test(t) && !jide) return false;
  const m = jide ?? t.match(ZH_THIS) ?? t.match(ZH_VERB) ?? t.match(EN);
  let c = content(m);
  if (!m) { const tail = t.match(ZH_TAIL); if (!tail || !/我/.test(tail[1]) || /说|讲|告诉|写道|写着/.test(tail[1])) return false; c = tail[1].trim(); }
  return c.length > 0 && !REMINDER.test(c);
}
