import { TaskWorker } from '../patched-openmuse/apps/server/src/engine/worker.ts';
import { Facade } from './facade.mjs';
import { FencedWorkerStore } from './fenced-worker-store.mjs';
import { syntheticHandler } from './synthetic-handler.mjs';
import { upstreamActionsFor } from './upstream-actions.mjs';
import { syntheticAuth,iso } from './common.mjs';
export async function createRuntime({repository,authenticate=syntheticAuth,executionLayer='actual_upstream_taskworker_inprocess',beforePublish}={}) {
  let worker;
  const facade=new Facade({repository,authenticate,executionLayer,abortTask:id=>worker?.abort(id)});
  facade.actionsFor=upstreamActionsFor(facade);
  const store=new FencedWorkerStore(facade);
  // Same recovery semantics as upstream Store.recoverInterruptedActions: uncertain dispatch stays unknown.
  await repository.transaction(async tx=>{
    for(const {owner,value} of await tx.scan('actions'))if(owner.startsWith('catpaw:')&&value.status==='executing')await tx.compareAndSwap(owner,'actions',value.id,{status:'executing'},{status:'outcome_unknown',error:'Interrupted execution; reconcile original proposal',recoveredAt:iso()});
  });
  worker=new TaskWorker(store,syntheticHandler(facade,{beforePublish}));
  return {facade,worker,store,repository};
}
