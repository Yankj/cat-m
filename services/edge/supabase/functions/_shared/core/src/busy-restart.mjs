// R7 busy retry: pure admission rules for restarting the SAME turn after `rate_limited`.
import { check } from '../facade-r2/src/common.mjs';
export const BUSY_RESTART_LIMIT = 3;
const PRE_OUTPUT_EVENTS = new Set(['turn_started', 'turn_failed']);
/** Throws unless `turn` failed with rate_limited before any output and is still the conversation head. */
export function assertBusyRestartable(turn, conversation, principal) {
  check(turn && turn.conversation_id === conversation.id && turn.subject_id === principal.subject_id, 404, 'turn_not_found');
  check(turn.state === 'failed' && turn.error?.code === 'rate_limited' && !turn.work_intent && !turn.revision_target && !turn.revision_work_intent, 409, 'turn_not_restartable');
  check(Array.isArray(turn.events) && turn.events.every(e => PRE_OUTPUT_EVENTS.has(e.type)), 409, 'turn_output_started');
  check(conversation.state === 'active' && conversation.last_turn_id === turn.id && conversation.grant_epoch === turn.grant_epoch && conversation.revision === turn.conversation_revision, 409, 'turn_not_restartable');
  check((turn.busy_restarts ?? 0) < BUSY_RESTART_LIMIT, 429, 'busy_restart_limit');
}
/** Same identity/request; events kept so the next event continues the original sequence. */
export function restartedTurn(turn) {
  const next = { ...turn, state: 'running', error: null, busy_restarts: (turn.busy_restarts ?? 0) + 1 };
  delete next.finished_at; delete next.dispatch_checkpoint;
  return next;
}
