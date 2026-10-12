import { randomUUID } from 'node:crypto';
import { Facade } from '../src/facade.mjs';
import { MemoryRepository } from '../src/memory-repository.mjs';
import { FencedWorkerStore } from '../src/fenced-worker-store.mjs';
import { syntheticHandler } from '../src/synthetic-handler.mjs';
import { syntheticAuth,SYNTHETIC_SCOPE } from '../src/common.mjs';
import { upstreamActionsFor } from '../src/upstream-actions.mjs';
import { TaskWorker } from '../patched-openmuse/apps/server/src/engine/worker.ts';
export const auth='Bearer synthetic-only',scope=SYNTHETIC_SCOPE.scope_id;
export function input(fixture='report') { return {delegation_id:randomUUID(),title:'Synthetic comparison',goal:'Compare fixed Alpha and Beta records',requirements:'Use fixed synthetic data',stop_conditions:['Stop after one report'],synthetic_fixture_id:fixture}; }
export function admission() { return {operation_id:randomUUID(),run_id:randomUUID(),expected_revision:1,expected_grant_epoch:1}; }
export function harness({repository=new MemoryRepository(),authenticate=syntheticAuth,beforePublish}={}) {
  let worker;
  const facade=new Facade({repository,authenticate,executionLayer:'actual_upstream_taskworker_inprocess',abortTask:id=>worker?.abort(id)});
  facade.actionsFor=upstreamActionsFor(facade); // Pinned upstream ActionService + explicit local-preview patch.
  const store=new FencedWorkerStore(facade);
  worker=new TaskWorker(store,syntheticHandler(facade,{beforePublish}),{leaseMs:60000});
  return {facade,repository,store,worker,owner:facade.owner(SYNTHETIC_SCOPE)};
}
export async function admitted(h,fixture='report') { const d=input(fixture),a=admission();await h.facade.createDelegation(auth,scope,d);const r=await h.facade.createRun(auth,scope,d.delegation_id,a);return {d,a,r}; }
export function decision(a) { return {decision:'approve',upstream_hash:a.upstream_hash,action_digest:a.action_digest,expected_grant_epoch:a.grant_epoch}; }
export function deferred() { let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve}; }
