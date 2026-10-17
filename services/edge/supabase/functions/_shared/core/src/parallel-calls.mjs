// chat-context-1522 B1 (NoBug round 2): a model step with more parallel tool calls than the chat loop runs (4).
// Never execute part of a write batch silently: if ANY call of the step writes or needs the user's confirmation, NONE
// of them runs and every call gets a too_many_parallel_writes result; a read-only step runs its first 4 calls and each
// extra call gets a not_executed result. Write vs read uses the existing approval declarations (tools.mjs
// TOOL_APPROVAL; device tools: confirm 'none' = read-only). Undeclared tools count as writes.
import { toolApprovalPolicy } from './tools.mjs';

export const MAX_PARALLEL_CALLS = 4;
export const TOO_MANY_PARALLEL_WRITES = 'too_many_parallel_writes';

/** True only for calls that cannot change anything and never ask the user. */
export function isReadOnlyCall(name, registry) {
  const reg = registry instanceof Map ? registry.get(name) : null;
  if (reg?.device) return reg.confirm === 'none';
  const policy = toolApprovalPolicy(name);
  return policy.approval === 'never' && (policy.risk === 'read_only' || policy.risk === 'none');
}

/** {calls, blocked:[{call,result}]} for a round whose provider surfaced overflow calls (round.overflow). */
export function planParallelCalls(round, registry) {
  const calls = round.calls ?? [], overflow = round.overflow ?? [];
  if (!overflow.length) return { calls, blocked: [] };
  const all = [...calls, ...overflow], requested = all.length;
  if (all.some(c => !isReadOnlyCall(c.name, registry))) {
    const message = `Not executed: you issued ${requested} tool calls in one step and at least one of them writes or needs the user's confirmation, so none of them ran. Issue write actions one at a time (wait for each result); at most ${MAX_PARALLEL_CALLS} read-only calls may run in parallel.`;
    return { calls: [], blocked: all.map(call => ({ call, result: { status: TOO_MANY_PARALLEL_WRITES, max_parallel_calls: MAX_PARALLEL_CALLS, requested, message } })) };
  }
  const message = `Not executed: only the first ${MAX_PARALLEL_CALLS} parallel read-only calls ran. Call this one again separately if you still need it.`;
  return { calls, blocked: overflow.map(call => ({ call, result: { status: 'not_executed', reason: 'parallel_call_limit', max_parallel_calls: MAX_PARALLEL_CALLS, requested, message } })) };
}
