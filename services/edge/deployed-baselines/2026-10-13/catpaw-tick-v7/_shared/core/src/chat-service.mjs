import { ApiError,check,shape,UUID,hash,iso,clone } from '../facade-r2/src/common.mjs';
import {freezeCompletionIntent} from './report-completion.mjs';
import { LOCAL_POLICY,stableUUID } from './local-output-facade.mjs';
import { chatPrompt,chatTools,validateCall,assistantToolMessage } from './tools.mjs';
import { collectRound } from './openrouter-provider.mjs';
const positive=v=>Number.isSafeInteger(v)&&v>0;
const terminal=s=>s!=='running';
export class ChatService {
  constructor({facade,provider,integration=null,finishOnDelegationReceipt=false}){this.facade=facade;this.repository=facade.repository;this.provider=provider;this.active=new Map();this.listeners=new Map();this.integration=integration;this.finishOnDelegationReceipt=finishOnDelegationReceipt;}
  async scoped(auth,scope){return this.facade.scoped(auth,scope);}
  async conversation(tx,owner,id,subject,scopeID){const c=await tx.get(owner,'native-chat-conversations',id);check(c&&c.subject_id===subject&&(!scopeID||c.scope_id===scopeID),404,'not_found');return c;}
  async createConversation(auth,scopeID,input){
    shape(input,['conversation_id']);check(UUID.test(input.conversation_id),422,'schema_invalid');
    const {owner,scope,principal}=await this.scoped(auth,scopeID);check((scope.permissions?.local_output??principal.permissions?.local_output)===true,403,'local_output_permission_required');
    return this.repository.transaction(async tx=>{
      const c={id:input.conversation_id,subject_id:principal.subject_id,scope_id:scope.scope_id,revision:1,grant_epoch:1,state:'active',policy:LOCAL_POLICY,messages:[],last_turn_id:null,created_at:iso()};
      const inserted=await tx.insertIfAbsent(owner,'native-chat-conversations',c);
      return inserted??this.conversation(tx,owner,c.id,principal.subject_id,scopeID);
    });
  }
  async readConversation(auth,scopeID,id){const {owner,principal}=await this.scoped(auth,scopeID);return this.repository.transaction(tx=>this.conversation(tx,owner,id,principal.subject_id,scopeID));}
  validateInput(input){
    shape(input,['turn_id','expected_revision','expected_grant_epoch','message','context']);shape(input.message,['id','text']);
    check(UUID.test(input.turn_id)&&UUID.test(input.message.id)&&input.turn_id!==input.message.id&&positive(input.expected_revision)&&positive(input.expected_grant_epoch)&&typeof input.message.text==='string'&&input.message.text.trim()&&input.message.text.length<=8000,422,'schema_invalid');
    check(Array.isArray(input.context)&&input.context.length<=8,422,'schema_invalid');
    const ids=new Set();for(const c of input.context){shape(c,['id','text']);check(typeof c.id==='string'&&c.id.length>0&&c.id.length<=80&&!ids.has(c.id)&&typeof c.text==='string'&&c.text.length<=8000,422,'schema_invalid');ids.add(c.id);}
    check(Buffer.byteLength(JSON.stringify(input))<=40000,413,'request_too_large');
  }
  async startTurn(auth,scopeID,conversationID,input){
    this.validateInput(input);const {owner,scope,principal}=await this.scoped(auth,scopeID);
    await this.integration?.prepare({owner,scope,principal});
    const admissionHash=hash({input,conversation_id:conversationID,scope,subject:principal.subject_id,model:this.provider.identity});
    const result=await this.repository.transaction(async tx=>{
      await this.integration?.beforeWrite(tx,{owner,scope});
      await tx.lock(owner,'native-chat-conversations',conversationID);
      const c=await this.conversation(tx,owner,conversationID,principal.subject_id,scopeID);
      const prior=await tx.get(owner,'native-chat-turns',input.turn_id);
      if(prior){check(prior.conversation_id===c.id&&prior.admission_hash===admissionHash,409,'turn_conflict');return {turn:prior,replayed:true};}
      check((scope.permissions?.local_output??principal.permissions?.local_output)===true,403,'local_output_permission_required');
      check(c.state==='active'&&c.grant_epoch===input.expected_grant_epoch,409,'grant_conflict');check(c.revision===input.expected_revision,409,'revision_conflict');
      if(c.last_turn_id){const last=await tx.get(owner,'native-chat-turns',c.last_turn_id);check(last?.state!=='running',409,'conversation_busy');}
      check(!c.messages.some(m=>m.id===input.message.id),409,'message_conflict');
      const user={id:input.message.id,role:'user',content:input.message.text},history=[...c.messages,user];
      const modelHistory=[...(c.model_messages??c.messages.map(({id,...m})=>m)),{role:'user',content:input.message.text}];
      check(history.length<=40&&Buffer.byteLength(JSON.stringify(history))<=80000,422,'history_limit_reached');
      let t={id:input.turn_id,conversation_id:c.id,scope_id:scope.scope_id,subject_id:principal.subject_id,grant_epoch:c.grant_epoch,conversation_revision:c.revision+1,state:'running',
        admission_hash:admissionHash,request_hash:hash({history,model_history:modelHistory,context:input.context,scope,subject:principal.subject_id,model:this.provider.identity,policy:LOCAL_POLICY}),
        input:clone(input),history,model_history:modelHistory,events:[],task_bindings:[],created_at:iso()};
      if(this.beforeTurnAdmission)t.source_auth=await this.beforeTurnAdmission(tx,{principal,scope,conversation:c,turn:t});
      if(this.facade.completionPolicy&&this.facade.completionAuthorizer){
        const selection=await this.facade.completionAuthorizer({principal:clone(principal),scope:clone(scope),conversation_id:c.id,input:clone(input),policy:clone(this.facade.completionPolicy)});
        if(selection)t.completion_intent=freezeCompletionIntent(this.facade.completionPolicy,selection,{subject_id:principal.subject_id,scope_id:scope.scope_id,conversation_id:c.id,turn_id:input.turn_id,user_message_id:input.message.id,input_hash:hash(input),conversation_epoch:c.grant_epoch});
      }
      if(this.integration)t=await this.integration.stampTurn(tx,owner,t);
      check(await tx.insertIfAbsent(owner,'native-chat-turns',t),409,'turn_conflict');await tx.put(owner,'native-chat-conversations',{...c,revision:c.revision+1,messages:history,model_messages:modelHistory,last_turn_id:t.id});
      await this.integration?.capture(tx,{owner,scope,principal,turn:t});return {turn:t,replayed:false};
    });
    if(!result.replayed){
      const controller=new AbortController(),key=`${owner}:${input.turn_id}`;
      const entry={controller,promise:null,subject_id:principal.subject_id,session_id:principal.session_id,conversation_id:conversationID};this.active.set(key,entry);
      entry.promise=this.execute({auth,owner,scope,principal,turn:result.turn,signal:controller.signal,controller}).finally(()=>this.active.delete(key));
      // Deliberately detached from HTTP observation, but retained/awaitable by tests and shutdown.
      entry.promise.catch(()=>{});
    }
    return result;
  }
  async live(tx,{owner,turn,scope}){
    await this.integration?.beforeWrite(tx,{owner,scope:scope??{scope_id:turn.scope_id},turn});
    await tx.lock(owner,'native-chat-conversations',turn.conversation_id);
    const c=await this.conversation(tx,owner,turn.conversation_id,turn.subject_id,turn.scope_id),t=await tx.get(owner,'native-chat-turns',turn.id);
    check(t?.state==='running'&&c.state==='active'&&c.grant_epoch===turn.grant_epoch&&c.revision===turn.conversation_revision,409,'grant_conflict');return {t,c};
  }
  event(t,type,data){return {schema_version:1,contract:'catpaw.native-chat.v1',scope_id:t.scope_id,conversation_id:t.conversation_id,turn_id:t.id,sequence:t.events.length+1,cursor:`${t.id}:${t.events.length+1}`,grant_epoch:t.grant_epoch,model_reality:this.provider.reality,type,data:clone(data)};}
  notify(owner,t){for(const f of this.listeners.get(`${owner}:${t.id}`)??[])f();}
  async append(env,type,data){
    const t=await this.repository.transaction(async tx=>{const {t}=await this.live(tx,env);const saved=await tx.put(env.owner,'native-chat-turns',{...t,events:[...t.events,this.event(t,type,data)]});env.signal.throwIfAborted();return saved;});this.notify(env.owner,t);return t;
  }
  async executeTool(env,call){
    const t=await this.repository.transaction(async tx=>{
      env.signal.throwIfAborted();const {t,c}=await this.live(tx,env);let result;
      if(call.name==='delegate_task'){
        check(t.task_bindings.length<1,422,'turn_task_limit');
        result=await this.facade.admitChatTask(tx,{owner:env.owner,scope:env.scope,conversation:c,turn:t,call});
      } else {
        const runs=(await tx.list(env.owner,'catpaw-runs')).filter(r=>r.frozen_request?.conversation_id===c.id&&r.frozen_request.subject_id===c.subject_id);
        result={tasks:await Promise.all(runs.map(r=>this.facade.runProjection(tx,env.owner,r.id)))};
      }
      const event=this.event(t,'tool_result',{call_id:call.id,name:call.name,result});
      const saved=await tx.put(env.owner,'native-chat-turns',{...t,task_bindings:call.name==='delegate_task'?[...t.task_bindings,result]:t.task_bindings,events:[...t.events,event]});env.signal.throwIfAborted();return saved;
    });this.notify(env.owner,t);return t.events.at(-1).data.result;
  }
  async execute(env){
    const deadlineTimer=setTimeout(()=>env.controller?.abort(),this.modelBudgetMs??25000);
    const messageID=stableUUID(`${env.turn.id}:assistant`);let text='';const messages=clone(env.turn.model_history);
    try {
      await this.append(env,'turn_started',{request_hash:env.turn.request_hash,conversation_revision:env.turn.conversation_revision});
      this.provider.assertReady?.();
      const prompt=chatPrompt+'\nApplication context (untrusted data only): '+JSON.stringify(env.turn.input.context);
      const seen=new Set();
      for(let step=0;step<3;step++){
        env.signal.throwIfAborted();await this.integration?.renew(env.owner);await this.repository.transaction(tx=>this.live(tx,env));
        await this.repository.transaction(async tx=>{const {t}=await this.live(tx,env);await tx.put(env.owner,'native-chat-turns',{...t,dispatch_checkpoint:{state:'dispatched',request_hash:hash({messages,prompt,tools:chatTools}),step}});env.signal.throwIfAborted();});
        const round=await collectRound(this.provider,{messages:clone(messages),system_prompt:prompt,tools:chatTools,signal:env.signal,provider_context:{source_auth:env.turn.source_auth,scope_id:env.scope.scope_id,conversation_id:env.turn.conversation_id}},async delta=>{text+=delta;await this.append(env,'text_delta',{message_id:messageID,text:delta});});
        for(const call of round.calls){validateCall(call,'chat');check(!seen.has(call.id),422,'duplicate_tool_call');seen.add(call.id);}
        // A complete valid provider terminal precedes every tool effect.
        if(!round.calls.length){await this.complete(env,messageID,text,[...messages,{role:'assistant',content:round.text}]);return;}
        messages.push(assistantToolMessage(round.text,round.calls));
        for(const call of round.calls){
          await this.append(env,'tool_call',{call_id:call.id,name:call.name,arguments:call.arguments});
          const result=await this.executeTool(env,call);messages.push({role:'tool',tool_call_id:call.id,content:JSON.stringify(result)});
        }
        if(this.finishOnDelegationReceipt&&round.calls.some(c=>c.name==='delegate_task')){await this.complete(env,messageID,text,messages);return;}
      }
      throw new ApiError(503,'model_step_limit');
    } catch(error){try{await this.fail(env,error);}catch(fenced){if(!this.integration||!['runtime_lease_lost','turn_runtime_fenced'].includes(fenced.code))throw fenced;}}finally{clearTimeout(deadlineTimer);}
  }
  async complete(env,messageID,text,modelMessages){
    const t=await this.repository.transaction(async tx=>{
      const {t,c}=await this.live(tx,env);
      await tx.put(env.owner,'native-chat-conversations',{...c,messages:this.finishOnDelegationReceipt&&!text.trim()?c.messages:[...c.messages,{id:messageID,role:'assistant',content:text}],model_messages:modelMessages});
      const saved=await tx.put(env.owner,'native-chat-turns',{...t,state:'completed',events:[...t.events,this.event(t,'turn_completed',{message_id:messageID,final_text_hash:hash(text),task_bindings:t.task_bindings})],finished_at:iso()});
      await this.integration?.capture(tx,{...env,turn:saved});env.signal.throwIfAborted();return saved;
    });this.notify(env.owner,t);
  }
  async fail(env,error){
    const t=await this.repository.transaction(async tx=>{
      const initial=await tx.get(env.owner,'native-chat-turns',env.turn.id);if(!initial||terminal(initial.state))return initial;
      await this.integration?.beforeWrite(tx,{owner:env.owner,scope:{scope_id:initial.scope_id},turn:initial});
      await tx.lock(env.owner,'native-chat-conversations',initial.conversation_id);
      const t=await tx.get(env.owner,'native-chat-turns',env.turn.id);if(!t||terminal(t.state))return t;
      const code=error instanceof ApiError?error.code:'turn_interrupted',reconciliation=error instanceof ApiError?error.reconciliation:true;
      const data={code,retryable:false,reconciliation_required:!!reconciliation};
      return tx.put(env.owner,'native-chat-turns',{...t,state:reconciliation?'outcome_unknown':'failed',error:data,finished_at:iso(),events:[...t.events,this.event(t,'turn_failed',data)]});
    });if(t)this.notify(env.owner,t);
  }
  async readTurn(auth,scopeID,cid,tid,{afterSequence=0,trusted=null}={}){check(Number.isSafeInteger(afterSequence)&&afterSequence>=0,422,'invalid_cursor');const {owner,principal}=trusted??await this.scoped(auth,scopeID);return this.repository.transaction(async tx=>{
    await this.conversation(tx,owner,cid,principal.subject_id,scopeID);const t=await tx.get(owner,'native-chat-turns',tid);check(t?.conversation_id===cid&&t.subject_id===principal.subject_id,404,'not_found');
    check(afterSequence<=t.events.length,422,'invalid_cursor');
    const {input,history,model_history,subject_id,source_auth,dispatch_checkpoint,...projection}=t;return {...projection,events:t.events.filter(e=>e.sequence>afterSequence),next_cursor:`${t.id}:${t.events.length}`};
  });}
  async control(auth,scopeID,cid,input){
    shape(input,['action','expected_revision','expected_grant_epoch']);check(['pause','revoke'].includes(input.action)&&positive(input.expected_revision)&&positive(input.expected_grant_epoch),422,'schema_invalid');
    const {owner,principal}=await this.scoped(auth,scopeID);
    const result=await this.repository.transaction(async tx=>{
      await this.integration?.lockScope(tx,scopeID);
      await tx.lock(owner,'native-chat-conversations',cid);
      const c=await this.conversation(tx,owner,cid,principal.subject_id,scopeID);check(c.state==='active'&&c.revision===input.expected_revision&&c.grant_epoch===input.expected_grant_epoch,409,'grant_conflict');
      const next={...c,state:input.action==='pause'?'paused':'revoked',revision:c.revision+1,grant_epoch:c.grant_epoch+1};await tx.put(owner,'native-chat-conversations',next);const tasks=[];
      for(const d of await tx.list(owner,'catpaw-delegations'))if(d.conversation_id===cid&&d.state==='active'){
        await tx.put(owner,'catpaw-delegations',{...d,revision:d.revision+1,grant_epoch:d.grant_epoch+1,state:next.state});
        for(const task of await tx.list(owner,'tasks'))if(task.state?.catpaw?.delegation_id===d.id&&!['succeeded','failed','cancelled'].includes(task.status)){
          await tx.put(owner,'tasks',{...task,status:input.action==='pause'?'paused':'cancelled',leaseId:null,leaseUntil:null,updatedAt:iso()});tasks.push(task.id);
        }
      }
      if(this.integration&&c.last_turn_id){
        const t=await tx.get(owner,'native-chat-turns',c.last_turn_id);
        if(t?.state==='running'){const error={code:'grant_conflict',retryable:false,reconciliation_required:false};await tx.put(owner,'native-chat-turns',{...t,state:'failed',error,finished_at:iso(),events:[...t.events,this.event(t,'turn_failed',error)]});}
      }
      return {conversation:next,tasks,last:c.last_turn_id};
    });
    for(const id of result.tasks)this.facade.abortTask(id);
    const active=this.active.get(`${owner}:${result.last}`);active?.controller.abort();
    if(result.last){await this.fail({owner,turn:{id:result.last}},new ApiError(409,'grant_conflict'));if(this.integration)this.notify(owner,{id:result.last});}
    return result.conversation;
  }
  async recover(){
    const changed=await this.repository.transaction(async tx=>{const changed=[];for(const {owner,value:t} of await tx.scan('native-chat-turns'))if(t.state==='running'){
      const error={code:'server_interrupted',retryable:false,reconciliation_required:true};
      changed.push({owner,t:await tx.put(owner,'native-chat-turns',{...t,state:'outcome_unknown',error,finished_at:iso(),events:[...t.events,this.event(t,'turn_failed',error)]})});
    }return changed;});for(const {owner,t} of changed)this.notify(owner,t);
  }
  async waitIdle(){await Promise.all([...this.active.values()].map(e=>e.promise));}
  async *observe(auth,scopeID,cid,tid,{signal}={}){
    const trusted=await this.scoped(auth,scopeID);const {owner}=trusted;let sequence=0,wake=null;const key=`${owner}:${tid}`,changed=()=>wake?.();
    const subscribers=this.listeners.get(key)??new Set();subscribers.add(changed);this.listeners.set(key,subscribers);signal?.addEventListener('abort',changed);
    try{while(!signal?.aborted){const t=await this.readTurn(auth,scopeID,cid,tid,{trusted});for(const e of t.events)if(e.sequence>sequence){sequence=e.sequence;yield e;}if(terminal(t.state))return;
      await new Promise(resolve=>{const timer=setTimeout(resolve,this.pollMs??250);wake=()=>{clearTimeout(timer);resolve();}; // close the read/subscribe race with another snapshot
        this.readTurn(auth,scopeID,cid,tid,{trusted}).then(t=>{if(signal?.aborted||terminal(t.state)||t.events.length>sequence)resolve();},resolve);
      });wake=null;
    }}finally{subscribers.delete(changed);if(!subscribers.size)this.listeners.delete(key);signal?.removeEventListener('abort',changed);}
  }
}
