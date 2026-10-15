// catpaw.approval.v1 — human-in-the-loop interrupts on the existing native chat turn record.
// No table or column: interrupts and the paused round live on the `native-chat-turns` row;
// "以后同类直接执行" lives in the existing records table under kind APPROVAL_PREFERENCES.
import { check,shape,UUID,hash,clone } from '../facade-r2/src/common.mjs';
export const isoAt=ms=>new Date(ms).toISOString();
import { toolApprovalPolicy } from './tools.mjs';
import { stableUUID } from './local-output-facade.mjs';
export const APPROVAL_CONTRACT='catpaw.approval.v1';
export const APPROVAL_HEADER='X-Catpaw-Approval-Contract';
export const APPROVAL_TTL_MS=10*60*1000;
export const APPROVAL_PREFERENCES='native-chat-approval-preferences';
export const DECISIONS=Object.freeze(['approve','deny','approve_always']);
const SHA=/^[a-f0-9]{64}$/;
export const argsHash=call=>hash({name:call.name,arguments:call.arguments});
export const preferenceID=(subjectID,cls)=>hash({contract:APPROVAL_CONTRACT,subject_id:subjectID,class:cls}).slice(0,32);
export function summarizeArguments(args){
  const parts=[];for(const [k,v] of Object.entries(args??{})){if(parts.join(' · ').length>180)break;const text=typeof v==='string'?v:JSON.stringify(v);parts.push(`${k}: ${String(text).slice(0,80)}`);}
  return parts.join(' · ').slice(0,240);
}
/** Calls of one model round that need a human decision now (policy + remembered class grants). */
export async function gatedCalls(tx,{owner,subjectID,calls,registry}){
  const out=[];
  for(const call of calls){
    const policy=toolApprovalPolicy(call.name);if(policy.approval==='never')continue;
    if(policy.approval==='first_use'&&policy.class){const pref=await tx.get(owner,APPROVAL_PREFERENCES,preferenceID(subjectID,policy.class));if(pref?.state==='always_allow')continue;}
    const tool=registry instanceof Map?registry.get(call.name):null;
    let summary;try{summary=tool?.summarize?String(tool.summarize(clone(call.arguments))).slice(0,240):summarizeArguments(call.arguments);}catch{summary=summarizeArguments(call.arguments);}
    out.push({call,policy,summary});
  }
  return out;
}
export function interruptFor(turnID,{call,policy,summary},now){
  return {interrupt_id:stableInterruptID(turnID,call.id),call_id:call.id,tool:call.name,summary,args_hash:argsHash(call),risk:policy.risk,approval:policy.approval,class:policy.class??null,
    remember_allowed:policy.approval==='first_use'&&!!policy.class,expires_at:isoAt(now+APPROVAL_TTL_MS),status:'pending'};
}
const stableInterruptID=(turnID,callID)=>stableUUID(`${turnID}:${callID}:approval`);
export const requestedEvent=(it,call)=>({interrupt_id:it.interrupt_id,call_id:it.call_id,tool:it.tool,summary:it.summary,arguments:clone(call.arguments),args_hash:it.args_hash,expires_at:it.expires_at,risk:it.risk,remember_allowed:it.remember_allowed});
export const resolvedEvent=it=>({interrupt_id:it.interrupt_id,call_id:it.call_id,decision:it.status,remember:it.remember===true,decided_at:it.decided_at,...it.decision_operation_id?{decision_operation_id:it.decision_operation_id}:{}});
/** Public projection of pending interrupts for GET …/turns/{t}. */
export const pendingApprovals=t=>(t.interrupts??[]).filter(i=>i.status==='pending').map(({interrupt_id,call_id,tool,summary,args_hash,expires_at,risk,remember_allowed})=>({interrupt_id,call_id,tool,summary,args_hash,expires_at,risk,remember_allowed,arguments:clone(t.approval_checkpoint?.round?.calls?.find(c=>c.id===call_id)?.arguments??null)}));
export function validateDecision(input){
  check(input&&typeof input==='object'&&!Array.isArray(input),422,'approval_schema_invalid');
  try{shape(input,['operation_id','decision','args_hash']);}catch{check(false,422,'approval_schema_invalid');}
  check(UUID.test(input.operation_id)&&DECISIONS.includes(input.decision)&&typeof input.args_hash==='string'&&SHA.test(input.args_hash),422,'approval_schema_invalid');
  return clone(input);
}
/** Lazy expiry: every pending interrupt past expires_at becomes `expired` (denied to the model).
 * Returns {turn,changed,resume}; resume=true when the turn leaves awaiting_approval. */
export function settleExpired(t,now,event){
  if(t?.state!=='awaiting_approval')return {turn:t,changed:false,resume:false};
  let next=t,changed=false;
  for(const it of t.interrupts??[])if(it.status==='pending'&&Date.parse(it.expires_at)<=now){
    const resolved={...it,status:'expired',decided_at:isoAt(now)};
    next={...next,interrupts:next.interrupts.map(i=>i.interrupt_id===it.interrupt_id?resolved:i)};
    next={...next,events:[...next.events,event(next,'approval_resolved',resolvedEvent(resolved))]};changed=true;
  }
  if(!changed)return {turn:t,changed:false,resume:false};
  const resume=next.interrupts.every(i=>i.status!=='pending');
  if(resume)next=resumedTurn(next);
  return {turn:next,changed,resume};
}
export function resumedTurn(t){return {...t,state:'running',approval_checkpoint:{...t.approval_checkpoint,state:'resolved'}};}
/** Model-facing result of a call that was not executed. */
export const deniedResult=it=>({status:'denied',reason:it.status==='expired'?'approval_expired':it.status==='cancelled'?'approval_cancelled':'user_denied',message:it.status==='expired'?'The user did not confirm within 10 minutes; the action was not performed.':'The user declined; the action was not performed.'});
