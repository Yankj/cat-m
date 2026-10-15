#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/revision-work-tests .build/module-cache
# Import deterministic maintained contract helpers; no handler, server, Auth or provider is started.
node --input-type=module - .build/revision-work-tests/node-goldens.json <<'JS'
import {writeFileSync} from 'node:fs';
import {canonical,hash} from '../../services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {taskRevisionReceiptHash} from '../../services/edge/supabase/functions/_shared/core/src/task-revision-contract.mjs';
import {validateTaskRevisionWorkRequest,validatePublicRevisionWorkReceipt,revisionWorkReceiptHash,revisionWorkIntentHash} from '../../services/edge/supabase/functions/_shared/core/src/task-revision-work-contract.mjs';
const id=n=>`a1000000-b0c0-4d00-8e00-${String(n).padStart(12,'0')}`;
const scope=id(1),subject=id(2),conversation=id(3),turn=id(4),message=id(5),decision=id(6),run=id(7),route_hash=hash('synthetic-fixed-route'),source_auth_hash=hash('synthetic-original-source');
const binding={scope_id:scope,conversation_id:conversation,turn_id:id(8),call_id:'original-offline-call',delegation_id:id(9),operation_id:id(10),run_id:run,task_id:hash('synthetic-task'),request_hash:hash('synthetic-request'),delegation_revision:1,grant_epoch:1,projection_url:`/catpaw/tasks/v1/scopes/${scope}/runs/${run}`};
const target={intent:'revise_report',run_id:run,task_id:binding.task_id,artifact_reference:{artifact_id:hash('synthetic-artifact'),version:2,content_hash:hash('synthetic-base-content')},expected_grant_epoch:1,expected_plan_revision:3,expected_plan_hash:hash('synthetic-base-plan')};
const cases=['请保留原来源，并把结论改成可核对的三项。\n原文不改写 🐾','\ufeff A\u0085\u2028\u2029\n"\\/ 🇨🇳 e\u0301','é 与 e\u0301 字节分别保留，末尾空格  '].map((raw,index)=>{
 const t={turn_id:turn,expected_revision:7,expected_grant_epoch:2,message:{id:message,text:raw},context:[{id:'user-context',text:'保留来源与结论边界\nemoji 🐾'}]},input_hash=hash({turn:t,target}),target_hash=hash(target);
 const work={decision_id:decision,input_hash,route_hash,tool_policy:'public_sources_v1',not_after:'2026-10-15T05:30:00.000Z',execution_budget_ms:120000,limits:{due:1,model:3,source:2}};
 const wrapper={schema_version:1,contract:'catpaw.task-revision-work.v1',turn:t,target,work};validateTaskRevisionWorkRequest(wrapper);
 const call_id=`offline-revise-call-${index}`,digest=hash(`${turn}:${call_id}:catpaw.task-revision.v1`),operation_id=`${digest.slice(0,8)}-${digest.slice(8,12)}-4${digest.slice(13,16)}-8${digest.slice(17,20)}-${digest.slice(20,32)}`;
 const revision={operation_id,operation_hash:hash(`synthetic-revision-operation-${index}`),scope_id:scope,subject_id:subject,conversation_id:conversation,turn_id:turn,call_id,run_id:run,task_id:binding.task_id,base_reference:target.artifact_reference,base_plan_reference:{revision:3,plan_hash:target.expected_plan_hash},accepted_plan_reference:{revision:4,plan_hash:hash('synthetic-new-plan')},instruction_hash:hash(raw),source_auth_hash,fresh_source_auth_hash:hash('synthetic-fresh-source'),grant_epoch:1,accepted_at:'2026-10-15T05:00:00.000Z'};
 revision.receipt_hash=taskRevisionReceiptHash(revision);revision.state='accepted';
 const accepted={schema_version:1,contract:'catpaw.task-revision-work.v1',decision_id:decision,input_hash,target_hash,work_intent_hash:revisionWorkIntentHash(work),revision,grant_reference:{schema_version:2,contract:'catpaw.task-work-grant.v2',grant_id:decision,terms_hash:hash('synthetic-new-grant-terms')},grant_receipt_hash:hash('synthetic-new-grant-receipt')};accepted.receipt_hash=revisionWorkReceiptHash(accepted);validatePublicRevisionWorkReceipt(accepted);
 const completed=structuredClone(accepted);completed.revision.state='completed';completed.revision.result_reference={artifact_id:target.artifact_reference.artifact_id,version:3,content_hash:hash('synthetic-result')};completed.revision.result_receipt_hash=hash('synthetic-result-receipt');validatePublicRevisionWorkReceipt(completed);
 return {raw,wrapper:canonical(wrapper),input_hash,target_hash,work_intent_hash:hash(work),call_id,accepted,completed};
});
writeFileSync(process.argv[2],JSON.stringify({synthetic_only:true,scope,subject,conversation,turn,message,decision,route_hash,source_auth_hash,binding,target,cases},null,2)+'\n');
console.log(`PASS maintained Node validators: ${cases.length} request + accepted/completed goldens`);
JS
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache \
  Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift \
  Sources/Features/WorkspaceService.swift Tests/ConversationRevisionWorkRunner.swift -o .build/revision-work-tests/runner
.build/revision-work-tests/runner .build/revision-work-tests/node-goldens.json
