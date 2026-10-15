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
