// Explicit TEST/loopback-only repository; this is not SQL durability evidence.
import { clone } from './common.mjs';
export class MemoryRepository {
  constructor(rows=[]) { this.rows=new Map(rows);this.queue=Promise.resolve();this.layer='inprocess_memory'; }
  async transaction(fn) {
    let release;const next=new Promise(r=>release=r), prior=this.queue;this.queue=prior.then(()=>next);await prior;
    const working=new Map([...this.rows].map(([k,v])=>[k,clone(v)]));
    const tx=new MemoryTransaction(working);
    try { const result=await fn(tx);await this.prepareCommit(working);this.rows=working;return result; } finally { release(); }
  }
  async prepareCommit() {}
  snapshot() { return clone([...this.rows]); }
}
class MemoryTransaction {
  constructor(rows) { this.rows=rows; }
  key(owner,kind,id) { return JSON.stringify([owner,kind,id]); }
  async lock() {} // transaction serialization models locks; NOT a PostgreSQL test.
  async get(owner,kind,id) { const v=this.rows.get(this.key(owner,kind,id));return v===undefined?null:clone(v); }
  async list(owner,kind) { return [...this.rows].filter(([k])=>{const [o,t]=JSON.parse(k);return o===owner&&t===kind;}).map(([,v])=>clone(v)); }
  async scan(kind) { return [...this.rows].filter(([k])=>JSON.parse(k)[1]===kind).map(([k,v])=>({owner:JSON.parse(k)[0],value:clone(v)})); }
  async put(owner,kind,value) { this.rows.set(this.key(owner,kind,value.id),clone(value));return clone(value); }
  async insertIfAbsent(owner,kind,value) { if(await this.get(owner,kind,value.id))return null;return this.put(owner,kind,value); }
  async compareAndSwap(owner,kind,id,expected,patch) {
    const previous=await this.get(owner,kind,id);
    if(!previous||!Object.entries(expected).every(([k,v])=>JSON.stringify(previous[k])===JSON.stringify(v)))return null;
    return this.put(owner,kind,{...previous,...clone(patch)});
  }
  async claim(owner,id,status,now) {
    const a=await this.get(owner,'actions',id);if(!a||a.status!=='awaiting_review'||Date.parse(a.expiresAt)<=Date.parse(now))return null;
    if(status==='executing'&&a.taskId){const task=await this.get(owner,'tasks',a.taskId);if(!task||!['running','waiting_approval'].includes(task.status))return null;}
    return this.compareAndSwap(owner,'actions',id,{status:'awaiting_review'},{status});
  }
}
