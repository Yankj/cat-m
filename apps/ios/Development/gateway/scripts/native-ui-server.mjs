// Explicit synthetic-only native UI harness. No credentials, cloud worker or real model calls.
import { resolve } from 'node:path';
import { mkdirSync } from 'node:fs';
import { DurableStore } from '../src/store.mjs';
import { AssistantService } from '../src/assistant.mjs';
import { LocalWorker } from '../src/worker.mjs';
import { createLocalServer, DEMO_SCOPE } from '../src/server.mjs';
const directory = resolve(process.argv[2]);
mkdirSync(directory, { recursive: true });
let now = Date.now();
const service = new AssistantService(new DurableStore(resolve(directory, 'state.json')), { clock: () => now });
const delegation = service.createDelegation(DEMO_SCOPE, { title: 'Gateway UI 合成约定', goal: '仅整理合成输入供原生验收', requirements: '只保存本机合成草稿', stop_conditions: ['用户停止'], interval_ms: 3600000, model_id: 'qwen-beijing' }, 'native-ui-delegation-v1');
service.enqueue(DEMO_SCOPE, delegation.id, 'native-ui-run-v1');
await new LocalWorker(service).tick();
now += 3600000;
await new LocalWorker(service).tick();
const app = createLocalServer({ statePath: resolve(directory, 'state.json'), service });
app.server.listen(8787, '127.0.0.1', () => process.stdout.write('READY synthetic-only 127.0.0.1:8787; real_api_calls=0\n'));
process.on('SIGTERM', () => app.server.close(() => process.exit(0)));
