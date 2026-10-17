// Multi-turn context for turns that did not complete (chat-context-1522).
// complete() is the only path that writes a turn's assistant/tool messages into conversation.model_messages, so a
// turn that fails, is cancelled, or is abandoned while awaiting_approval used to vanish from the model's history: the
// next turn saw two user messages in a row and no trace of the tool call, the user's decision or the text already
// shown. These helpers turn such a turn's durable events into (a) a bounded note that is prepended, as an untrusted
// system record, to the next user message (same pattern as deviceUndoNote), and (b) per-interaction final states the
// client can restore cards from (conversation.interaction_outcomes; JSON on the existing record, no migration).
import { clone } from '../facade-r2/src/common.mjs';

const MAX_NOTES = 4, MAX_TOOLS = 6, MAX_OUTCOMES = 60;
const cut = (s, n) => { const t = String(s ?? '').replace(/\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n) + '…' : t; };
const ARG_KEYS = ['title', 'label', 'content', 'query', 'subject', 'name', 'start', 'due', 'due_at', 'time'];
function argsSummary(args) {
  if (!args || typeof args !== 'object') return '';
  const parts = [];
  for (const k of ARG_KEYS) if (typeof args[k] === 'string' && args[k].trim()) parts.push(`${k}=${cut(args[k], 40)}`);
  return cut(parts.join(', '), 120);
}

/** Final state of one interaction (approval / device / ui interrupt), as a stable label. */
export function interruptOutcome(it) {
  if (!it) return null;
  if (it.status === 'reported') { const s = it.response?.status; return s === 'ok' ? 'ok' : s === 'cancelled' ? 'user_declined' : s === 'denied' ? 'permission_denied' : 'error'; }
  if (it.status === 'cancelled') return it.cancel_reason === 'superseded' ? 'abandoned' : 'cancelled';
  return { approved: 'approved', denied: 'user_declined', expired: 'expired', submitted: 'submitted', dismissed: 'dismissed', errored: 'error', pending: 'pending' }[it.status] ?? String(it.status);
}

/** Tool calls of a turn with what happened to each (from the turn's own durable events + interrupts). */
export function turnToolOutcomes(t) {
  const events = t?.events ?? [], out = [];
  for (const e of events) {
    if (e.type !== 'tool_call' || out.some(o => o.call_id === e.data?.call_id)) continue;
    const id = e.data.call_id, it = (t.interrupts ?? []).find(i => i.call_id === id), result = events.find(x => x.type === 'tool_result' && x.data?.call_id === id);
    let outcome = interruptOutcome(it);
    const notRun = ['too_many_parallel_writes', 'not_executed'].includes(result?.data?.result?.status);
    if (!it || outcome === 'approved') outcome = result ? (notRun ? 'not_executed' : result.data.status === 'ok' ? 'ok' : result.data.status === 'denied' ? 'user_declined' : 'error') : 'not_executed';
    out.push({ call_id: id, name: String(e.data.name ?? ''), args: argsSummary(e.data.arguments), outcome });
  }
  return out;
}

const TEXT = { ok: '已执行成功', user_declined: '用户在确认卡片上主动点了「取消/拒绝」，没有执行（这是用户的决定，不是故障）', expired: '用户没有在时限内确认，没有执行', cancelled: '用户停止了这一轮，没有执行', abandoned: '用户没有在卡片上作答就发了新消息，没有执行', permission_denied: '手机权限不允许，没有执行', error: '执行出错', not_executed: '没有执行', pending: '没有执行', submitted: '用户已提交', dismissed: '用户关闭了卡片' };
const ENDING = { cancelled: '用户主动停止了这一轮', superseded_by_new_message: '用户没有回应确认卡片，直接发了新消息', approval_expired: '确认已过期' };

/** Note for a turn that ended without complete(); null when nothing happened beyond the user's message. */
export function interruptedTurnNote(t, code) {
  if (!t) return null;
  const tools = turnToolOutcomes(t).slice(0, MAX_TOOLS);
  const text = (t.events ?? []).filter(e => e.type === 'text_delta').map(e => e.data?.text ?? '').join('');
  if (!tools.length && !text.trim()) return null;
  return { turn_id: t.id, code: String(code ?? t.error?.code ?? 'turn_interrupted').slice(0, 60), tools, shown_text: cut(text, 300) };
}

/** Model-facing record prepended to the next user message (then cleared). Untrusted system record, never user words. */
export function turnOutcomeNote(notes) {
  if (!Array.isArray(notes) || !notes.length) return '';
  const parts = notes.slice(-MAX_NOTES).map(n => {
    const how = ENDING[n.code] ?? `没有正常结束（${n.code}）`;
    const tools = (n.tools ?? []).map(x => `${x.name}${x.args ? `（${x.args}）` : ''} → ${TEXT[x.outcome] ?? x.outcome}`).join('；');
    return `上一轮回复${how}。` + (tools ? `那一轮的工具调用：${tools}。` : '') + (n.shown_text ? `你当时已经对用户显示了：「${n.shown_text}」。` : '');
  });
  return '（系统记录，不是用户的话：' + parts.join(' ') + ' 请把这些当作对话上下文继续：用户取消或拒绝的操作不要自行重试或换工具绕过，也不要去排查“为什么被取消”；用户提到“取消/手动取消”时就是指这里。）';
}

/** Conversation fields after a turn ended without complete(): the note queue (bounded) and interaction outcomes. */
export function withInterruptedTurn(c, t, code) {
  const note = interruptedTurnNote(t, code);
  return { ...c, ...note ? { turn_outcome_notes: [...(c.turn_outcome_notes ?? []).filter(n => n.turn_id !== t.id), note].slice(-MAX_NOTES) } : {}, ...withInteractionOutcomes(c, t) };
}

/** catpaw.chat-context.v1: final state of every interactive component of a turn, kept on the conversation record so a
 * reopened conversation (GET …/conversations/{id}) can render 已取消 / 已添加 / 已过期 instead of dropping the card. */
export function withInteractionOutcomes(c, t) {
  const items = (t?.interrupts ?? []).filter(i => i.status !== 'pending').map(it => ({
    turn_id: t.id, interrupt_id: it.interrupt_id, call_id: it.call_id, kind: it.kind ?? 'approval', tool: it.tool,
    summary: cut(it.summary, 120), outcome: interruptOutcome(it), ...it.kind === 'device' && it.response?.status ? { device_status: it.response.status } : {}, decided_at: it.decided_at ?? null
  }));
  if (!items.length) return {};
  const ids = new Set(items.map(i => i.interrupt_id));
  return { interaction_outcomes: [...(c.interaction_outcomes ?? []).filter(o => !ids.has(o.interrupt_id)), ...clone(items)].slice(-MAX_OUTCOMES) };
}
