// Deterministic, conservative detector for an explicit "remember this" command in the CURRENT user message.
// Used only when auto_save is off (UI promise: 「关闭后只在你明确要求时记住」). False negatives are acceptable
// (nothing is saved, and the reply says so honestly); false positives are not. So any question, negation or
// recall wording disables it, and the command verb must open a clause.
const MAX_CHARS = 500;
// Questions or recall checks ("记住了吗", "你还记得…", "do you remember …?") never count as a command.
const QUESTION = /[?？]|[吗么嘛呢](?:[\s。！!，,~～…]*$|[\s。！!，,~～…])|记得|记不记|有没有记|是否记|能不能记|能记住|可以记住吗|记住没|do\s+you\s+remember|did\s+you\s+remember|can\s+you\s+remember|could\s+you\s+remember|you\s+remember/i;
// Negation / undo: "不要记住", "别记", "不用记", "忘掉", "don't remember".
const NEGATION = /(?:不要|别|不用|不必|无需|不需要|没必要|千万别)\s*(?:帮我|给我|替我)?\s*记|忘掉|忘记|删掉|不要保存|don'?t\s+remember|do\s+not\s+remember|forget/i;
// Command verb at the start of a clause, optionally after a polite/beneficiary prefix.
// "记住了" (acknowledgement) is excluded by the negative lookahead.
const ZH = /(?:^|[\s，,。.!！；;：:、\n])(?:请|麻烦|那就|那|好|好的)?\s*(?:你)?\s*(?:帮我|给我|替我|帮忙)?\s*(?:记住|记下来|记下|记一下|记录一下|记着)(?!了|过|住了)/;
const EN = /(?:^|[.;:!\n,，。！；：]\s*)(?:please\s+|pls\s+|can\s+you\s+please\s+)?(?:remember|memorize|note\s+down|save\s+(?:this|that)\s+(?:to|in)\s+(?:your\s+)?memory)(?:\s*[:：,-]|\s+(?:that|this|my|me|i|i'm|i\s+am|to)\b)/i;
export function explicitRememberIntent(text) {
  if (typeof text !== 'string') return false;
  const t = text.slice(0, MAX_CHARS).normalize('NFKC').trim();
  if (!t || QUESTION.test(t) || NEGATION.test(t)) return false;
  return ZH.test(t) || EN.test(t);
}
