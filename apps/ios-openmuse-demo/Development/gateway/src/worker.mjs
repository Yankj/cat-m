import { ModelGateway } from './transport.mjs';
import { CredentialProvider } from './models.mjs';
import { SyntheticTransport } from './mock.mjs';

export class LocalWorker {
  constructor(service,{gateway=new ModelGateway({transport:new SyntheticTransport(),credentials:new CredentialProvider()}),id='local-synthetic-worker'}={}) {
    this.service=service;this.gateway=gateway;this.id=id;
  }
  async tick() {
    this.service.scheduleDue(); const claim=this.service.claim(this.id,60000); if(!claim) return {status:'idle'};
    let text='',completed=false,failure;
    try {
      // Authoritative fence immediately before each model call; payload remains the frozen one.
      const request=this.service.beginModelCall(claim);
      for await(const event of this.gateway.stream(request,{operationID:claim.run.operation_id,timeoutMs:30000})) {
        if(event.type==='text_delta') text+=event.text;
        if(event.type==='task_completed') completed=true;
        if(event.type==='failed'||event.type==='cancelled') failure=event.code??event.type;
      }
      if(!completed||failure) {this.service.failRun(claim,failure??'missing_terminal');return {status:'failed',run_id:claim.run.id,code:failure};}
      const artifact=this.service.publish(claim,text);
      return {status:'published',run_id:claim.run.id,artifact:artifact.current_reference,reality:claim.run.reality};
    } catch(error) {
      // Revocation/deletion/pause already durably invalidated the run; don't overwrite that decision.
      if(['lease_lost','context_invalidated'].includes(error.code)) return {status:'discarded',run_id:claim.run.id,code:error.code};
      try {this.service.failRun(claim,error.code??'worker_failed');} catch {}
      return {status:'failed',run_id:claim.run.id,code:error.code??'worker_failed'};
    }
  }
}
