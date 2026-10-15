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
      offer: turn => turn?.agent_memory?.enabled === true && (name !== 'memory_save' || turn.agent_memory.auto_save === true),
      validate: a => { try { validateToolArgs(name, a); } catch (e) { throw asApi(e); } },
      async summarize(a, ctx = {}) {
        if (name !== 'memory_forget') return `${name}`;
        const hits = ctx.subjectID ? await service.forgetPreview(ctx.subjectID, a) : [];
        return hits.length ? `忘记 ${hits.length} 条记忆：` + hits.map(h => `「${h.slice(0, 40)}」`).join(' ') : '没有找到匹配的记忆';
      },
      async execute(_tx, ctx) {
        try { return await service.executeTool(ctx.principal.subject_id, name, ctx.call.arguments, { conversation_id: ctx.conversation.id, turn_id: ctx.turn.id, operation_id: ctx.operation_id }); }
        catch (e) { throw asApi(e); }
      },
    });
  }
  return map;
}
export const agentMemoryPrompt = '\nMemory tools: save only stable facts or preferences the user stated about themselves (one short sentence each); search before update or forget; memory_forget shows the user a confirmation card listing the matches.';
