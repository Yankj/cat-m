// Own dependency-free runner for Node 18+. Only local synthetic JSON and pure functions.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { canonical, sha256, digest, freezeDelegation, newObservation, contextFor, disconnect,
  fenceControl, artifactVersion, freezeApproval, validateApproval, approvalReceipt, validateCard } from '../adapter/guards.mjs';
import { SUPPORT, nativeID, taskCreateDescriptor, predictedTaskID, recoveryPlan, bindCreatedTask,
  applyTaskDetail, applyFacadeRun, decisionDescriptor, mapProposalReceipt, SyntheticSSEDecoder,
  mapEphemeralEvent, openSyntheticStream, applyEphemeralEvent, controlDescriptor } from '../adapter/openmuse.mjs';
const readJSON = async path => JSON.parse(await readFile(new URL(path, import.meta.url), 'utf8'));
const f = await readJSON('../fixtures/scenario.json'), facade = await readJSON('../fixtures/facade-run.json');
const tests = [], trace = [];
const test = (name, fn) => tests.push({ name, fn });
const errorIs = code => error => error.code === code;
const copy = value => JSON.parse(JSON.stringify(value));
const frozen = freezeDelegation(f.request);
const admitted = bindCreatedTask(newObservation(frozen), frozen, f.taskCreated);
const running = applyTaskDetail(admitted, f.detailRunning, contextFor(admitted), 1);
const v1 = applyTaskDetail(running, f.detailV1, contextFor(running), 2);
const v2 = applyTaskDetail(v1, f.detailV2, contextFor(v1), 3);
const artifactID = f.detailV1.artifacts[0].id;
const now = Date.parse('2026-10-11T13:01:00.000Z');
function makeApproval(state, proposal, artifact) {
  return freezeApproval({ proposalID: proposal.id, upstreamHash: proposal.hash,
    scope: state.scope, operationID: state.operationID, requestHash: state.requestHash,
    delegationRevision: state.delegationRevision, grantRevision: state.grantRevision, contextEpoch: state.contextEpoch,
    taskID: state.persistentTaskID, runID: state.businessRunID, toolID: proposal.kind, toolVersion: 'synthetic.tool.v1',
    actorAccountID: proposal.account, connectionID: proposal.connectionId, target: proposal.data.eventId,
    targetVersion: proposal.targetVersion ?? null, arguments: proposal.data, artifact,
    policyVersion: 'synthetic.policy.v1', expiresAt: Date.parse(proposal.expiresAt), idempotencyKey: `synthetic:${proposal.id}` });
}
const a1 = makeApproval(v1, f.proposalV1, v1.artifactVersions[artifactID]);
const a2 = makeApproval(v2, f.proposalV2, v2.artifactVersions[artifactID]);
const current = approval => ({ artifact: approval.envelope.artifact, target: approval.envelope.target,
  arguments: approval.envelope.arguments, toolVersion: approval.envelope.toolVersion, policyVersion: approval.envelope.policyVersion });

test('SHA256 known vector and stable canonical Unicode JSON', () => {
  assert.equal(sha256('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert.equal(canonical({ z: '猫', a: [1, true, null] }), '{"a":[1,true,null],"z":"猫"}');
  assert.throws(() => canonical({ bad: undefined }), errorIs('non_json_value'));
});
test('frozen request matches independently generated golden hash and resists caller edits', () => {
  const input = copy(f.request), saved = freezeDelegation(input); input.goal = 'changed'; input.modelConfiguration.model = 'changed';
  assert.equal(saved.requestHash, f.golden.requestHash); assert.equal(saved.request.goal, f.request.goal);
  assert.throws(() => { saved.request.sources[0].url = 'changed'; }, TypeError);
  assert.equal(predictedTaskID(saved), f.golden.taskID);
});
test('wire create uses exact source keys; no invented model/scope/run fields', () => {
  const d = taskCreateDescriptor(frozen);
  assert.equal(d.path, '/api/agent/tasks'); assert.equal(d.method, 'POST');
  assert.deepEqual(Object.keys(d.body).sort(), ['input', 'kind', 'prompt', 'requestId', 'title']);
  assert.equal(d.body.prompt, f.taskCreated.prompt); assert.deepEqual(d.body.input, {});
});
test('requestId changes for model, source revision, scope, grant and delegation revision', () => {
  for (const edit of [r => r.modelConfiguration.model = 'changed', r => r.sources[0].revision++,
    r => r.scope.workspaceID = 'other', r => r.grantRevision++, r => r.delegationRevision++]) {
    const input = copy(f.request); edit(input);
    assert.notEqual(taskCreateDescriptor(freezeDelegation(input)).body.requestId, taskCreateDescriptor(frozen).body.requestId);
  }
});
test('tampered frozen request, ungranted source and autonomous schedule rejected', () => {
  const bad = copy(frozen); bad.request.goal += '!';
  assert.throws(() => taskCreateDescriptor(bad), errorIs('frozen_request_hash_mismatch'));
  assert.throws(() => freezeDelegation({ ...f.request, sources: [{ ...f.request.sources[0], allowed: false }] }), errorIs('source_not_authorized'));
  assert.throws(() => freezeDelegation({ ...f.request, schedule: { cadence: 'daily' } }), errorIs('schedule_unsupported_in_pilot'));
});
test('64-hex provider ID maps to scoped Catpaw UUID without replacing raw ID', () => {
  assert.match(nativeID(f.request.scope, 'task', f.golden.taskID), /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-8[a-f0-9]{3}-[a-f0-9]{12}$/);
  assert.notEqual(nativeID(f.request.scope, 'task', f.golden.taskID), nativeID({ ...f.request.scope, profileID: 'other' }, 'task', f.golden.taskID));
});
test('create response id and frozen prompt are checked', () => {
  assert.equal(admitted.persistentTaskID, f.golden.taskID);
  assert.throws(() => bindCreatedTask(newObservation(frozen), frozen, { ...f.taskCreated, id: 'other' }), errorIs('created_task_id_mismatch'));
  assert.throws(() => bindCreatedTask(newObservation(frozen), frozen, { ...f.taskCreated, prompt: 'changed' }), errorIs('created_task_prompt_mismatch'));
});
test('PUBLIC API SHAPE: stable Catpaw Run/task link survives App close; task GET restores status only', async () => {
  const closed = disconnect(running);
  await writeFile(new URL('../evidence/synthetic-ledger.json', import.meta.url), JSON.stringify(closed, null, 2) + '\n');
  const restored = await readJSON('../evidence/synthetic-ledger.json');
  assert.equal(restored.observedLeaseRunID, facade.run.id);
  assert.equal(restored.businessRunID, f.request.businessRunID); assert.equal(restored.runRecord, undefined);
  assert.equal(restored.observedRunStatus, 'running'); // App close did not cancel the server task.
  const plan = recoveryPlan(restored, frozen);
  assert.deepEqual(plan.requests.map(x => [x.method, x.path]), [['GET', `/api/agent/tasks/${f.golden.taskID}`]]);
  assert.equal(plan.resubmitCreate, false); assert.equal(plan.resubmitDecision, false); assert.equal(plan.reattachSSE, false);
  const readback = applyTaskDetail(restored, f.detailV1, contextFor(restored), 2);
  assert.equal(readback.artifactVersions[artifactID].version, 1);
  const done = applyTaskDetail(readback, f.detailTerminal, contextFor(readback), 3);
  assert.equal(f.detailTerminal.task.leaseId, null);
  assert.equal(done.observedLeaseRunID, restored.observedLeaseRunID); assert.equal(done.businessRunID, restored.businessRunID);
  assert.equal(done.workState, 'succeeded'); assert.equal(done.runRecord, undefined);
  trace.push({ step: 'source-shaped create -> stable business Run/task association -> App close -> task GET status/artifact read',
    businessRunID: done.businessRunID, operationID: done.operationID, taskID: done.persistentTaskID,
    previouslyObservedLeaseID: done.observedLeaseRunID, currentPublicLeaseID: f.detailTerminal.task.leaseId,
    reality: done.reality, runRead: 'unsupported_public_api', requests: plan.requests });
});
test('PUBLIC API GAP: close before observing a lease cannot reconstruct any upstream Run ID', () => {
  const closed = disconnect(admitted);
  const done = applyTaskDetail(closed, f.detailTerminal, contextFor(closed), 1);
  assert.equal(done.observedLeaseRunID, null); assert.equal(done.runRecord, undefined);
  assert.equal(done.businessRunID, f.request.businessRunID); assert.equal(done.workState, 'succeeded');
});
test('PROPOSED FACADE ONLY: private Run row codec requires stable business/operation/hash association', () => {
  const hypothetical = applyFacadeRun(running, facade, contextFor(running));
  assert.equal(hypothetical.runReadEvidence, 'synthetic_facade_only');
  assert.equal(hypothetical.businessRunID, running.businessRunID);
  assert.throws(() => applyFacadeRun(running, { ...facade, businessRunID: 'wrong' }, contextFor(running)), errorIs('facade_run_binding_mismatch'));
});
test('lost create response reconciles predicted task ID; 404 does not silently POST', () => {
  const plan = recoveryPlan(disconnect(newObservation(frozen)), frozen);
  assert.equal(plan.requests[0].path, `/api/agent/tasks/${f.golden.taskID}`);
  assert.equal(plan.resubmitCreate, false); assert.match(plan.on404, /explicit_reconciliation/);
});
test('Run history HTTP and Last-Event-ID replay remain explicitly unsupported', () => {
  assert.equal(SUPPORT.publicRunHistoryRead, false); assert.equal(SUPPORT.lastEventIDReplay, false);
  assert.equal(SUPPORT.taskSSE, false); assert.equal(SUPPORT.scopeEnforcedByUpstream, false);
  assert.throws(() => applyFacadeRun(running, { run: facade.run }, contextFor(running)), errorIs('run_read_api_unsupported'));
});
test('cross-profile, operation, task and payload relationships are isolated', () => {
  assert.throws(() => applyTaskDetail(running, f.detailV1, { ...contextFor(running), scope: { ...running.scope, profileID: 'other' } }, 2), errorIs('scope_mismatch'));
  assert.throws(() => applyTaskDetail(running, f.detailV1, { ...contextFor(running), operationID: 'other' }, 2), errorIs('operation_mismatch'));
  assert.throws(() => applyTaskDetail(running, { ...f.detailV1, task: { ...f.detailV1.task, id: 'other' } }, contextFor(running), 2), errorIs('task_mismatch'));
  assert.throws(() => applyTaskDetail(running, { ...f.detailV1, artifacts: [{ ...f.detailV1.artifacts[0], taskId: 'other' }] }, contextFor(running), 2), errorIs('cross_task_payload'));
});
test('stale generation, timestamp conflict and successor lease require reconciliation', () => {
  assert.throws(() => applyTaskDetail(v2, f.detailV1, contextFor(v2), 4), errorIs('stale_task_snapshot'));
  assert.throws(() => applyTaskDetail(v1, f.detailV1, contextFor(v1), 2), errorIs('stale_read'));
  assert.throws(() => applyTaskDetail(v1, { ...f.detailV1, task: { ...f.detailV1.task, result: 'changed' } }, contextFor(v1), 3), errorIs('same_timestamp_conflict'));
  assert.throws(() => applyTaskDetail(running, { ...f.detailRunning, task: { ...f.detailRunning.task, updatedAt: '2026-10-11T13:00:11.000Z', leaseId: 'successor-lease' } }, contextFor(running), 2), errorIs('successor_run_requires_rebind'));
  assert.throws(() => applyTaskDetail(running, { ...f.detailTerminal, task: { ...f.detailTerminal.task, attempts: 2 } }, contextFor(running), 2), errorIs('successor_attempt_requires_rebind'));
});
test('artifact versions hash content, preserve old body and do not bump for createdAt', () => {
  assert.equal(v2.artifactVersions[artifactID].version, 2);
  assert.notEqual(v1.artifactVersions[artifactID].contentHash, v2.artifactVersions[artifactID].contentHash);
  assert.equal(v2.artifactHistory[artifactID][0].body, v1.artifactVersions[artifactID].body);
  const same = artifactVersion(v2.artifactVersions[artifactID], { ...f.detailV2.artifacts[0], createdAt: '2030-01-01T00:00:00Z' });
  assert.equal(same, v2.artifactVersions[artifactID]);
  assert.equal(sha256(same.body), same.contentHash);
});
test('duplicate artifacts and unknown task status never publish partial projections', () => {
  assert.throws(() => applyTaskDetail(running, { ...f.detailV1, artifacts: [...f.detailV1.artifacts, ...f.detailV1.artifacts] }, contextFor(running), 2), errorIs('duplicate_artifact'));
  assert.throws(() => applyTaskDetail(running, { ...f.detailV1, task: { ...f.detailV1.task, status: 'new_upstream_status' } }, contextFor(running), 2), errorIs('unsupported_task_status'));
  assert.deepEqual(running.artifactVersions, {});
});
test('old approval rejected after artifact version changes', () => {
  assert.throws(() => validateApproval(v2, a1, { ...current(a1), artifact: v2.artifactVersions[artifactID] }, now), errorIs('stale_artifact_version'));
  assert.throws(() => validateApproval(v2, a1, current(a1), now), errorIs('stale_artifact_version')); // stale caller cannot override persisted current version.
});
test('approval binds frozen request, target, args, policy, connection and upstream hash', () => {
  assert.notEqual(a2.actionDigest, f.proposalV2.hash);
  const tampered = copy(a2); tampered.envelope.target = 'other';
  assert.throws(() => validateApproval(v2, tampered, current(a2), now), errorIs('action_digest_mismatch'));
  assert.throws(() => validateApproval(v2, a2, { ...current(a2), target: 'other' }, now), errorIs('action_changed'));
  assert.throws(() => validateApproval(v2, a2, { ...current(a2), policyVersion: 'other' }, now), errorIs('policy_changed'));
  assert.throws(() => decisionDescriptor(v2, a2, { ...f.proposalV2, hash: 'changed' }, current(a2), now, 'approve'), errorIs('proposal_changed'));
  assert.throws(() => decisionDescriptor(v2, a2, { ...f.proposalV2, connectionId: 'changed' }, current(a2), now, 'approve'), errorIs('proposal_binding_mismatch'));
});
test('new approval builds exact inert response request, then unknown receipt forbids duplicate', () => {
  const { request, nextApproval } = decisionDescriptor(v2, a2, f.proposalV2, current(a2), now, 'approve');
  assert.deepEqual(request, { method: 'POST', path: '/api/actions/synthetic-proposal-v2/decide', body: { hash: f.proposalV2.hash, decision: 'approve' } });
  const unknown = approvalReceipt(nextApproval, 'unknown');
  assert.equal(unknown.status, 'consumed'); assert.equal(unknown.receipt, 'unknown');
  assert.throws(() => decisionDescriptor(v2, unknown, f.proposalV2, current(a2), now, 'approve'), errorIs('approval_consumed_or_unknown'));
  assert.equal(mapProposalReceipt(f.proposalUnknown, f.proposalV2.id).receipt, 'unknown');
  trace.push({ step: 'artifact v1 -> v2 -> old approval rejected -> new decision descriptor -> unknown receipt',
    versions: v2.artifactHistory[artifactID].map(({ version, contentHash }) => ({ version, contentHash })),
    request, receipt: unknown.receipt, reality: 'simulated', externalRequestsSent: 0 });
});
test('expired or changed request approvals rejected; 200/succeeded is not verified', () => {
  assert.throws(() => validateApproval(v2, a2, current(a2), a2.envelope.expiresAt), errorIs('approval_expired'));
  const changed = freezeApproval({ ...a2.envelope, requestHash: 'other' });
  assert.throws(() => validateApproval(v2, changed, current(a2), now), errorIs('request_mismatch'));
  const receipt = mapProposalReceipt(f.proposalSucceeded, f.proposalV2.id);
  assert.equal(receipt.receipt, 'accepted'); assert.equal(receipt.verified, false);
  for (const status of ['failed', 'cancelled']) assert.equal(mapProposalReceipt({ ...f.proposalSucceeded, status }, f.proposalV2.id).receipt, 'unknown');
  assert.throws(() => mapProposalReceipt({ ...f.proposalSucceeded, status: 'mystery' }, f.proposalV2.id), errorIs('unsupported_action_status'));
});
test('pause/revoke fences late artifacts and approvals; resume cannot restore old grant', () => {
  for (const control of ['paused', 'revoked']) {
    const blocked = fenceControl(v2, control);
    assert.throws(() => applyTaskDetail(blocked, f.detailTerminal, contextFor(v2), 4), errorIs('stale_observationEpoch'));
    assert.throws(() => validateApproval(blocked, a2, current(a2), now), errorIs('stale_contextEpoch'));
    assert.equal(recoveryPlan(blocked, frozen).resubmitDecision, false);
    assert.throws(() => fenceControl(blocked, 'active'), errorIs('resume_requires_new_admission'));
  }
});
test('disconnect drops late events from old observation, never cancels cloud task', () => {
  const closed = disconnect(running);
  assert.throws(() => applyTaskDetail(closed, f.detailV1, contextFor(running), 2), errorIs('stale_observationEpoch'));
  assert.equal(closed.control, 'active'); assert.equal(closed.observedRunStatus, 'running');
});
test('persistent task terminal prevents later nonterminal or successor events', () => {
  const done = applyTaskDetail(v2, f.detailTerminal, contextFor(v2), 4);
  assert.equal(done.workState, 'succeeded'); assert.equal(done.taskTerminal, true);
  assert.throws(() => applyTaskDetail(done, { ...f.detailTerminal, task: { ...f.detailTerminal.task, status: 'running', updatedAt: '2026-10-11T13:01:00.000Z' } }, contextFor(done), 5), errorIs('event_after_terminal'));
});
test('SSE handles every UTF8 byte split, comments, id and CRLF without replay assumptions', () => {
  const expected = [{ type: 'TEXT_MESSAGE_CONTENT', messageId: 'synthetic-message', delta: '猫🐾' }, { type: 'RUN_FINISHED', runId: 'synthetic-agui-run', threadId: 'synthetic-thread' }];
  const bytes = Buffer.from(`:heartbeat\r\nid:ignored\r\ndata: ${JSON.stringify(expected[0])}\r\n\r\ndata: ${JSON.stringify(expected[1])}\r\n\r\n`);
  const d = new SyntheticSSEDecoder(), actual = [];
  for (const byte of bytes) actual.push(...d.feed(Buffer.from([byte])));
  d.finish(); assert.deepEqual(actual, expected);
});
test('truncated SSE, malformed UTF8 and oversized frame rejected', () => {
  const d = new SyntheticSSEDecoder(); d.feed(Buffer.from('data: {"type":"RUN_FINISHED"}\n'));
  assert.throws(() => d.finish(), errorIs('truncated_sse_frame'));
  assert.throws(() => new SyntheticSSEDecoder().feed(Buffer.from([0xff])), TypeError);
  assert.throws(() => new SyntheticSSEDecoder().feed(Buffer.alloc(1048577, 65)), errorIs('sse_frame_limit'));
});
test('AG-UI runId stays distinct from persistent lease, and terminal only ends model stream', () => {
  let stream = openSyntheticStream(running, 'synthetic-thread', 'synthetic-agui-run');
  stream = applyEphemeralEvent(stream, { type: 'TEXT_MESSAGE_CONTENT', delta: '猫' }, contextFor(stream));
  stream = applyEphemeralEvent(stream, { type: 'RUN_FINISHED', threadId: 'synthetic-thread', runId: 'synthetic-agui-run' }, contextFor(stream));
  assert.equal(stream.stream.terminal, true); assert.equal(stream.taskTerminal, false);
  assert.equal(stream.observedLeaseRunID, facade.run.id); assert.notEqual(stream.stream.aguiRunID, stream.observedLeaseRunID);
  assert.throws(() => applyEphemeralEvent(stream, { type: 'TEXT_MESSAGE_CONTENT', delta: 'late' }, contextFor(stream)), errorIs('event_after_stream_terminal'));
});
test('tool/unknown events are nonexecutable; stream errors trigger status read', () => {
  assert.equal(mapEphemeralEvent({ type: 'TOOL_CALL_START' }).executable, false);
  assert.equal(mapEphemeralEvent({ type: 'FUTURE_EXTERNAL_WRITE' }).executable, false);
  assert.equal(mapEphemeralEvent({ type: 'RUN_ERROR', message: 'synthetic' }).next, 'read_task_status');
  const stream = openSyntheticStream(running, 'synthetic-thread', 'synthetic-agui-run');
  assert.throws(() => applyEphemeralEvent(stream, { type: 'RUN_FINISHED', runId: 'other' }, contextFor(stream)), errorIs('stream_run_mismatch'));
});
test('A2UI reservation permits reference cards and rejects script/tool expansion', () => {
  assert.equal(validateCard({ schema: 'catpaw.card.v1', kind: 'status', label: '合成状态' }).label, '合成状态');
  assert.throws(() => validateCard({ schema: 'catpaw.card.v1', kind: 'status', label: 'x', onClick: 'execute()' }), errorIs('bad_card_schema'));
  assert.throws(() => validateCard({ schema: 'catpaw.card.v1', kind: 'webview', html: '<script>' }), errorIs('card_not_whitelisted'));
});
test('control descriptor validates actual source enum and encodes no local cancel inference', () => {
  assert.deepEqual(controlDescriptor(f.golden.taskID, 'pause').body, { action: 'pause' });
  assert.throws(() => controlDescriptor(f.golden.taskID, 'revoke'), errorIs('unsupported_control'));
});

let failed = 0;
console.log('OFFLINE SYNTHETIC CONTRACT TESTS — no upstream runtime, HTTP, credentials or model calls');
for (const { name, fn } of tests) {
  try { await fn(); console.log(`PASS ${name}`); }
  catch (error) { failed++; console.log(`FAIL ${name}\n${error.stack}`); }
}
await writeFile(new URL('../evidence/lifecycle-trace.json', import.meta.url), JSON.stringify({ syntheticOnly: true, tests: tests.length,
  passed: tests.length - failed, failed, externalRequestsSentByTests: 0, trace }, null, 2) + '\n');
console.log(`RESULT tests=${tests.length} pass=${tests.length - failed} fail=${failed} external_requests=0 upstream_runtime_executed=false`);
process.exitCode = failed ? 1 : 0;
