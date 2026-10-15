import {Buffer} from 'node:buffer';
import {check,hash} from '../facade-r2/src/common.mjs';
import {parseStrictObjectJSON} from './strict-json.mjs';
export const MEMORY_CONTRACT='catpaw.memory.v1';
export const MEMORY_LIMITS=Object.freeze({payload_bytes:16000,state_bytes:1500000,max_rows:2000});
const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const memoryUUID=value=>{check(typeof value==='string'&&uuidPattern.test(value),422,'memory_schema_invalid');return value.toLowerCase();};
const exact=(value,keys,optional=[])=>check(value&&Object.getPrototypeOf(value)===Object.prototype&&keys.every(k=>Object.hasOwn(value,k))&&Object.keys(value).every(k=>keys.includes(k)||optional.includes(k)),422,'memory_schema_invalid');
const positive=value=>check(Number.isSafeInteger(value)&&value>0,422,'memory_schema_invalid');
const bool=value=>check(typeof value==='boolean',422,'memory_schema_invalid');
export function validateMemoryCommand(input){
 exact(input,['schema_version','contract','operation_id','expected_memory_generation','command']);
 check(input.schema_version===1&&input.contract===MEMORY_CONTRACT,422,'memory_schema_invalid');memoryUUID(input.operation_id);positive(input.expected_memory_generation);
 const c=input.command;check(c&&typeof c.type==='string',422,'memory_schema_invalid');
 if(['remember','correct'].includes(c.type)){
  exact(c,['type','conversation_id','source_text','claim','allow_relearn','sensitive_consent',...c.type==='correct'?['target_id','expected_version']:[]]);
  memoryUUID(c.conversation_id);check(typeof c.source_text==='string'&&c.source_text.trim().length>0&&c.source_text.length<=8000,422,'memory_schema_invalid');bool(c.allow_relearn);bool(c.sensitive_consent);
  if(c.type==='correct'){memoryUUID(c.target_id);positive(c.expected_version);}
  check(c.claim&&c.claim.assertion==='explicit',422,'memory_schema_invalid');
 }else if(c.type==='confirm'){
  exact(c,['type','candidate_id','expected_version','allow_relearn','sensitive_consent']);memoryUUID(c.candidate_id);positive(c.expected_version);bool(c.allow_relearn);bool(c.sensitive_consent);
 }else if(c.type==='forget'){
  exact(c,['type','target_id','expected_version','no_relearn']);memoryUUID(c.target_id);positive(c.expected_version);bool(c.no_relearn);
 }else if(c.type==='set_enabled'){exact(c,['type','enabled']);bool(c.enabled);}
 else check(false,422,'memory_schema_invalid');
 check(Buffer.byteLength(JSON.stringify(input))<=MEMORY_LIMITS.payload_bytes,413,'memory_request_too_large');return input;
}
export function parseMemoryCommand(raw){return validateMemoryCommand(parseStrictObjectJSON(raw,{maxBytes:MEMORY_LIMITS.payload_bytes,maxDepth:10,sizeCode:'memory_request_too_large',schemaCode:'memory_schema_invalid',duplicateCode:'memory_duplicate_key'}));}
export const memoryRequestHash=input=>hash(validateMemoryCommand(input));
