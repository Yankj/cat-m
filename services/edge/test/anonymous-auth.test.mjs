import test from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,SignJWT} from 'npm:jose@6.2.12';
import {createSupabaseSessionVerifier,createSupabaseTokenVerifier} from '../supabase/functions/_shared/core/src/supabase-auth.mjs';
import {officialUserVerifier} from '../supabase/functions/_shared/authority.mjs';
const url='https://dbyklgxdvjbutxzsjeth.supabase.co',sub=randomUUID(),sid=randomUUID(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
const {privateKey,publicKey}=await generateKeyPair('ES256'),jwk={...await exportJWK(publicKey),kid:'offline-test-key',alg:'ES256',use:'sig'},jwks={keys:[jwk]};const now=Math.floor(Date.now()/1000);
const token=async(p={})=>new SignJWT({iss:url+'/auth/v1',aud:'authenticated',sub,session_id:sid,iat:now,exp:now+600,role:'authenticated',is_anonymous:true,...p}).setProtectedHeader({alg:'ES256',kid:jwk.kid,typ:'JWT'}).sign(privateKey);
let requests=0;const userVerify=officialUserVerifier({projectUrl:url,publishableKey:'offline-public-placeholder',fetchImpl:async(target,options)=>{requests++;assert.equal(target,url+'/auth/v1/user');assert.ok(options.headers.Authorization.startsWith('Bearer '));return Response.json({id:sub,is_anonymous:true});}});
test('project signed anonymous JWT plus official-user identity confirmation reaches scope resolver; refresh keeps scope',async()=>{const resolveInputs=[];const verify=createSupabaseSessionVerifier({projectUrl:url,mode:'test',testJWKS:jwks,scopeAuthority:{resolve:async input=>{resolveInputs.push(input);return {session_active:true,scopes:[scope]};}},remoteUserVerifier:userVerify});const first=await verify('Bearer '+await token()),refresh=await verify('Bearer '+await token({iat:now+1,exp:now+601}));assert.deepEqual(first.scopes,refresh.scopes);assert.equal(first.subject_id,sub);assert.equal(resolveInputs.length,2);});
test('tamper, foreign issuer, admin role, malformed anonymous flag are rejected before official-user request',async()=>{const verify=createSupabaseTokenVerifier({projectUrl:url,mode:'test',testJWKS:jwks});for(const p of [{iss:'https://abcdefghijklmnopqrst.supabase.co/auth/v1'},{role:'service_role'},{is_anonymous:'true'}])await assert.rejects(verify('Bearer '+await token(p)));const t=await token(),parts=t.split('.');parts[1]=btoa(JSON.stringify({iss:url+'/auth/v1',sub:randomUUID()})).replaceAll('=','');await assert.rejects(verify('Bearer '+parts.join('.')));});
test('official-user mismatch or failure never grants a scope; other project anonymous remains denied',async()=>{const bad=officialUserVerifier({projectUrl:url,publishableKey:'offline',fetchImpl:async()=>Response.json({id:randomUUID(),is_anonymous:true})});await assert.rejects(bad({authorization:'Bearer offline',subject_id:sub,is_anonymous:true}),e=>e.code==='invalid_session');const denied=officialUserVerifier({projectUrl:url,publishableKey:'offline',fetchImpl:async()=>new Response('{}',{status:401})});await assert.rejects(denied({authorization:'Bearer offline',subject_id:sub,is_anonymous:true}),e=>e.code==='invalid_session');const verify=createSupabaseTokenVerifier({projectUrl:'https://abcdefghijklmnopqrst.supabase.co',mode:'test',testJWKS:jwks});await assert.rejects(verify('Bearer '+await token({iss:'https://abcdefghijklmnopqrst.supabase.co/auth/v1'})),e=>e.code==='invalid_session');});
test('official-user availability failures do not reject the identity or reach scope resolution',async()=>{
 for(const fetchImpl of [
  async()=>{throw new TypeError('offline transport');},
  ...[408,429,500,503].map(status=>async()=>new Response('{}',{status})),
  async()=>new Response('{'),async()=>Response.json(null)
 ]){
  let resolves=0;
  const verify=createSupabaseSessionVerifier({projectUrl:url,mode:'test',testJWKS:jwks,
   scopeAuthority:{resolve:async()=>{resolves++;return {session_active:true,scopes:[scope]};}},
   remoteUserVerifier:officialUserVerifier({projectUrl:url,publishableKey:'offline',fetchImpl})});
  await assert.rejects(verify('Bearer '+await token()),e=>e.status===503&&e.code==='auth_service_unavailable');
  assert.equal(resolves,0);
 }
});
