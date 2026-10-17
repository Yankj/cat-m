// Offline Node (20+) harness for the Deno edge sources:
//  - `npm:pkg@ver` resolves to CATPAW_NPM_DIR/pkg when that directory has it
//    (install jose@6.2.12 postgres@3.4.7 esbuild there), otherwise to inert stubs;
//  - `.ts` sources are type-stripped with esbuild from CATPAW_NPM_DIR.
// Usage: CATPAW_NPM_DIR=/path/node_modules node --import ./test/support/npm-stubs.mjs --test test/*.test.mjs
import {register} from 'node:module';
register('data:text/javascript,'+encodeURIComponent(`const npmDir=${JSON.stringify(process.env.CATPAW_NPM_DIR??'')};
import {existsSync} from 'node:fs';import {pathToFileURL,fileURLToPath} from 'node:url';import {readFile} from 'node:fs/promises';
const stubs={
 jose:'export const createRemoteJWKSet=()=>{throw Error("offline_stub")},createLocalJWKSet=()=>{throw Error("offline_stub")},jwtVerify=async()=>{throw Error("offline_stub")},decodeProtectedHeader=()=>({}),decodeJwt=()=>({});',
 postgres:'export default function postgres(){throw Error("offline_stub")}'
};
export async function resolve(specifier,context,next){
 const m=/^npm:((?:@[^/@]+\\/)?[^/@]+)(?:@[^/]+)?$/.exec(specifier);
 if(m){if(npmDir&&existsSync(npmDir+'/'+m[1]))return next(m[1],{...context,parentURL:pathToFileURL(npmDir+'/').href});
  if(stubs[m[1]])return {url:'data:text/javascript,'+encodeURIComponent(stubs[m[1]]),shortCircuit:true};}
 return next(specifier,context);
}
export async function load(url,context,next){
 if(!url.startsWith('file:')||!url.endsWith('.ts'))return next(url,context);
 const esbuild=await import(pathToFileURL(npmDir+'/esbuild/lib/main.js').href);
 const out=await esbuild.transform(await readFile(fileURLToPath(url),'utf8'),{loader:'ts',format:'esm',target:'esnext'});
 return {format:'module',source:out.code,shortCircuit:true};
}`));
