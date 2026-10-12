// One serialized durable writer while the provider keeps draining. Memory stays bounded
// by collectRound's 64 KiB output limit. finish/stop are awaited by the retained turn.
export class TextBatcher {
 constructor({persist,assertLive,onFailure,signal,minChars=512,delayMs=250}){
  Object.assign(this,{persist,assertLive,onFailure,signal,minChars,delayMs});
  this.pending='';this.busy=false;this.sealed=false;this.stopped=false;this.failure=null;this.flight=Promise.resolve();this.timer=null;
  this.abort=()=>{this.stopped=true;this.sealed=true;this.pending='';this.clearTimer();};
  signal.addEventListener('abort',this.abort,{once:true});if(signal.aborted)this.abort();
 }
 clearTimer(){if(this.timer!==null){clearTimeout(this.timer);this.timer=null;}}
 schedule(){if(this.timer===null&&!this.busy&&!this.sealed&&!this.stopped&&this.pending)this.timer=setTimeout(()=>{this.timer=null;this.start();},this.delayMs);}
 push(text){
  this.assertLive();if(this.failure)throw this.failure;if(this.sealed||this.stopped)throw Error('text_batcher_closed');
  this.pending+=text;
  if(!this.busy&&this.pending.length>=this.minChars)this.start();else this.schedule();
 }
 start(){
  if(this.busy||this.stopped||this.failure||!this.pending)return;
  this.clearTimer();const text=this.pending;this.pending='';this.busy=true;
  this.flight=Promise.resolve().then(async()=>{this.assertLive();await this.persist(text);this.assertLive();})
   .catch(error=>{this.failure=error;this.pending='';this.stopped=true;this.clearTimer();this.onFailure(error);})
   .finally(()=>{this.busy=false;if(!this.sealed&&!this.stopped){if(this.pending.length>=this.minChars)this.start();else this.schedule();}});
 }
 async finish(){
  this.sealed=true;this.clearTimer();
  while(this.busy||this.pending){if(this.failure)throw this.failure;this.assertLive();if(!this.busy)this.start();await this.flight;}
  if(this.failure)throw this.failure;this.assertLive();
 }
 async stop(){this.abort();await this.flight;this.signal.removeEventListener('abort',this.abort);}
}
