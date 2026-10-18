// Offline Node 22 harness without esbuild: .ts → node:module stripTypeScriptTypes.
// npm:jose / npm:postgres resolve to the real pinned packages in test/support/vendor (installed by
// scripts/ci-node-tests.sh); when absent they fall back to inert stubs. Also installs a minimal Deno shim.
import {register} from 'node:module';
import {readFile,writeFile} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {fileURLToPath,pathToFileURL} from 'node:url';
import process from 'node:process';
const vendor=fileURLToPath(new URL('./vendor/node_modules/',import.meta.url));
globalThis.Deno??={args:[],env:{get:k=>process.env[k],has:k=>k in process.env,toObject:()=>({...process.env})},readTextFile:p=>readFile(p,'utf8'),writeTextFile:(p,t)=>writeFile(p,t)};
register('data:text/javascript,'+encodeURIComponent(`
import {readFile} from 'node:fs/promises';import {fileURLToPath,pathToFileURL} from 'node:url';import {stripTypeScriptTypes} from 'node:module';import {existsSync} from 'node:fs';
const vendor=${JSON.stringify(vendor)};
const stubs={jose:'export const createRemoteJWKSet=()=>{throw Error("offline_stub")},createLocalJWKSet=()=>{throw Error("offline_stub")},jwtVerify=async()=>{throw Error("offline_stub")},decodeProtectedHeader=()=>({}),decodeJwt=()=>({});',postgres:'export default function postgres(){throw Error("offline_stub")}'};
export async function resolve(s,c,n){const m=/^npm:((?:@[^/@]+\\/)?[^/@]+)(?:@[^/]+)?(\\/.*)?$/.exec(s);
 if(m&&stubs[m[1]]){const dir=vendor+m[1];
  if(existsSync(dir))return n(m[2]?pathToFileURL(dir+m[2]).href:m[1],{...c,parentURL:pathToFileURL(vendor).href});
  if(!m[2])return {url:'data:text/javascript,'+encodeURIComponent(stubs[m[1]]),shortCircuit:true};}
 return n(s,c);}
export async function load(u,c,n){if(!u.startsWith('file:')||!u.endsWith('.ts'))return n(u,c);return {format:'module',source:stripTypeScriptTypes(await readFile(fileURLToPath(u),'utf8'),{mode:'transform'}),shortCircuit:true};}`));
