// Offline Node 22 harness without esbuild: npm: → inert stubs, .ts → node:module stripTypeScriptTypes. Used by CI.
import {register} from 'node:module';
register('data:text/javascript,'+encodeURIComponent(`
import {readFile} from 'node:fs/promises';import {fileURLToPath} from 'node:url';import {stripTypeScriptTypes} from 'node:module';
const stubs={jose:'export const createRemoteJWKSet=()=>{throw Error("offline_stub")},createLocalJWKSet=()=>{throw Error("offline_stub")},jwtVerify=async()=>{throw Error("offline_stub")},decodeProtectedHeader=()=>({}),decodeJwt=()=>({});',postgres:'export default function postgres(){throw Error("offline_stub")}'};
export async function resolve(s,c,n){const m=/^npm:((?:@[^/@]+\\/)?[^/@]+)(?:@[^/]+)?$/.exec(s);if(m&&stubs[m[1]])return {url:'data:text/javascript,'+encodeURIComponent(stubs[m[1]]),shortCircuit:true};return n(s,c);}
export async function load(u,c,n){if(!u.startsWith('file:')||!u.endsWith('.ts'))return n(u,c);return {format:'module',source:stripTypeScriptTypes(await readFile(fileURLToPath(u),'utf8'),{mode:'transform'}),shortCircuit:true};}`));
