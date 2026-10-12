// Port used by the REAL pinned TaskWorker. No poller, queue or second engine here.
import { ApiError,check,iso } from './common.mjs';
import { LostLeaseError } from '../patched-openmuse/apps/server/src/engine/worker.ts';
export class FencedWorkerStore {
  constructor(facade) { this.facade=facade;this.repository=facade.repository; }
  get(owner,kind,id) { return this.repository.transaction(tx=>tx.get(owner,kind,id)); }
  list(owner,kind) { return this.repository.transaction(tx=>tx.list(owner,kind)); }
  scan(kind) { return this.repository.transaction(async tx=>(await tx.scan(kind)).filter(r=>kind!=='tasks'||(r.owner.startsWith('catpaw:')&&r.value.state?.catpaw))); }
  async compareAndSwap(owner,kind,id,expected,patch) {
    return this.repository.transaction(async tx=>{
      if(kind==='tasks'){
        try { await this.facade.admittedTask(tx,owner,id); } catch(e) { if(e instanceof ApiError)return null;throw e; }
      }
      const result=await tx.compareAndSwap(owner,kind,id,expected,patch);
      // Persist worker lease -> stable business run association atomically with claim.
      if(result&&kind==='tasks'&&patch.status==='running'&&patch.leaseId){
        const run=await tx.get(owner,'catpaw-runs',result.state.catpaw.run_id);
        const previous=(await tx.list(owner,'runs')).filter(r=>r.taskId===id&&r.status==='running'&&r.id!==patch.leaseId);
        for(const r of previous)await tx.compareAndSwap(owner,'runs',r.id,{status:'running'},{status:'interrupted',finishedAt:iso(),recoveryReason:'superseded_lease'});
        await tx.insertIfAbsent(owner,'runs',{id:patch.leaseId,taskId:id,startedAt:iso(),status:'running'});
        await tx.insertIfAbsent(owner,'catpaw-run-links',{id:patch.leaseId,run_id:run.id,operation_id:run.operation_id,task_id:id,grant_epoch:run.grant_epoch});
      }
      return result;
    });
  }
  async put(owner,kind,value) {
    return this.repository.transaction(async tx=>{
      if(kind==='run-events'){
        try {
          const {task}=await this.facade.admittedTask(tx,owner,value.taskId,{running:true});
          check(value.leaseId&&value.leaseId===task.leaseId,409,'lease_lost');
        } catch(error) {
          if(error instanceof ApiError&&['lease_lost','grant_conflict'].includes(error.code))throw new LostLeaseError();
          throw error;
        }
      }
      if(kind==='agent-artifacts')throw new ApiError(409,'immutable_artifact_writer_required');
      if(kind==='runs'){
        const link=await tx.get(owner,'catpaw-run-links',value.id);check(link?.task_id===value.taskId,409,'run_conflict');
        const task=await tx.get(owner,'tasks',value.taskId),d=await this.facade.delegation(tx,owner,task.state.catpaw.delegation_id,{lock:true});
        if(value.status==='succeeded'&&(d.grant_epoch!==link.grant_epoch||d.state!=='active'))value={...value,status:'interrupted',finishedAt:iso()};
      }
      return tx.put(owner,kind,value);
    });
  }
}
