import { mkdirSync, readFileSync, writeFileSync, openSync, closeSync, fsyncSync, renameSync, rmSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { clone, fail } from './models.mjs';

const empty = () => ({schema_version:1, sequence:0, delegations:{}, runs:{}, sources:{}, memories:{},
  suppressions:{}, artifacts:{}, approvals:{}, idempotency:{}, outbox:[]});

// Development single-host store. Short synchronous transactions + interprocess lock,
// atomic replacement and fsync; external I/O is always outside the transaction.
// A dead PID's lock can be recovered. A live or unverifiable owner fails closed.
export class DurableStore {
  constructor(path) {this.path=path; this.lock=`${path}.lock`; this.recovery=`${path}.recovery`; mkdirSync(dirname(path),{recursive:true});}
  recoverDeadOwner() {
    try {mkdirSync(this.recovery);} catch {throw fail('store_locked');}
    try {
      let pid; try {pid=JSON.parse(readFileSync(`${this.lock}/owner.json`)).pid;} catch {throw fail('store_locked');}
      if(!Number.isInteger(pid)||pid<1) throw fail('store_locked');
      try {process.kill(pid,0); throw fail('store_locked');}
      catch(probe) {if(probe.code!=='ESRCH') throw fail('store_locked');}
      const quarantine=`${this.lock}.dead.${randomUUID()}`;
      renameSync(this.lock,quarantine); rmSync(quarantine,{recursive:true});
    } finally {rmSync(this.recovery,{recursive:true});}
  }
  acquire() {
    for (let attempt=0;attempt<2;attempt++) {
      if(existsSync(this.recovery)) throw fail('store_locked');
      try {
        mkdirSync(this.lock);
        // Close the acquire/recovery race before entering a transaction.
        if(existsSync(this.recovery)) {rmSync(this.lock,{recursive:true});throw fail('store_locked');}
        writeFileSync(`${this.lock}/owner.json`,JSON.stringify({pid:process.pid}),{mode:0o600}); return;
      }
      catch(error) {
        if(error.code!=='EEXIST') throw error;
        this.recoverDeadOwner();
      }
    }
    throw fail('store_locked');
  }
  load() {
    if(!existsSync(this.path)) return empty();
    const state=JSON.parse(readFileSync(this.path,'utf8'));
    if(state.schema_version!==1 || !Number.isSafeInteger(state.sequence)) throw fail('store_corrupt');
    return state;
  }
  read() {return clone(this.load());}
  transact(fn) {
    this.acquire(); let temporary;
    try {
      const state=this.load(); const result=fn(state);
      if(result && typeof result.then==='function') throw fail('async_transaction_forbidden');
      state.sequence++;
      temporary=`${this.path}.${randomUUID()}.tmp`;
      const fd=openSync(temporary,'wx',0o600);
      try {writeFileSync(fd,JSON.stringify(state)); fsyncSync(fd);} finally {closeSync(fd);}
      renameSync(temporary,this.path); temporary=null;
      const dir=openSync(dirname(this.path),'r'); try {fsyncSync(dir);} finally {closeSync(dir);}
      return clone(result ?? null);
    } finally {if(temporary) rmSync(temporary,{force:true}); rmSync(this.lock,{recursive:true});}
  }
}
