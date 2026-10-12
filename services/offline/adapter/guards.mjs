// Proposed Catpaw facade invariants, NOT fields or guarantees supplied by OpenMuse.
// Pure synthetic-policy functions. No transport, executor, scheduler, credentials or dependencies.
import { createHash } from 'node:crypto';

export class ContractError extends Error {
  constructor(code) { super(code); this.code = code; }
}
export function requireThat(condition, code) { if (!condition) throw new ContractError(code); }
export function canonical(value) {
  if (value === null || ['string', 'boolean'].includes(typeof value)) return JSON.stringify(value);
  if (typeof value === 'number') { requireThat(Number.isFinite(value), 'non_json_number'); return JSON.stringify(value); }
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  requireThat(value && Object.getPrototypeOf(value) === Object.prototype, 'non_json_value');
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export const digest = value => sha256(canonical(value));
export function frozenCopy(value) {
  const copy = JSON.parse(canonical(value));
  const freeze = v => { if (v && typeof v === 'object') { Object.values(v).forEach(freeze); Object.freeze(v); } return v; };
  return freeze(copy);
}
export const sameScope = (a, b) => a?.profileID === b?.profileID && a?.workspaceID === b?.workspaceID;
export function assertScope(expected, actual) { requireThat(sameScope(expected, actual), 'scope_mismatch'); }
export function freezeDelegation(input) {
  requireThat(input.scope?.profileID && input.scope.workspaceID && input.operationID && input.businessRunID && input.environmentID, 'missing_identity');
  requireThat(input.delegationID && Number.isSafeInteger(input.delegationRevision) && input.delegationRevision > 0, 'bad_revision');
  requireThat(input.modelConfiguration?.model && input.goal?.trim() && input.stopConditions?.length, 'unfrozen_request');
  requireThat(typeof input.title === 'string' && input.title.trim() && typeof input.requirements === 'string' &&
    Array.isArray(input.sources) && input.stopConditions.every(v => typeof v === 'string' && v.trim()), 'bad_request_shape');
  requireThat(input.sources.every(s => s.allowed && Number.isSafeInteger(s.revision) && s.revision > 0), 'source_not_authorized');
  requireThat(input.grantRevision > 0 && input.contextEpoch > 0, 'bad_epoch');
  requireThat(input.schedule === null, 'schedule_unsupported_in_pilot');
  const request = frozenCopy(input);
  return frozenCopy({ schema: 'catpaw.openmuse.offline.v1', request, requestHash: digest(request) });
}
export function assertFrozen(frozen) { requireThat(frozen.requestHash === digest(frozen.request), 'frozen_request_hash_mismatch'); }

// Observation fencing belongs in an authenticated SERVER facade in a real integration.
// Here the context is a locally trusted synthetic fixture; upstream responses have no Catpaw scope/epoch.
export function newObservation(frozen) {
  assertFrozen(frozen);
  return { scope: frozen.request.scope, operationID: frozen.request.operationID, businessRunID: frozen.request.businessRunID,
    delegationRevision: frozen.request.delegationRevision, grantRevision: frozen.request.grantRevision,
    contextEpoch: frozen.request.contextEpoch, observationEpoch: 1, requestHash: frozen.requestHash,
    control: 'active', connected: true, needsRead: false, persistentTaskID: null,
    observedLeaseRunID: null, observedRunStatus: null, taskTerminal: false,
    receipt: 'not_started', reality: 'simulated', approvals: {}, artifactVersions: {}, artifactHistory: {} };
}
export function assertFence(state, context) {
  assertScope(state.scope, context.scope);
  requireThat(context.operationID === state.operationID, 'operation_mismatch');
  requireThat(context.requestHash === state.requestHash, 'request_mismatch');
  for (const key of ['observationEpoch', 'contextEpoch', 'grantRevision', 'delegationRevision'])
    requireThat(context[key] === state[key], `stale_${key}`);
  requireThat(state.control === 'active', `control_${state.control}`);
}
export const contextFor = state => frozenCopy(Object.fromEntries(
  ['scope', 'operationID', 'requestHash', 'observationEpoch', 'contextEpoch', 'grantRevision', 'delegationRevision'].map(k => [k, state[k]])));
export function disconnect(state) {
  return { ...state, connected: false, needsRead: true, observationEpoch: state.observationEpoch + 1,
    receipt: state.receipt === 'dispatch_committed' ? 'unknown' : state.receipt };
}
export function fenceControl(state, control) {
  requireThat(['paused', 'revoked', 'active'].includes(control), 'bad_control');
  // Resume never restores a former grant: caller must create a new frozen admission.
  requireThat(control !== 'active', 'resume_requires_new_admission');
  return { ...state, control, observationEpoch: state.observationEpoch + 1,
    contextEpoch: state.contextEpoch + 1, grantRevision: state.grantRevision + 1, needsRead: true };
}

export function artifactVersion(previous, artifact) {
  requireThat(typeof artifact.id === 'string' && artifact.id && artifact.taskId &&
    ['plan', 'comparison', 'finance', 'report'].includes(artifact.kind) &&
    typeof artifact.title === 'string' && typeof artifact.summary === 'string' &&
    artifact.data && !Array.isArray(artifact.data), 'bad_artifact');
  // Codec is explicitly local. No invented upstream revision/hash or evidence claim.
  const body = canonical({ codec: 'catpaw-artifact-v1', id: artifact.id, taskId: artifact.taskId,
    title: artifact.title, kind: artifact.kind, summary: artifact.summary, data: artifact.data });
  const hash = sha256(body);
  if (previous?.contentHash === hash) return previous;
  return frozenCopy({ artifactID: artifact.id, version: (previous?.version ?? 0) + 1,
    contentHash: hash, codec: 'catpaw-artifact-v1', body });
}
export function freezeApproval(input) {
  requireThat(input.proposalID && input.operationID && input.taskID && input.runID, 'missing_approval_identity');
  requireThat(input.artifact?.contentHash && input.artifact.version > 0 && input.target && input.toolVersion, 'unfrozen_approval');
  const envelope = frozenCopy(input);
  return frozenCopy({ envelope, actionDigest: digest(envelope), status: 'pending', receipt: 'not_started' });
}
export function validateApproval(state, approval, current, now) {
  requireThat(approval.actionDigest === digest(approval.envelope), 'action_digest_mismatch');
  const e = approval.envelope;
  assertFence(state, { ...contextFor(state), scope: e.scope, operationID: e.operationID,
    requestHash: e.requestHash,
    grantRevision: e.grantRevision, delegationRevision: e.delegationRevision, contextEpoch: e.contextEpoch });
  requireThat(e.taskID === state.persistentTaskID && e.runID === state.businessRunID, 'approval_run_mismatch');
  requireThat(approval.status === 'pending' && approval.receipt === 'not_started', 'approval_consumed_or_unknown');
  requireThat(now < e.expiresAt, 'approval_expired');
  requireThat(state.artifactVersions[e.artifact.artifactID] &&
    canonical(e.artifact) === canonical(state.artifactVersions[e.artifact.artifactID]), 'stale_artifact_version');
  requireThat(canonical(e.artifact) === canonical(current.artifact), 'stale_artifact_version');
  requireThat(e.target === current.target && digest(e.arguments) === digest(current.arguments), 'action_changed');
  requireThat(e.toolVersion === current.toolVersion && e.policyVersion === current.policyVersion, 'policy_changed');
  return true;
}
export function commitApproval(approval) {
  requireThat(approval.status === 'pending' && approval.receipt === 'not_started', 'approval_consumed_or_unknown');
  return frozenCopy({ ...approval, status: 'consumed', receipt: 'dispatch_committed' });
}
export function approvalReceipt(approval, outcome) {
  requireThat(approval.receipt === 'dispatch_committed', 'receipt_without_dispatch');
  // Classify the returned proposal; HTTP 200 alone is not independent side-effect verification.
  requireThat(['accepted', 'unknown'].includes(outcome), 'unverified_receipt');
  return frozenCopy({ ...approval, receipt: outcome });
}

// Proposed A2UI bridge only; exact local whitelist schema, no renderer/UI dependency.
export function validateCard(card) {
  requireThat(card && ['status', 'artifact_reference', 'approval_reference'].includes(card.kind), 'card_not_whitelisted');
  const allowed = { status: ['schema', 'kind', 'label'], artifact_reference: ['schema', 'kind', 'artifactID', 'version', 'contentHash'],
    approval_reference: ['schema', 'kind', 'proposalID', 'actionDigest'] }[card.kind];
  requireThat(card.schema === 'catpaw.card.v1' && Object.keys(card).every(k => allowed.includes(k)) && allowed.every(k => k in card), 'bad_card_schema');
  if (card.kind === 'status') requireThat(typeof card.label === 'string' && card.label.length <= 1000, 'bad_card_schema');
  if (card.kind === 'artifact_reference') requireThat(typeof card.artifactID === 'string' && Number.isSafeInteger(card.version) && card.version > 0 && /^[a-f0-9]{64}$/.test(card.contentHash), 'bad_card_schema');
  if (card.kind === 'approval_reference') requireThat(typeof card.proposalID === 'string' && /^[a-f0-9]{64}$/.test(card.actionDigest), 'bad_card_schema');
  return frozenCopy(card);
}
