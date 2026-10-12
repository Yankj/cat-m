// Imports only the explicitly supplied, committed pure validator. Never starts the API/provider.
import {pathToFileURL} from 'node:url';
import {readFileSync} from 'node:fs';
const [modulePath,payloadPath]=process.argv.slice(2);
if(!modulePath||!payloadPath)throw Error('Supply committed vision-contract.mjs and synthetic CodecSmoke output paths');
globalThis.fetch=()=>{throw Error('No network allowed');};
const {validateVisionTurn}=await import(pathToFileURL(modulePath));
const payloads=JSON.parse(readFileSync(payloadPath,'utf8'));
for(const payload of payloads){
 const result=validateVisionTurn(payload,{enabled:true});
 if(result.receipts.length!==1||result.receipts[0].width!==4||result.receipts[0].height!==8)throw Error('Unexpected receipt');
 if(result.input.message.attachments!==undefined)throw Error('Image bytes entered normalized message');
 console.log(`PASS server v2 pure validator: ${result.receipts[0].mime_type}, actual synthetic bytes/hash/container`);
}
