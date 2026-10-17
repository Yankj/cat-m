// catpaw.task-tools.v1 → catpaw-api chat dispatcher (catpaw.approval.v1 gated registry).
// list_tasks is read-only (policy `never`, runs directly); create_task/update_task are
// first-use approvals of class `proactive_task_write` (approve_always allowed), see core/src/tools.mjs TOOL_APPROVAL.
// All three are offered only on turns that negotiated the approval contract (older iOS builds reject unknown tool names).
import { ApiError } from '../core/facade-r2/src/common.mjs';
import { TASK_TOOLS } from './contract.mjs';
const PROPS = Object.fromEntries(TASK_TOOLS.map(t => [t.function.name, Object.keys(t.function.parameters.properties)]));
const REQUIRED = Object.fromEntries(TASK_TOOLS.map(t => [t.function.name, t.function.parameters.required ?? []]));
function validator(name) {
  return args => {
    const ok = args && typeof args === 'object' && !Array.isArray(args) && Object.keys(args).every(k => PROPS[name].includes(k)) && REQUIRED[name].every(k => args[k] !== undefined && args[k] !== null && args[k] !== '');
    if (!ok) throw new ApiError(422, 'invalid_tool_arguments');
  };
}
function summarize(name, a) {
  if (name === 'create_task') return [`新建：${a.title}`, a.due_at ? `时间：${a.due_at}` : null, a.recurrence ? `重复：${a.recurrence.freq}` : null].filter(Boolean).join(' · ');
  if (name === 'update_task') return [`修改任务 ${String(a.task_id).slice(0, 8)}`, a.status ? `状态→${a.status}` : null, a.title ? `标题→${a.title}` : null, a.due_at ? `时间→${a.due_at}` : null, a.snooze_until ? `稍后→${a.snooze_until}` : null].filter(Boolean).join(' · ');
  return '查看任务';
}
/** @param service createProactiveService(...) instance; executeTool(uid, {name, arguments}, {conversation_id, turn_id, operation_id}) */
export function createTaskChatTools({ service }) {
  const map = new Map();
  for (const definition of TASK_TOOLS) {
    const name = definition.function.name;
    map.set(name, {
      definition, contractOnly: true, validate: validator(name), summarize: a => summarize(name, a),
      // operation_id = stableUUID(turn_id:call_id:operation) from the chat service: identical across
      // retry-busy, approval resume and recovery, so create_task replays instead of duplicating.
      async execute(_tx, ctx) {
        const result = await service.executeTool(ctx.principal.subject_id, { name, arguments: ctx.call.arguments }, { conversation_id: ctx.conversation.id, turn_id: ctx.turn.id, operation_id: ctx.operation_id });
        if (result?.ok === false) throw new ApiError(422, String(result.error ?? 'tool_failed').slice(0, 80));
        return result;
      },
    });
  }
  return map;
}
