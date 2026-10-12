import {DurableStore} from '../src/store.mjs';
import {AssistantService} from '../src/assistant.mjs';
const [mode,path]=process.argv.slice(2);
const store=new DurableStore(path),service=new AssistantService(store,{clock:()=>1000000000000});
if(mode==='claim') {try {const c=service.claim(`child-${process.pid}`,60000);process.stdout.write(JSON.stringify(c?{run:c.run.id,token:c.token}:null));} catch(e){process.stdout.write(JSON.stringify({code:e.code}));}}
if(mode==='crash-after-call'){const c=service.claim(`child-${process.pid}`,60000);service.beginModelCall(c);process.exit(86);}
if(mode==='crash-in-transaction')store.transact(()=>process.exit(87));
