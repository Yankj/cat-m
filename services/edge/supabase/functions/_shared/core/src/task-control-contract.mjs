import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';
import {Buffer} from 'node:buffer';

export const TASK_CONTROL_CONTRACT='catpaw.task-control.v1';
export const TASK_CONTROL_OPERATIONS='catpaw-task-control-operations';
export const TASK_CONTROL_LIMITS=Object.freeze({payload_bytes:8000,write_budget_ms:15000,unknown_operations:64});
const digest=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
export function taskControlRevision(task){const n=task.state?.task_control?.revision??0;check(Number.isSafeInteger(n)&&n>=0,409,'control_state_corrupt');return n;}
export function validateTaskControlRequest(input){
 shape(input,['operation_id','action','expected_execution_revision','expected_snapshot_hash','expected_grant_epoch','expected_plan_revision','expected_plan_hash']);
 check(UUID.test(input.operation_id)&&['pause','resume','revoke'].includes(input.action)&&Number.isSafeInteger(input.expected_execution_revision)&&input.expected_execution_revision>=0&&digest(input.expected_snapshot_hash)&&Number.isSafeInteger(input.expected_grant_epoch)&&input.expected_grant_epoch>0&&Number.isSafeInteger(input.expected_plan_revision)&&input.expected_plan_revision>0&&digest(input.expected_plan_hash),422,'control_schema_invalid');
 check(Buffer.byteLength(JSON.stringify(input))<=TASK_CONTROL_LIMITS.payload_bytes,413,'control_request_too_large');return {...clone(input),operation_id:input.operation_id.toLowerCase()};
}
export function taskControlReceiptHash(receipt){const {receipt_hash,...fields}=receipt;return hash(fields);}
export function workerExecutionContext(run,task){return {run_id:run.id,task_id:task.id,run_request_hash:run.request_hash,lease_id:task.leaseId,execution_revision:taskControlRevision(task)};}
export function parseTaskControlJSON(raw){
 check(typeof raw==='string'&&Buffer.byteLength(raw)<=TASK_CONTROL_LIMITS.payload_bytes,413,'control_request_too_large');let result;
 try{result=JSON.parse(raw);}catch{check(false,422,'control_schema_invalid');}
 let cursor=0;const space=()=>{while(/[\x20\x09\x0a\x0d]/.test(raw[cursor]??'')&&cursor<raw.length)cursor++;};
 const string=()=>{check(raw[cursor]==='"',422,'control_schema_invalid');const start=cursor++;while(cursor<raw.length){const c=raw[cursor++];if(c==='\\'){cursor++;continue;}if(c==='"')return JSON.parse(raw.slice(start,cursor));}check(false,422,'control_schema_invalid');};
 const value=depth=>{check(depth<=8,422,'control_schema_invalid');space();const c=raw[cursor];if(c==='"'){string();return;}
  if(c==='{'){cursor++;space();const keys=new Set();if(raw[cursor]==='}'){cursor++;return;}for(;;){const key=string();check(!keys.has(key),422,'control_duplicate_key');keys.add(key);space();check(raw[cursor++]===':',422,'control_schema_invalid');value(depth+1);space();const end=raw[cursor++];if(end==='}')return;check(end===',',422,'control_schema_invalid');space();}}
  if(c==='['){cursor++;space();if(raw[cursor]===']'){cursor++;return;}for(;;){value(depth+1);space();const end=raw[cursor++];if(end===']')return;check(end===',',422,'control_schema_invalid');}}
  const token=/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(raw.slice(cursor));check(token,422,'control_schema_invalid');cursor+=token[0].length;
 };value(0);space();check(cursor===raw.length,422,'control_schema_invalid');return result;
}
