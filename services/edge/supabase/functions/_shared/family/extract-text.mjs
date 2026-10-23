// Deterministic zh-CN text -> item candidate extractor (offline fallback; a model extractor can replace it).
// Unknowns stay null (never guessed): no date -> local_date null, ambiguous time -> local_time null.
const WD = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 0, 天: 0 };
const CN = { 零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10 };
const num = s => { if (/^\d+$/.test(s)) return Number(s); if (s === '十') return 10; if (s.startsWith('十')) return 10 + (CN[s[1]] ?? 0); if (s.endsWith('十')) return (CN[s[0]] ?? 0) * 10; if (s.includes('十')) return (CN[s[0]] ?? 0) * 10 + (CN[s[2]] ?? 0); return CN[s] ?? NaN; };
const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
const addDays = (ymd, n) => { const d = new Date(ymd + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d; };

export function extractItemsFromText(text, { today, children = [] }) {
  const t = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (!t) return [];
  return t.split(/[；;。\n]+/).map(s => s.trim()).filter(Boolean).map(s => one(s, today, children)).filter(Boolean).slice(0, 5);
}

function one(s, today, children) {
  let date = null, time = null, m;
  const base = new Date(today + 'T00:00:00Z'), dow = base.getUTCDay();
  if (/今天|今日/.test(s)) date = today;
  else if (/明天|明日/.test(s)) date = iso(addDays(today, 1));
  else if (/后天/.test(s)) date = iso(addDays(today, 2));
  if (!date && (m = /(?:(\d{4})年)?(\d{1,2})月(\d{1,2})[日号]/.exec(s))) {
    let y = m[1] ? Number(m[1]) : base.getUTCFullYear(); const cand = `${y}-${pad(m[2])}-${pad(m[3])}`;
    if (!m[1] && cand < today) y += 1;
    const d = new Date(`${y}-${pad(m[2])}-${pad(m[3])}T00:00:00Z`);
    if (d.getUTCMonth() + 1 === Number(m[2])) date = iso(d);
  }
  if (!date && (m = /(下下|下个?|这个?|本)?(?:周|星期|礼拜)([一二三四五六日天])/.exec(s))) {
    const target = WD[m[2]]; let diff = (target - dow + 7) % 7;
    if (m[1] && m[1].startsWith('下')) { const mondayNext = 7 - ((dow + 6) % 7); diff = mondayNext + ((target + 6) % 7) + (m[1].startsWith('下下') ? 7 : 0); }
    date = iso(addDays(today, diff));
  }
  if (!date && (m = /(\d{1,2})[./](\d{1,2})(?!\d)/.exec(s))) { const d = new Date(`${base.getUTCFullYear()}-${pad(m[1])}-${pad(m[2])}T00:00:00Z`); if (!isNaN(d)) date = iso(d); }
  if ((m = /(\d{1,2}):(\d{2})/.exec(s))) time = `${pad(m[1])}:${m[2]}`;
  else if ((m = /(早上|上午|中午|下午|傍晚|晚上)?([0-9一二两三四五六七八九十]{1,3})点(半|一刻|([0-9一二三四五六七八九十]{1,3})分?)?/.exec(s))) {
    let h = num(m[2]); let min = m[3] === '半' ? 30 : m[3] === '一刻' ? 15 : m[4] ? num(m[4]) : 0;
    if (['下午', '傍晚', '晚上'].includes(m[1]) && h < 12) h += 12;
    if (m[1] === '中午' && h < 6) h += 12;
    if (!m[1] && h >= 1 && h <= 6) h = null; // "3点" without am/pm: unknown, not guessed
    if (h !== null && h >= 0 && h <= 23 && min >= 0 && min < 60) time = `${pad(h)}:${pad(min)}`;
  }
  const bring = []; if ((m = /(?:带上?|准备|别忘了?带?|记得带)([^，,。；;]+)/.exec(s))) for (const x of m[1].split(/[、和及与跟,，\s]+/)) { const v = x.replace(/^(好|上)/, '').trim(); if (v && v.length <= 20) bring.push(v); }
  const kid = children.find(c => c.display_name && s.includes(c.display_name));
  let deadline = false; if (/\d{1,2}[日号]?前|之前|截止/.test(s)) deadline = true;
  let place = null; if ((m = /([^\s，,。；;：:0-9]{2,10}?)(门口)?集合/.exec(s))) place = m[1] + (m[2] ?? '');
  if (!place && (m = /(?:在|去|到)([^\s，,。；;]{2,12}?)(?:上课|集合|参加|见面|门口|$|，|,)/.exec(s))) place = m[1];
  let title = s.replace(/(?:带上?|准备|别忘了?带?|记得带)[^，,。；;]+/, '')
    .replace(/(今天|今日|明天|明日|后天|(下下|下个?|这个?|本)?(周|星期|礼拜)[一二三四五六日天]|(\d{4}年)?\d{1,2}月\d{1,2}[日号]|\d{1,2}[./]\d{1,2})/g, '')
    .replace(/(早上|上午|中午|下午|傍晚|晚上)?([0-9一二两三四五六七八九十]{1,3})点(半|一刻|[0-9一二三四五六七八九十]{1,3}分?)?|\d{1,2}:\d{2}/g, '')
    .replace(kid ? new RegExp(kid.display_name, 'g') : /$^/, '').replace(/^[\s，,的要有去]+|[\s，,]+$/g, '').trim();
  title = title.replace(/^[^：:]{0,12}通知[：:]/, '').replace(/[（(][）)]/g, '').replace(/(，|,)?请(?=$|，|,)/g, '').replace(/^前|之前|截止/g, '').replace(/[，,]{2,}/g, '，').replace(/^[\s，,]+|[\s，,]+$/g, '');
  if (place) title = title.replace(new RegExp('[，,]?\\s*' + place + '集合'), '');
  if (place) title = title.replace(new RegExp('\\s*(在|去|到)' + place + '(上课|集合|参加|见面|门口)?'), '').trim();
  if (kid && title.length <= 2) title = title + kid.display_name;
  if (!title) return null;
  if (title.length > 40) title = title.slice(0, 40);
  return { title, deadline, local_date: date, local_time: time, member_id: kid?.member_id ?? null, place, bring: bring.slice(0, 6) };
}
