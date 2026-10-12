import { startSyntheticServer } from '../src/server.mjs';
const local=await startSyntheticServer({port:0,path:process.argv[2]});
console.log(JSON.stringify({origin:local.origin}));
process.once('SIGTERM',()=>void local.close().then(()=>process.exit(0)));
