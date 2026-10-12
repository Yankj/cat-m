// Runs only the already delivered synthetic facade. No dependency installation or full upstream bootstrap.
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const [backend,portText,dataPath,pidFile]=process.argv.slice(2);
if(!backend||!dataPath||!pidFile||!/^\d+$/.test(portText))throw new Error('backend port isolated-data-path pid-file required');
const contract=await readFile(resolve(backend,'contract/native-contract-v1.json'));
if(createHash('sha256').update(contract).digest('hex')!=='08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9')throw new Error('Frozen contract changed');
const {startSyntheticServer}=await import(pathToFileURL(resolve(backend,'src/server.mjs')));
const local=await startSyntheticServer({port:Number(portText),path:resolve(dataPath)});
await writeFile(pidFile,JSON.stringify({pid:process.pid,origin:local.origin,data:resolve(dataPath),mode:'synthetic-facade-only'})+'\n');
console.log(JSON.stringify({ready:true,pid:process.pid,origin:local.origin,data:resolve(dataPath),model:'unconfigured',intelligence:'unconfigured'}));
for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>void local.close().then(()=>process.exit(0)));
