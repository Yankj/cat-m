// Read-only, pinned Git blob audit. Exact lines are evidence anchors, not semantic proofs.
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {assertPinnedSources} from './source-pin.mjs';
const source='789ad4feceb0680b8e2e5913083c5b834dc63db1',contract='2419db9b98e2e3bc0e8c850da62418d216fd3bb8';
const blob=(sha,path)=>execFileSync('git',['show',`${sha}:${path}`],{encoding:'utf8'});
const entries=[
 ['ST-01','services/edge/supabase/functions/_shared/authority.mjs','check(session?.subject_id===source.subject_id','Current source checks session and scope membership, not proposed family membership.'],
 ['ST-02','services/edge/supabase/functions/_shared/authority.mjs','auth_service_unavailable','Official-user verifier distinguishes availability from identity rejection.'],
 ['ST-03','services/edge/supabase/migrations/20261016110000_feature_enrollment.sql','create policy memories_catpaw_api','catpaw_records memory policy permits all rows; application query scoping remains critical.'],
 ['ST-04','services/edge/supabase/functions/_shared/agent-memory/pg-store.mjs','where user_id=$1 and id=$2 returning','Content UPDATE scoped by user and id, without content revision CAS.'],
 ['ST-05','services/edge/supabase/functions/_shared/agent-memory/pg-store.mjs','delete from agent_memory.journal_fragments where day=$1 returning','Journal claims destructively delete fragments before service save.'],
 ['ST-06','services/edge/supabase/functions/_shared/agent-memory/service.mjs','source_conversation_id: ctx.conversation_id','Basic memory sources are optional; correction does not rebuild source chain.'],
 ['ST-07','services/edge/supabase/functions/_shared/agent-memory/service.mjs','verifyUser(req.headers.get','All verifyUser failures collapse to null and unauthorized in this route.'],
 ['ST-08','services/edge/supabase/functions/_shared/proactive/service.mjs',"log('error', e.stack ?? e.message)",'Raw error content may enter logger arguments.'],
 ['ST-09','services/edge/supabase/functions/catpaw-proactive/index.ts','log:','Runtime uses console logging for proactive service.'],
 ['ST-10','apps/ios-conversation/Sources/Features/ConversationSessionService.swift','privacy: .public','Native public logging contains payload/error descriptions; inspect selected anchors below.'],
 ['ST-11','apps/ios-conversation/Sources/Domain/ConversationSessionContracts.swift','textDelta(messageID:','Native stream payload can contain user-visible text.'],
 ['ST-12','services/edge/supabase/functions/_shared/core/src/device-effect-service.mjs','can_redispatch:false','Device effect unknown state is not a redispatch permit.'],
 ['ST-13','services/edge/supabase/functions/_shared/proactive/decision.mjs','idemGet','Idempotency wrapper read, execute and put require real PG concurrency proof.'],
 ['ST-14','services/edge/supabase/functions/_shared/core/integration/server-foundation/src/foundation.mjs','previous_source_ref','Source-backed memory has a separate versioned correction mechanism.'],
 ['ST-15','services/edge/supabase/functions/_shared/core/src/memory-service.mjs','user_direct','Source-backed memory checks direct current-user source.'],
 ['ST-16','services/edge/supabase/functions/_shared/agent-memory/contract.mjs','Separate from the source-backed','Two current memory contracts must not share acceptance credit.'],
];
const sourcePin=assertPinnedSources(entries.map(e=>e[1]));
const results=entries.map(([id,path,pattern,meaning])=>{const content=blob(source,path),lines=content.split('\n');const hits=lines.flatMap((text,i)=>text.includes(pattern)?[{line:i+1,text}]:[]);return {id,source_sha:source,path,sha256:createHash('sha256').update(content).digest('hex'),pattern,matched:hits.length>0,evidence_class:'STATIC',acceptance_status:'NOT_RUN',meaning,hits:id==='ST-10'?hits.filter(x=>[351,684,695].includes(x.line)):hits};});
assert.ok(results.every(x=>x.matched),'all static anchors must resolve');
const tree=execFileSync('git',['ls-tree','-r','--name-only',source,'services/edge/supabase/functions','services/edge/supabase/migrations'],{encoding:'utf8'}).split('\n');
const familyModule=tree.filter(p=>p.includes('/_shared/family/'));
const api=blob(source,'services/edge/supabase/functions/_shared/api.mjs');
const docs=['docs/architecture/family-companion-technical-plan.md','docs/design/family-companion/execution-goal.md','docs/design/family-companion/README.md'].map(path=>({source_sha:contract,path,sha256:createHash('sha256').update(blob(contract,path)).digest('hex')}));
console.log(JSON.stringify({...sourcePin,contract_sha:contract,scope:'Read-only Git blob anchors; no database or runtime semantic claims.',family_module_paths:familyModule,family_v1_route_literal_present:api.includes('/catpaw/family/v1'),anchor_total:results.length,all_patterns_located:results.every(x=>x.matched),results,contract_sources:docs},null,2));
