import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {membershipOwner,revokeAppSession} from '../supabase/functions/_shared/authority.mjs';
import {hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';

test('logout writes delegation and task under resource owner, preserving system-owner shadows and other sessions',async()=>{
 const repository=new TestRepository(),issuer='https://offline.example.invalid/auth/v1',sub=randomUUID(),sid=randomUUID();
 const scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()},owner=membershipOwner(issuer),resourceOwner=`catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`;
 await repository.transaction(async tx=>{
  await tx.put(owner,'scope-memberships',{id:sub,scopes:[scope]});
  for(const [id,session_id] of [['own',sid],['other',randomUUID()]]){
   await tx.put(resourceOwner,'catpaw-runs',{id,task_id:id,delegation_id:id,frozen_request:{subject_id:sub,source_auth:{session_id}}});
   await tx.put(resourceOwner,'catpaw-delegations',{id,state:'active',revision:1,grant_epoch:1});
   await tx.put(resourceOwner,'tasks',{id,status:'queued',leaseId:null,leaseUntil:null});
  }
  await tx.put(owner,'catpaw-delegations',{id:'own',state:'active',revision:7,grant_epoch:7});
  await tx.put(owner,'tasks',{id:'own',status:'queued',shadow:true});
 });
 await revokeAppSession(repository,{iss:issuer,sub,session_id:sid,exp:9999999999},{chat:{event(){throw Error('No chat turn in this fixture');}}});
 await repository.transaction(async tx=>{
  assert.equal((await tx.get(resourceOwner,'tasks','own')).status,'cancelled');
  const d=await tx.get(resourceOwner,'catpaw-delegations','own');assert.equal(d.state,'revoked');assert.equal(d.grant_epoch,2);
  assert.equal((await tx.get(resourceOwner,'tasks','other')).status,'queued');assert.equal((await tx.get(resourceOwner,'catpaw-delegations','other')).state,'active');
  assert.deepEqual(await tx.get(owner,'tasks','own'),{id:'own',status:'queued',shadow:true});
  assert.deepEqual(await tx.get(owner,'catpaw-delegations','own'),{id:'own',state:'active',revision:7,grant_epoch:7});
  assert.equal((await tx.get(owner,'app-sessions',sid)).state,'revoked');
 });
});
