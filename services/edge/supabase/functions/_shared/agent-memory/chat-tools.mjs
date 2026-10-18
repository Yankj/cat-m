// catpaw.agent-memory.v1 → catpaw-api gated chat registry (catpaw.approval.v1).
// Offered only when the turn froze an enabled memory snapshot (gate on, user consented, use_memory on, not ephemeral)
// and the client negotiated approval.v1. memory_forget always suspends for the user's confirmation (tools.mjs).
import { ApiError } from '../core/facade-r2/src/common.mjs';
import { MEMORY_TOOLS, MemoryError, validateToolArgs } from './contract.mjs';
const asApi = e => e instanceof MemoryError ? new ApiError(e.status >= 500 ? 422 : e.status, e.code) : e;
export function createAgentMemoryChatTools({ service }) {
  const map = new Map();
  for (const definition of MEMORY_TOOLS) {
    const name = definition.function.name;
    map.set(name, {
      definition, contractOnly: true, emitsEvents: true,
      offer: turn => turn?.agent_memory?.enabled === true && (name !== 'memory_save' || turn.agent_memory.auto_save === true || turn.agent_memory.explicit_save === true),
      validate: a => { try { validateToolArgs(name, a); } catch (e) { throw asApi(e); } },
      async summarize(a, ctx = {}) {
        if (name !== 'memory_forget') return `${name}`;
        const hits = ctx.subjectID ? await service.forgetPreview(ctx.subjectID, a) : [];
        return hits.length ? `忘记 ${hits.length} 条记忆：` + hits.map(h => `「${h.slice(0, 40)}」`).join(' ') : '没有找到匹配的记忆';
      },
      async execute(_tx, ctx) {
        try { return await service.executeTool(ctx.principal.subject_id, name, ctx.call.arguments, { conversation_id: ctx.conversation.id, turn_id: ctx.turn.id, operation_id: ctx.operation_id, ...name === 'memory_save' && ctx.turn.agent_memory?.explicit_save === true ? { explicit_save: true, saved_this_turn: (ctx.turn.events ?? []).filter(e => e.type === 'memory_saved').length } : {} }); }
        catch (e) { throw asApi(e); }
      },
    });
  }
  return map;
}
export const agentMemoryPrompt = '\nMemory tools: save only stable facts or preferences the user stated about themselves (one short sentence each); search before update or forget; memory_forget shows the user a confirmation card listing the matches.';

// v54 stopgap (demo-blockers DIAG 症状 2): when this turn offers no memory_save tool (auto memory off, memory off,
// temporary conversation, image turn, feature unavailable), the model must not claim it remembered anything.
// Decided from the tools actually offered this turn, not from settings, so the note can never contradict the tool list.
// No output rewriting. The only tool-list change is the explicit-command case below (explicit_save, explicit-intent.mjs).
const NO_SAVE_BASE = '\nMemory saving is unavailable in this turn: no tool here can save a memory, and a reply alone stores nothing. Never say or imply that you have remembered, saved or noted anything for later, or that you will remember it (for example 记住了, 已记住, 我记下了, 我会记住, "I will remember", "noted for next time").';
const NO_SAVE_REASON = Object.freeze({
  proposal: ' propose_memory_v1 only proposes; the user still has to confirm it, so do not call it saved.',
  ephemeral: ' This is a temporary conversation, which never saves memories. If the user asks you to remember something, say honestly that it was not saved because temporary conversations do not keep memories, then help with the rest of the message.',
  auto_save_off: ' Auto memory (自动记住新内容) is off for this account. If the user asks you to remember something, say honestly that it was not saved because 自动记住新内容 is off, and that they can turn it on in 设置 › 记忆; then help with the rest of the message.',
  memory_off: ' Memory is off for this account. If the user asks you to remember something, say honestly that it was not saved because memory is off, and that they can turn on 使用记忆 and 自动记住新内容 in 设置 › 记忆; then help with the rest of the message.',
  image_turn: ' Memories cannot be saved from a message with an image. If the user asks you to remember something, say honestly that it was not saved and ask them to send it again as text without an image.',
  unavailable: ' If the user asks you to remember something, say honestly that it was not saved, then help with the rest of the message.',
});
/** Which honesty note applies; null when memory_save is offered (behaviour unchanged) or the turn is task/revision work. */
export function memoryNoSaveReason(turn, toolNames, { imageTurn = false } = {}) {
  if (toolNames.includes('memory_save') || turn?.work_intent || turn?.revision_target) return null;
  if (toolNames.includes('propose_memory_v1')) return 'proposal';
  const m = turn?.agent_memory;
  if (m?.mode === 'ephemeral') return 'ephemeral';
  if (m?.enabled === true && m.auto_save !== true) return 'auto_save_off';
  if (m && m.enabled !== true) return 'memory_off';
  if (m?.enabled === true && imageTurn) return 'image_turn';
  return 'unavailable';
}
// auto_save off but the user explicitly asked to remember (UI: 「关闭后只在你明确要求时记住」).
const EXPLICIT_SAVE = '\nAuto memory (自动记住新内容) is off, but the current user message explicitly asks you to remember something, so memory_save is available for that one item only. Save exactly what the user asked to remember as one short sentence, nothing else from the conversation, and never secrets, credentials, health or financial identifiers. Only after memory_save returns status "saved" tell the user plainly that it was saved (for example 已记住：…), and that with 自动记住新内容 off you only remember what they explicitly ask. If it returns anything else, say honestly that it was not saved.';
export function memoryHonestyPrompt(turn, tools, opts) {
  const names = (tools ?? []).map(t => t?.function?.name);
  if (names.includes('memory_save') && turn?.agent_memory?.explicit_save === true && turn.agent_memory.auto_save !== true) return EXPLICIT_SAVE;
  const reason = memoryNoSaveReason(turn, names, opts);
  return reason ? NO_SAVE_BASE + NO_SAVE_REASON[reason] : '';
}
