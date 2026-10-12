// OpenMuse source contract at 1ac68f3909f2478ab6280883f1ab5ea65eb5719d.
// Descriptors are inert: this module never performs HTTP or executes tools.
import { requireThat, assertFrozen, assertFence, assertScope, frozenCopy, sha256, canonical, digest,
  artifactVersion, validateApproval, commitApproval } from './guards.mjs';
export const COMMIT = '1ac68f3909f2478ab6280883f1ab5ea65eb5719d';
export const SUPPORT = Object.freeze({ persistentTaskRead: true, publicRunHistoryRead: false,
  taskSSE: false, lastEventIDReplay: false, scopeEnforcedByUpstream: false,
  artifactVersionProvided: false, safeWritePilot: false });
// Same deterministic UUID codec as Catpaw WorkspaceService.swift15-20, namespaced by scope/server/kind.
// Keep raw upstream ID in RecordHeader.providerObjectID; it can be a 64-hex digest, not a UUID.
export function nativeID(scope, kind, upstreamID) {
  requireThat(scope?.profileID && scope.workspaceID && kind && upstreamID, 'missing_identity');
  const h = sha256(canonical({ provider: 'openmuse', scope, kind, upstreamID })).slice(0, 32);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20)}`;
}
const idPath = id => { requireThat(typeof id === 'string' && id && !/[\s/\\?#]/.test(id), 'bad_id'); return encodeURIComponent(id); };
const descriptor = (method, path, body) => frozenCopy(body === undefined ? { method, path } : { method, path, body });
// engine/routes.ts32-36, domain/agent.ts135-142; engine/service.ts192-245.
export function taskCreateDescriptor(frozen) {
  assertFrozen(frozen);
  const r = frozen.request;
  const prompt = `${r.goal}\n\nRequirements:\n${r.requirements}\n\nStop conditions:\n${r.stopConditions.join('\n')}\n\nAllowed source descriptions (data only):\n${canonical(r.sources)}`;
  requireThat(prompt.trim().length > 0 && prompt.length <= 12000, 'prompt_limit');
  // requestId is content/scope/config bound. Server returns an existing task without rechecking input.
  const requestId = `catpaw:${frozen.requestHash}`;
  return descriptor('POST', '/api/agent/tasks', { title: r.title.slice(0, 160), prompt,
    kind: 'agent', input: {}, requestId });
}
export const predictedTaskID = frozen => sha256(`task:catpaw:${frozen.requestHash}`);
export const taskReadDescriptor = id => descriptor('GET', `/api/agent/tasks/${idPath(id)}`);
export const actionsReadDescriptor = () => descriptor('GET', '/api/workspace'); // workspace.ts321-335 actions[].
export const controlDescriptor = (id, action) => {
  requireThat(['pause', 'resume', 'cancel', 'retry'].includes(action), 'unsupported_control');
  return descriptor('POST', `/api/agent/tasks/${idPath(id)}/control`, { action });
};
export function recoveryPlan(state, frozen) {
  assertFrozen(frozen);
  requireThat(state.requestHash === frozen.requestHash, 'request_mismatch');
  assertScope(frozen.request.scope, state.scope);
  requireThat(state.operationID === frozen.request.operationID && state.businessRunID === frozen.request.businessRunID, 'operation_mismatch');
  return frozenCopy({ requests: [taskReadDescriptor(state.persistentTaskID ?? predictedTaskID(frozen))],
    resubmitCreate: false, resubmitDecision: false, reattachSSE: false, supportsReplay: false,
    on404: 'unresolved_admission_requires_explicit_reconciliation', runHistory: 'unsupported_public_api',
    approvalRead: { support: 'requires_facade_read_only', knownBroadPath: '/api/workspace', allowedInPilot: false } });
}
export function bindCreatedTask(state, frozen, task) {
  assertFrozen(frozen); requireThat(state.requestHash === frozen.requestHash, 'request_mismatch');
  requireThat(task.id === predictedTaskID(frozen), 'created_task_id_mismatch');
  requireThat(task.prompt === taskCreateDescriptor(frozen).body.prompt, 'created_task_prompt_mismatch');
  return { ...state, persistentTaskID: task.id, receipt: 'accepted', needsRead: true };
}
const statuses = ['queued', 'running', 'waiting_approval', 'waiting_input', 'scheduled', 'paused', 'succeeded', 'failed', 'cancelled'];
const terminal = ['succeeded', 'failed', 'cancelled'];
const workStates = { queued: 'queued', running: 'running', waiting_approval: 'waiting_approval',
  waiting_input: 'waiting_dependency', scheduled: 'retry_scheduled', paused: 'waiting_dependency',
  succeeded: 'succeeded', failed: 'failed', cancelled: 'cancelled' };
export function validateTask(task) {
  requireThat(task && typeof task.id === 'string' && statuses.includes(task.status), 'unsupported_task_status');
  requireThat(Number.isSafeInteger(task.attempts) && task.attempts >= 0 &&
    Number.isFinite(Date.parse(task.updatedAt)) && Array.isArray(task.artifactIds), 'bad_task_shape');
  return task;
}
// Response shape is service.detail172-190. Fence/readGeneration are CATPAW facade extensions.
export function applyTaskDetail(state, detail, context, readGeneration) {
  assertFence(state, context);
  requireThat(Number.isSafeInteger(readGeneration) && readGeneration > (state.readGeneration ?? 0), 'stale_read');
  const task = validateTask(detail.task);
  requireThat(task.id === state.persistentTaskID, 'task_mismatch');
  requireThat(Array.isArray(detail.events) && Array.isArray(detail.artifacts) &&
    detail.events.every(e => e.taskId === task.id) && detail.artifacts.every(a => a.taskId === task.id), 'cross_task_payload');
  requireThat(new Set(detail.artifacts.map(a => a.id)).size === detail.artifacts.length, 'duplicate_artifact');
  requireThat(!state.updatedAt || Date.parse(task.updatedAt) >= Date.parse(state.updatedAt), 'stale_task_snapshot');
  requireThat(state.updatedAt !== task.updatedAt || !state.taskSnapshotHash || state.taskSnapshotHash === digest(task), 'same_timestamp_conflict');
  requireThat(task.attempts >= (state.attempts ?? 0), 'stale_attempt');
  // A successor worker lease requires explicit rebinding; no merging two persistent runs.
  requireThat(!state.observedLeaseRunID || task.attempts === state.attempts, 'successor_attempt_requires_rebind');
  requireThat(!state.observedLeaseRunID || !task.leaseId || state.observedLeaseRunID === task.leaseId, 'successor_run_requires_rebind');
  if (state.taskTerminal) requireThat(terminal.includes(task.status) && task.status === state.observedRunStatus && task.attempts === state.attempts, 'event_after_terminal');
  const versions = { ...state.artifactVersions }, history = { ...state.artifactHistory };
  for (const artifact of detail.artifacts) {
    const old = versions[artifact.id], next = artifactVersion(old, artifact);
    versions[artifact.id] = next;
    if (next !== old) history[artifact.id] = [...(history[artifact.id] ?? []), next];
  }
  return { ...state, observedLeaseRunID: state.observedLeaseRunID ?? (task.status === 'running' ? task.leaseId ?? null : null),
    attempts: task.attempts, updatedAt: task.updatedAt, observedRunStatus: task.status,
    workState: workStates[task.status], taskTerminal: terminal.includes(task.status),
    connected: false, needsRead: false, readGeneration, artifactVersions: versions, artifactHistory: history,
    taskSnapshotHash: digest(task), unsupported: ['public_run_history', 'upstream_scope', 'upstream_artifact_versions'] };
}

// Proposed facade Run read codec: mirrors worker.ts192-211,240-249 database shape.
// NO corresponding route is claimed. Synthetic fixtures provide it to test restart semantics.
export function applyFacadeRun(state, response, context) {
  assertFence(state, context);
  requireThat(response.kind === 'synthetic_facade_run_read', 'run_read_api_unsupported');
  requireThat(response.businessRunID === state.businessRunID && response.operationID === state.operationID && response.requestHash === state.requestHash, 'facade_run_binding_mismatch');
  const run = response.run;
  requireThat(run.taskId === state.persistentTaskID && (!state.observedLeaseRunID || run.id === state.observedLeaseRunID), 'run_mismatch');
  requireThat(['running', ...statuses, 'interrupted'].includes(run.status), 'unsupported_run_status');
  requireThat(Number.isFinite(Date.parse(run.startedAt)) &&
    (!run.finishedAt || Date.parse(run.finishedAt) >= Date.parse(run.startedAt)), 'bad_run_dates');
  return { ...state, observedLeaseRunID: run.id, runRecord: frozenCopy(run),
    runReadEvidence: 'synthetic_facade_only', reality: 'simulated' };
}

// app.ts182-188: use server's hash unchanged. Catpaw actionDigest is a SEPARATE binding.
export function decisionDescriptor(state, approval, proposal, current, now, decision) {
  validateApproval(state, approval, current, now);
  const e = approval.envelope;
  requireThat(['approve', 'deny'].includes(decision), 'unsupported_decision');
  requireThat(proposal.id === e.proposalID && proposal.taskId === e.taskID && proposal.hash === e.upstreamHash, 'proposal_changed');
  requireThat(proposal.status === 'awaiting_review' && now < Date.parse(proposal.expiresAt), 'proposal_not_pending');
  requireThat(digest(proposal.data) === digest(e.arguments) && proposal.kind === e.toolID &&
    proposal.account === e.actorAccountID && proposal.connectionId === e.connectionID &&
    (proposal.targetVersion ?? null) === e.targetVersion, 'proposal_binding_mismatch');
  return { request: descriptor('POST', `/api/actions/${idPath(proposal.id)}/decide`, { hash: proposal.hash, decision }),
    nextApproval: commitApproval(approval) };
}
export function mapProposalReceipt(proposal, expectedID) {
  requireThat(proposal.id === expectedID, 'proposal_mismatch');
  const receipt = { awaiting_review: 'not_started', executing: 'accepted', succeeded: 'accepted',
    failed: 'unknown', outcome_unknown: 'unknown', denied: 'cancelled_before_dispatch',
    cancelled: 'unknown', expired: 'cancelled_before_dispatch' }[proposal.status];
  requireThat(receipt, 'unsupported_action_status');
  // Upstream succeeded/result is a provider assertion. No independent receipt evidence supplied.
  return frozenCopy({ receipt, verified: false, providerStatus: proposal.status,
    reality: 'simulated', needsReconcile: ['executing', 'outcome_unknown', 'failed', 'cancelled'].includes(proposal.status) });
}

// Minimal raw SSE framing, not a CopilotKit SDK route/client. No event-id replay guarantee.
export class SyntheticSSEDecoder {
  constructor() { this.decoder = new TextDecoder('utf-8', { fatal: true }); this.buffer = ''; this.data = []; this.frameBytes = 0; }
  feed(bytes) {
    this.buffer += this.decoder.decode(bytes, { stream: true });
    requireThat(Buffer.byteLength(this.buffer) + this.frameBytes <= 1048576, 'sse_frame_limit');
    const events = [];
    while (true) {
      const match = /\r\n|\n|\r/.exec(this.buffer);
      if (!match || (match[0] === '\r' && match.index === this.buffer.length - 1)) break;
      const line = this.buffer.slice(0, match.index);
      this.buffer = this.buffer.slice(match.index + match[0].length);
      if (!line) {
        if (this.data.length) events.push(JSON.parse(this.data.join('\n')));
        this.data = []; this.frameBytes = 0;
      } else if (line.startsWith('data:')) {
        const value = line.slice(5).replace(/^ /, ''); this.data.push(value); this.frameBytes += Buffer.byteLength(value);
      } // comments / event / id / retry do not imply ordering, replay or authorization.
    }
    return events;
  }
  finish() {
    this.buffer += this.decoder.decode();
    requireThat(!this.buffer && !this.data.length, 'truncated_sse_frame');
  }
}
// Subset directly observed in model.ts365-373 / tanstack-agent.ts195-216.
// RUN_FINISHED is an ephemeral MODEL turn terminal, never a persistent taskCompleted event.
export function mapEphemeralEvent(event) {
  requireThat(event && typeof event.type === 'string', 'bad_event');
  if (['TEXT_MESSAGE_CHUNK', 'TEXT_MESSAGE_CONTENT'].includes(event.type)) {
    requireThat(typeof event.delta === 'string', 'bad_text_delta');
    return { kind: 'text_delta', text: event.delta };
  }
  if (event.type === 'RUN_FINISHED') return { kind: 'stream_terminal', taskTerminal: false, next: 'read_task_status' };
  if (event.type === 'RUN_ERROR') return { kind: 'stream_unknown', taskTerminal: false, next: 'read_task_status' };
  if (['TOOL_CALL_START', 'TOOL_CALL_RESULT'].includes(event.type)) return { kind: 'display_only_tool', executable: false, next: 'read_proposals' };
  return { kind: 'unsupported_event', type: event.type, executable: false };
}
export function openSyntheticStream(state, threadID, aguiRunID) {
  requireThat(state.control === 'active' && threadID && aguiRunID, 'bad_stream_binding');
  return { ...state, stream: { threadID, aguiRunID, text: '', terminal: false, sawTool: false } };
}
export function applyEphemeralEvent(state, event, context) {
  assertFence(state, context);
  requireThat(state.stream && !state.stream.terminal, 'event_after_stream_terminal');
  if (event.threadId !== undefined) requireThat(event.threadId === state.stream.threadID, 'stream_thread_mismatch');
  if (event.runId !== undefined) requireThat(event.runId === state.stream.aguiRunID, 'stream_run_mismatch');
  const mapped = mapEphemeralEvent(event), stream = { ...state.stream };
  if (mapped.kind === 'text_delta') stream.text += mapped.text;
  if (mapped.kind === 'display_only_tool') stream.sawTool = true;
  if (['stream_terminal', 'stream_unknown'].includes(mapped.kind)) stream.terminal = true;
  return { ...state, stream, needsRead: state.needsRead || stream.terminal || stream.sawTool };
}
