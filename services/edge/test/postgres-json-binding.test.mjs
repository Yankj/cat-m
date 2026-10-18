import test from 'node:test';
import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import {serializers} from 'npm:postgres@3.4.7/src/types.js';
import {pgCompatiblePool,boundedPool,verifyDedicatedPool} from '../supabase/functions/_shared/postgres-pool.mjs';
import {AppScopeAuthority} from '../supabase/functions/_shared/authority.mjs';
import {RecordTransaction,PostgresRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/postgres-repository.mjs';

// No reserve/connect on this driver: its actual typed() and serializers are used offline.
const driver=postgres({prepare:false,host:'127.0.0.1',port:5432,database:'synthetic_only',username:'synthetic_only',password:'synthetic_only'});
const wire=(parameter,describedType)=>{
 let value=parameter,type=describedType;
 if(parameter&&typeof parameter==='object'&&'type' in parameter&&'value' in parameter){value=parameter.value;type=parameter.type;}
 return value===null?null:type in serializers?serializers[type](value):String(value);
};
function fixture({failInsert=false,legacy=false}={}){
 let committed={scopes:new Map(),records:new Map()},state=committed,scopeId='',released=0;
 const calls=[],diagnostics=[];
 const key=(owner,kind,id)=>JSON.stringify([owner,kind,id]);
 const parse=(args,index)=>JSON.parse(wire(args[index],3802));
 const reserved={typed:driver.typed,release(){released++;},async unsafe(sql,args=[]){
  calls.push(sql);
  if(sql==='BEGIN'){state=structuredClone(committed);scopeId='';return [];}
  if(sql==='COMMIT'){committed=state;scopeId='';return [];}
  if(sql==='ROLLBACK'){state=committed;scopeId='';return [];}
  if(sql.startsWith('SET LOCAL')||sql.includes('pg_advisory_xact_lock'))return [];
  if(sql.includes("set_config('catpaw.scope_id'")){scopeId=args[0];return [];}
  if(sql.startsWith('INSERT INTO catpaw.scopes')){
   if(failInsert)throw Object.assign(Error('sensitive error body must not be logged'),{code:'23502',query:sql,parameters:args,detail:'private parameter content'});
   const data=parse(args,1);
   // Emulates the actual generated NOT NULL columns, plus the verified scope RLS predicate.
   if(!data?.identity?.profile_id||!data.identity.workspace_id||!data.identity.owner||data.generation==null||data.last_sequence==null)throw Object.assign(Error('generated column is null'),{code:'23502'});
   assert.equal(scopeId,args[0]);assert.equal(data.identity.scope_id,args[0]);
   if(!state.scopes.has(args[0]))state.scopes.set(args[0],data);return [];
  }
  if(sql.startsWith('SELECT data FROM catpaw.scopes')){
   assert.equal(scopeId,args[0]);const data=state.scopes.get(args[0]);return data?[{data}]:[];
  }
  if(sql.startsWith('UPDATE catpaw.scopes')){assert.equal(scopeId,args[0]);state.scopes.set(args[0],parse(args,1));return [];}
  if(sql.startsWith('INSERT INTO catpaw.conversation_refs')){const data=parse(args,2);assert.equal(data.scope_id,scopeId);assert.equal(data.id,args[1]);state.records.set(key(scopeId,'conversation_refs',args[1]),data);return [];}
  if(sql.startsWith('SELECT data FROM public.records')){
   const kind=sql.includes("kind='app-sessions'")?'app-sessions':'scope-memberships';
   const data=state.records.get(key(args[0],kind,args[1]));return data?[{data}]:[];
  }
  if(sql.startsWith('INSERT INTO public.records')){
   const embeddedKind=sql.includes("'scope-memberships'")?'scope-memberships':sql.includes("'app-sessions'")?'app-sessions':null;
   const kind=embeddedKind??args[1],id=args[embeddedKind?1:2],data=parse(args,embeddedKind?2:3);
   state.records.set(key(args[0],kind,id),data);return sql.includes('RETURNING')?[{data}]:[];
  }
  if(sql.startsWith('UPDATE public.records SET data=data ||')){
   const old=state.records.get(key(args[0],args[1],args[2])),expected=parse(args,3),patch=parse(args,4);
   if(!old||!Object.entries(expected).every(([k,v])=>JSON.stringify(old[k])===JSON.stringify(v)))return [];
   const data={...old,...patch};state.records.set(key(args[0],args[1],args[2]),data);return [{data}];
  }
  if(sql.startsWith('UPDATE public.records AS action'))return [{data:{status:parse(args,3)}}];
  throw Error('Unexpected synthetic SQL statement');
 }};
 const sql={reserve:async()=>reserved};
 const pool=legacy?{connect:async()=>({query:async(text,args)=>({rows:await reserved.unsafe(text,args)}),release:()=>reserved.release()})}:boundedPool(pgCompatiblePool(sql));
 return {pool,calls,diagnostics,get committed(){return committed;},get released(){return released;}};
}
const input={issuer:'https://offline.example.invalid/auth/v1',subject_id:'11111111-1111-4111-8111-111111111111',session_id:'22222222-2222-4222-8222-222222222222',issued_at:1,expires_at:9999999999};

test('actual Postgres.js serializers preserve pre-encoded JSON values and leave UUID parameters inferred',async()=>{
 const reserved={typed:driver.typed,release(){},async unsafe(sql,args){
  if(sql==='SELECT $1::jsonb AS data')return [{data:JSON.parse(wire(args[0],3802))}];
  assert.equal(typeof args[0],'string');return [];
 }};
 const c=await pgCompatiblePool({reserve:async()=>reserved}).connect();
 for(const value of [{identity:{profile_id:input.subject_id}},[1,'a'],'scheduled',42,true,null])assert.deepEqual((await c.query('SELECT $1::jsonb AS data',[JSON.stringify(value)])).rows[0].data,value);
 await c.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1',[input.subject_id]);c.release();
 assert.equal(typeof JSON.parse(serializers[3802](JSON.stringify({identity:{}}))),'string','Old driver binding produces a JSON string, not an object');
});
test('foundation record writes, conditional CAS and scalar action status keep their pg JSON-text contract',async()=>{
 const f=fixture(),c=await f.pool.connect();await c.query('BEGIN');const tx=new RecordTransaction(c),owner='catpaw:offline';
 await tx.put(owner,'tasks',{id:'offline-task',status:'queued',state:{step:0}});
 const changed=await tx.compareAndSwap(owner,'tasks','offline-task',{status:'queued'},{status:'running'});assert.equal(changed.status,'running');assert.deepEqual(changed.state,{step:0});
 assert.equal(await tx.compareAndSwap(owner,'tasks','offline-task',{status:'queued'},{status:'succeeded'}),null);
 const inserted=await tx.insertIfAbsent(owner,'audit',{id:'offline-audit',details:{safe:true}});assert.deepEqual(inserted.details,{safe:true});
 assert.equal((await tx.claim(owner,'offline-action','executing','2026-10-12T00:00:00Z')).status,'executing');await c.query('COMMIT');c.release();
});
test('foundation bootstrapScope, saveScope and relational put preserve object JSON through the same adapter',async()=>{
 const f=fixture(),repository=new PostgresRepository(f.pool),identity={scope_id:input.subject_id,profile_id:input.subject_id,workspace_id:input.session_id,owner:'catpaw:offline-foundation'};
 await repository.bootstrapScope(identity);
 await repository.transaction(identity.scope_id,async tx=>{const scope=await tx.scope();await tx.saveScope({...scope,last_sequence:1});await tx.put('conversations',{id:input.session_id,scope_id:identity.scope_id,title:'Offline fixture'});});
 assert.equal(f.committed.scopes.get(identity.scope_id).last_sequence,1);assert.ok([...f.committed.records.values()].some(x=>x.title==='Offline fixture'));
});
test('initial provisioning fails with old binding; corrected binding commits and refresh resolves the same scope',async()=>{
 const old=fixture({legacy:true}),oldAuthority=new AppScopeAuthority(old.pool,{diagnostic:x=>old.diagnostics.push(x)});
 await assert.rejects(oldAuthority.resolve(input),e=>e.code==='scope_store_unavailable');assert.deepEqual(old.diagnostics,[{event:'catpaw_scope_resolve_failed',phase:'scope_insert',sqlstate:'23502'}]);assert.equal(old.committed.scopes.size,0);
 const f=fixture(),authority=new AppScopeAuthority(f.pool,{diagnostic:x=>f.diagnostics.push(x)});
 const first=await authority.resolve(input),refresh=await authority.resolve({...input,issued_at:2});assert.deepEqual(first.scopes,refresh.scopes);assert.equal(first.session_active,true);assert.equal(f.committed.scopes.size,1);assert.equal(f.committed.records.size,2);assert.deepEqual(f.diagnostics,[]);assert.equal(f.released,2);
 assert.ok(f.calls.includes("SET LOCAL statement_timeout='5000ms'"));assert.ok(f.calls.includes("SET LOCAL lock_timeout='1500ms'"));assert.ok(f.calls.includes("SET LOCAL idle_in_transaction_session_timeout='8000ms'"));
});
test('SQL failure emits only static phase and SQLSTATE; rolls back and releases without exposing error properties',async()=>{
 const f=fixture({failInsert:true}),authority=new AppScopeAuthority(f.pool,{diagnostic:x=>f.diagnostics.push(x)});
 await assert.rejects(authority.resolve(input),e=>e.status===503&&e.code==='scope_store_unavailable');
 assert.deepEqual(f.diagnostics,[{event:'catpaw_scope_resolve_failed',phase:'scope_insert',sqlstate:'23502'}]);assert.equal(f.committed.records.size,0);assert.ok(f.calls.includes('ROLLBACK'));assert.equal(f.released,1);
 const encoded=JSON.stringify(f.diagnostics);assert.ok(!encoded.includes(input.subject_id));assert.ok(!encoded.includes(input.issuer));assert.ok(!encoded.includes('sensitive'));assert.ok(!encoded.includes('private parameter'));
});
test('connection failure is classified safely and existing revoked session remains denied',async()=>{
 const diagnostics=[],authority=new AppScopeAuthority({connect:async()=>{throw Object.assign(Error('secret connection string'),{code:'ECONNRESET'});}},{diagnostic:x=>diagnostics.push(x)});
 await assert.rejects(authority.resolve(input),e=>e.status===503&&e.code==='scope_store_unavailable');assert.deepEqual(diagnostics,[{event:'catpaw_scope_resolve_failed',phase:'connect',sqlstate:null}]);
 const f=fixture(),a=new AppScopeAuthority(f.pool,{diagnostic:x=>f.diagnostics.push(x)});await a.resolve(input);
 const session=[...f.committed.records.values()].find(x=>x.id===input.session_id);session.state='revoked';await assert.rejects(a.resolve(input),e=>e.status===401&&e.code==='session_revoked');assert.deepEqual(f.diagnostics,[]);
});
test('startup read-only probe uses the same driver adapter and refuses a mismatched JSON contract',async()=>{
 let reads=0,releases=0,bad=false;
 const reserved={typed:driver.typed,release(){releases++;},async unsafe(sql,args){
  assert.ok(sql.startsWith('SELECT '),'Only read-only SELECT statements are permitted');reads++;
  if(sql.includes('pg_has_role'))return [{rolsuper:false,rolbypassrls:false,owns_records:false,records_cap:true,auth_cap:true}];
  const values=args.map(x=>JSON.parse(wire(x,3802))),keys=['object_type','array_type','string_type','null_type'];
  const types=values.map(v=>v===null?'null':Array.isArray(v)?'array':typeof v);if(bad)types[0]='string';return [Object.fromEntries(keys.map((k,i)=>[k,types[i]]))];
 }};
 const pool=pgCompatiblePool({reserve:async()=>reserved});await verifyDedicatedPool(pool);assert.equal(reads,2);assert.equal(releases,1);
 bad=true;await assert.rejects(verifyDedicatedPool(pool),/postgres_json_binding_contract_failed/);assert.equal(releases,2);
});
