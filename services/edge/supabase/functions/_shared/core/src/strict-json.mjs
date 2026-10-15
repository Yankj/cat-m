import {Buffer} from 'node:buffer';
import {check} from '../facade-r2/src/common.mjs';

/** Bound bytes/depth and reject duplicate keys before a typed mutation contract
 * can observe JSON.parse's last-key-wins result. Error identities belong to callers. */
export function parseStrictObjectJSON(raw,{maxBytes,maxDepth=8,sizeCode='request_too_large',schemaCode='schema_invalid',duplicateCode='duplicate_key'}={}){
 check(typeof raw==='string'&&Buffer.byteLength(raw)<=maxBytes,413,sizeCode);let result;
 try{result=JSON.parse(raw);}catch{check(false,422,schemaCode);}
 check(result&&Object.getPrototypeOf(result)===Object.prototype,422,schemaCode);
 let cursor=0;
 const space=()=>{while(cursor<raw.length&&/[\x20\x09\x0a\x0d]/.test(raw[cursor]))cursor++;};
 const string=()=>{check(raw[cursor]==='"',422,schemaCode);const start=cursor++;while(cursor<raw.length){const c=raw[cursor++];if(c==='\\'){cursor++;continue;}if(c==='"')return JSON.parse(raw.slice(start,cursor));}check(false,422,schemaCode);};
 const value=depth=>{
  check(depth<=maxDepth,422,schemaCode);space();const c=raw[cursor];
  if(c==='"'){string();return;}
  if(c==='{'){cursor++;space();const keys=new Set();if(raw[cursor]==='}'){cursor++;return;}for(;;){const key=string();check(!keys.has(key),422,duplicateCode);keys.add(key);space();check(raw[cursor++]===':',422,schemaCode);value(depth+1);space();const end=raw[cursor++];if(end==='}')return;check(end===',',422,schemaCode);space();}}
  if(c==='['){cursor++;space();if(raw[cursor]===']'){cursor++;return;}for(;;){value(depth+1);space();const end=raw[cursor++];if(end===']')return;check(end===',',422,schemaCode);}}
  const token=/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(raw.slice(cursor));check(token,422,schemaCode);cursor+=token[0].length;
 };
 value(0);space();check(cursor===raw.length,422,schemaCode);return result;
}
