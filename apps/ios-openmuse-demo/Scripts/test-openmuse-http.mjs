import {spawn} from 'node:child_process';
import {resolve} from 'node:path';
import {mkdir,readFile,writeFile,stat} from 'node:fs/promises';
import {once} from 'node:events';
const root=resolve(process.argv[2]??'.'), backend=resolve(process.argv[3]??resolve(root,'../../services/facade'));
const runRoot=resolve(root,'.build/openmuse-http/run-'+Date.now());
await mkdir(resolve(runRoot,'client'),{recursive:true});await mkdir(resolve(runRoot,'server'),{recursive:true});
let owned;
async function stop(){if(!owned)return;const child=owned;owned=null;if(child.exitCode===null){child.kill('SIGTERM');const [code]=await once(child,'exit');if(code!==0)throw new Error('Owned facade cleanup failed '+code);}}
async function start(index){
  const child=spawn(process.execPath,['--experimental-transform-types',resolve(root,'Scripts/openmuse-loopback.mjs'),backend,'8796',resolve(runRoot,'server/synthetic-records.json'),resolve(runRoot,`server-${index}.json`)],{stdio:['ignore','pipe','pipe']});owned=child;
  let text='',error='';child.stderr.on('data',d=>{error+=d;});
  const ready=await new Promise((ok,fail)=>{
    const timeout=setTimeout(()=>fail(new Error('Local facade readiness timeout')),15000);
    child.stdout.on('data',d=>{text+=d;for(const line of text.split('\n')){try{const v=JSON.parse(line);if(v.ready){clearTimeout(timeout);ok(v);return;}}catch{}}});
    child.once('exit',code=>{clearTimeout(timeout);fail(new Error('Facade failed before ready '+code+': '+error));});
  });return ready;
}
const phases=['admit-lost','restore','decide-unknown','read-receipt'];const results=[];
try{
  for(let i=0;i<phases.length;i++){
    const server=await start(i+1);console.log('server_started '+JSON.stringify(server));
    const output=resolve(runRoot,phases[i]+'.json');
    const client=spawn(resolve(root,'.build/openmuse-http/client-runner'),[phases[i],server.origin,resolve(runRoot,'client'),output],{stdio:['ignore','pipe','pipe']});
    let stdout='',stderr='';client.stdout.on('data',d=>{stdout+=d;});client.stderr.on('data',d=>{stderr+=d;});
    const [code]=await once(client,'exit');await writeFile(resolve(runRoot,phases[i]+'.log'),stdout+stderr);
    if(code!==0)throw new Error('Native Swift HTTP phase '+phases[i]+' failed: '+stderr);
    results.push(JSON.parse(await readFile(output,'utf8')));console.log('client_pass '+phases[i]);
    await stop();console.log('owned_server_stopped '+(i+1));
  }
  const taskIDs=results.map(x=>x.task_id).filter(x=>x!=='unresolved');if(new Set(taskIDs).size!==1)throw new Error('Stable task identity changed across restarts');
  const summary={status:'passed',client_processes:4,server_processes:4,same_isolated_data_file:true,runRoot,results,all_owned_servers_stopped:true,Intelligence_calls:0,real_model_calls:0,external_writes:0};
  await writeFile(resolve(runRoot,'summary.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify({status:'passed',runRoot,server_processes:4,client_processes:4,cleanup:'all_owned_servers_stopped'}));
}finally{await stop();}
