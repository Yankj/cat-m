import { createServer } from 'node:http';
import { resolve,dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FileRepository } from './file-repository.mjs';
import { createRuntime } from './runtime.mjs';
import { createFetchHandler } from './http.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
export async function startSyntheticServer({port=8787,path=resolve(root,'.runtime/synthetic-records.json'),runtime}={}) {
  if(!Number.isInteger(port)||port<0||port>65535)throw new Error('Invalid loopback port');
  runtime??=await createRuntime({repository:await FileRepository.open(path)});
  const handle=createFetchHandler(runtime.facade);
  const server=createServer(async(req,res)=>{
    try {
      const chunks=[];let size=0;
      for await(const chunk of req){size+=chunk.length;if(size>32768){res.writeHead(413,{'content-type':'application/json'});res.end(JSON.stringify({schema_version:1,error:{code:'request_too_large',message:'Request too large',retryable:false,reconciliation_required:false}}));return;}chunks.push(chunk);}
      const headers=new Headers();for(const [name,value] of Object.entries(req.headers))if(value!==undefined)headers.set(name,Array.isArray(value)?value.join(','):value);
      // Ignore Host as a routing/authentication input; fixed loopback origin.
      const request=new Request(`http://127.0.0.1${req.url}`,{method:req.method,headers,...(['GET','HEAD'].includes(req.method)?{}:{body:Buffer.concat(chunks)})});
      const response=await handle(request);res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));
    } catch { if(!res.headersSent)res.writeHead(500,{'content-type':'application/json'});res.end(JSON.stringify({schema_version:1,error:{code:'internal_error',message:'Request failed',retryable:false,reconciliation_required:false}})); }
  });
  await new Promise((ok,fail)=>{server.once('error',fail);server.listen(port,'127.0.0.1',ok);});runtime.worker.start();
  let closing;
  return {runtime,server,origin:`http://127.0.0.1:${server.address().port}`,close:()=>closing??=(async()=>{await runtime.worker.stop();await new Promise((ok,fail)=>server.close(e=>e?fail(e):ok()));})()};
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const port=process.argv[2]===undefined?8787:Number(process.argv[2]);
  const local=await startSyntheticServer({port});
  console.log(JSON.stringify({origin:local.origin,mode:'synthetic_loopback_only',worker:'pinned_OpenMuse_TaskWorker_with_captured_lease_event_patch',approval:'pinned_ActionService_with_preview_patch',repository:'single_process_atomic_file',intelligence:'unconfigured',model:'unconfigured'}));
  for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>void local.close().then(()=>process.exit(0)));
}
