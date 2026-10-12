import {resolve} from 'node:path';
import {DurableStore} from './store.mjs';
import {AssistantService} from './assistant.mjs';
import {LocalWorker} from './worker.mjs';
const args=process.argv.slice(2);
if(args.some(x=>!['--once','--loop'].includes(x))||args.includes('--once')&&args.includes('--loop'))throw new Error('Use --once (default) or --loop');
const service=new AssistantService(new DurableStore(resolve('local-data/state.json')));
const worker=new LocalWorker(service,{id:`local-cli-${process.pid}`});
let stopped=false;process.on('SIGINT',()=>{stopped=true;});process.on('SIGTERM',()=>{stopped=true;});
do {
  try {const result=await worker.tick();if(result.status!=='idle')process.stdout.write(JSON.stringify(result)+'\n');}
  catch(error){process.stderr.write(`Local worker: ${error.code??'failed'}\n`);}
  if(!args.includes('--loop')||stopped)break;
  await new Promise(resolve=>setTimeout(resolve,1000));
} while(!stopped);
