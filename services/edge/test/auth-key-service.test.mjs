import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,SignJWT} from 'npm:jose@6.2.12';
import {createSupabaseTokenVerifier} from '../supabase/functions/_shared/core/src/supabase-auth.mjs';

// Real signing/verification with a local fake JWKS transport; never contacts Supabase.
test('key-service outages remain retryable and fail closed; recovery caches verified public keys',async t=>{
  const projectUrl='https://abcdefghijklmnopqrst.supabase.co';
  const {privateKey,publicKey}=await generateKeyPair('ES256');
  const jwk={...await exportJWK(publicKey),kid:'offline-key',alg:'ES256',use:'sig'};
  const now=Math.floor(Date.now()/1000),subject=randomUUID();
  const sign=(overrides={},kid=jwk.kid)=>new SignJWT({iss:projectUrl+'/auth/v1',aud:'authenticated',sub:subject,session_id:randomUUID(),iat:now,exp:now+600,role:'authenticated',...overrides}).setProtectedHeader({alg:'ES256',kid,typ:'JWT'}).sign(privateKey);
  const token=await sign(),authorization='Bearer '+token;
  const originalFetch=globalThis.fetch;
  t.after(()=>{globalThis.fetch=originalFetch;});
  const unavailable=e=>e.status===503&&e.code==='auth_key_service_unavailable';
  const invalid=e=>e.status===401&&e.code==='invalid_session';

  for(const [name,response] of [
    ['timeout',()=>{throw new DOMException('offline timeout','TimeoutError');}],
    ['transport',()=>{throw new TypeError('offline fetch failed');}],
    ['http',()=>new Response('{}',{status:503})],
    ['malformed json',()=>new Response('{')],
    ['malformed keys',()=>Response.json({keys:'invalid'})]
  ]) await t.test(name,async()=>{
    let calls=0;
    globalThis.fetch=async url=>{calls++;assert.equal(String(url),projectUrl+'/auth/v1/.well-known/jwks.json');return response();};
    const verify=createSupabaseTokenVerifier({projectUrl});
    await assert.rejects(verify(authorization),unavailable);
    assert.equal(calls,1);
    globalThis.fetch=async()=>{calls++;return Response.json({keys:[jwk]});};
    assert.equal((await verify(authorization)).sub,subject);
    assert.equal((await verify(authorization)).sub,subject);
    assert.equal(calls,2,'Successful public keys are cached; failed fetches do not poison the verifier.');
  });

  await t.test('invalid signature, unknown key, expired and foreign issuer stay rejected',async()=>{
    let calls=0;
    globalThis.fetch=async()=>{calls++;return Response.json({keys:[jwk]});};
    const verify=createSupabaseTokenVerifier({projectUrl});
    await assert.rejects(verify('Bearer '+await sign({iss:'https://foreign.example.invalid/auth/v1'})),invalid);
    assert.equal(calls,0,'An untrusted issuer must not initiate key discovery.');
    await verify(authorization);
    const parts=token.split('.');parts[2]=(parts[2][0]==='a'?'b':'a')+parts[2].slice(1);
    await assert.rejects(verify('Bearer '+parts.join('.')),invalid);
    await assert.rejects(verify('Bearer '+await sign({},'unknown-key')),invalid);
    await assert.rejects(verify('Bearer '+await sign({iat:now-100,exp:now-1})),invalid);
    assert.equal(calls,1);
  });
});
