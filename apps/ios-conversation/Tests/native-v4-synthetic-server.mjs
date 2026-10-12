// Test composition only. Imports the frozen v4 backend; no backend edits or live model.
import http from 'node:http';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
const root=process.argv[2];
if(!root)throw Error('Explicit v4 backend directory required');
const load=relative=>import(pathToFileURL(path.join(root,relative)).href);
const {createFoundationChatRuntime}=await load('src/foundation-runtime.mjs');
const {TestRepository}=await load('integration/server-foundation/src/test-repository.mjs');
const {FakeProvider,authenticate,auth,scopeA,tools,call,text}=await load('test/harness.mjs');
// This boundary is deliberately test-only: every attempted fetch is denied.
globalThis.fetch=async()=>{throw Error('External fetch forbidden in native synthetic harness');};
const stop='保存一份完整的中文本地报告后停止';
const policy={schema_version:1,kind:'single_local_report',stop_condition:stop,required_sections:['衣物','雨具','随身物品'],required_context_ids:['synthetic-trip'],min_content_chars:200};
const content='衣物：带三套轻便衣物、保暖外套和舒适步行鞋。雨具：带折叠雨伞、防水外套与备用收纳袋。随身物品：检查证件、充电线、移动电源与常用药品。'+ '这是固定的合成旅行验收资料，仅用于原生客户端与现有 Worker 协议测试，不是模型生成建议。'.repeat(6);
const provider=new FakeProvider([
  text('这是来自 v4 合成后端的原生问答验收内容。'),
  tools(call('delegate_task',{title:'原生合成报告',goal:'根据明确给定的合成资料准备本地中文报告',requirements:'包含衣物、雨具、随身物品三个章节且不少于200字符',stop_conditions:[stop]})),
  tools(call('save_artifact',{title:'原生合成报告',summary:'仅供原生协议联调，模型调用为零',content}))
]);
const runtime=await createFoundationChatRuntime({repository:new TestRepository(),authenticate,provider,guardKey:'native-v4-synthetic-test-guard-only',dataClass:'synthetic',completionPolicy:policy,chatOptions:{finishOnDelegationReceipt:true},handlerOptions:{finishOnArtifactReceipt:true},workerOptions:{pollMs:10}});
await runtime.foundation.bootstrapScope(authenticate(auth),scopeA.scope_id);
let turnPosts=0;
const server=http.createServer(async(req,res)=>{
  try {
    if(req.headers.authorization!==auth){res.writeHead(401);return res.end('{}');}
    if(req.url==='/readyz'){res.writeHead(200,{'Content-Type':'application/json'});return res.end(JSON.stringify({ready:true,test_only:true,live_model_calls:0}));}
    if(req.url==='/native-v4-test/stats'){res.writeHead(200,{'Content-Type':'application/json'});return res.end(JSON.stringify({turnPosts,synthetic_provider_calls:provider.inputs.length,live_model_calls:0}));}
    if(req.method==='POST'&&req.url.endsWith('/turns'))turnPosts++;
    let size=0;const chunks=[];
    for await(const x of req){size+=x.length;if(size>42000)throw Error('request too large');chunks.push(x);}
    const abort=new AbortController();res.on('close',()=>abort.abort());
    const request=new Request('http://127.0.0.1'+req.url,{method:req.method,headers:req.headers,signal:abort.signal,...['GET','HEAD'].includes(req.method)?{}:{body:Buffer.concat(chunks)}});
    const response=await runtime.fetchHandler(request);res.writeHead(response.status,Object.fromEntries(response.headers));
    if(response.body)for await(const x of response.body){if(res.destroyed)break;res.write(x);}
    if(!res.destroyed)res.end();
  }catch{if(!res.headersSent)res.writeHead(500);if(!res.destroyed)res.end('{}');}
});
await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
runtime.worker.start();
process.stdout.write('ORIGIN=http://127.0.0.1:'+server.address().port+'\n');
process.on('SIGTERM',()=>{void (async()=>{await runtime.chat.waitIdle();await runtime.worker.stop();await new Promise(r=>server.close(r));process.exit(0);})();});
