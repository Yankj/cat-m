// From repository root: node qa/family-cloud-verification/run-existing-offline.mjs
// Uses only built-ins and the existing Node harness, never installs dependencies.
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const edge=new URL('../../services/edge/',import.meta.url);
const guard=fileURLToPath(new URL('./offline-guard.mjs',import.meta.url));
const files=[
  'agent-memory','agent-memory-settings-seq','memory-claim-honesty',
  'memory-http','conversation-memory-http','memory-extraction-service',
  'context-window','turn-cancel','chat-runtime-lease',
  'task-action','task-work-grant-lifecycle','approval',
  'proactive-throttle','proactive-apns-payload','proactive-gate-default',
  'proactive-decision','proactive-provider-consent','proactive-lead-minutes',
  'proactive-codex-pr90i-replay','device-effect',
].map(name=>`test/${name}.test.mjs`);
console.error(JSON.stringify({base_sha:'789ad4feceb0680b8e2e5913083c5b834dc63db1',runtime:process.version,files:files.length,layer:'offline Node, in-memory stores; missing npm packages use existing inert stubs',root_alias:'cloud-verify'}));
const result=spawnSync(process.execPath,['--no-warnings','--import',guard,'--import','./test/support/node-strip-loader.mjs','--test',...files],{
  cwd:edge,env:{PATH:process.env.PATH,TZ:'UTC',LANG:'C.UTF-8'},stdio:'inherit',timeout:120000,
});
if(result.error) console.error(result.error.message);
process.exitCode=result.status??1;
