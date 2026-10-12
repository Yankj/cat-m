import {createLocalServer} from '../src/server.mjs';
import {mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve as resolvePath} from 'node:path';
import {spawn} from 'node:child_process';
const app=createLocalServer({statePath:join(mkdtempSync(join(tmpdir(),'catpaw-native-http-')),'state.json')});
await new Promise(resolve=>app.server.listen(0,'127.0.0.1',resolve));
try {
  const code=await new Promise((resolve,reject)=>{
    const child=spawn(process.argv[2]??resolvePath('.build/integration-gateway-tests'),['--http',String(app.server.address().port)],{stdio:'inherit'});
    child.on('error',reject);child.on('exit',resolve);
  });if(code!==0)throw new Error(`native contract tests failed (${code})`);
} finally {await new Promise(resolve=>app.server.close(resolve));}
