import {LostLeaseError} from '../integration/edge-adapter/vendor/openmuse/runtime/engine/worker.mjs';
import {hash} from '../facade-r2/src/common.mjs';
import {taskControlRevision} from './task-control-contract.mjs';

/** One execution identity for both maintained worker ports. A running presentation,
 * matching task ID, or unchanged grant alone does not confer an executor lease. */
export function captureTaskExecutionFence(task) {
  return {revision:taskControlRevision(task),authority_hash:hash(task.state.catpaw)};
}
export function assertTaskExecutionFence(task,leaseId,now,fence) {
  const current=captureTaskExecutionFence(task);
  if(task.status!=='running'||task.leaseId!==leaseId||!(Date.parse(task.leaseUntil)>now)||
    fence?.authority_hash!==current.authority_hash||fence?.revision!==current.revision)throw new LostLeaseError();
}

// Authority withdrawal is an expected selection/settlement fence, not a worker
// failure to retry. Corrupt bindings and unknown errors deliberately stay visible.
const authorityFenceCodes=new Set(['grant_conflict','scope_forbidden','lease_lost','operation_conflict','unmanaged_task','memory_generation_conflict','memory_generation_superseded','memory_fenced','work_grant_generation_conflict','work_grant_expired','work_grant_not_active','work_grant_revision_superseded','work_grant_authority_denied','accepted_work_grant_conflict','revision_source_not_current','provider_consent_required','session_revoked']);
export function isTaskExecutionAuthorityFence(error){return error instanceof LostLeaseError||authorityFenceCodes.has(error?.code);}
