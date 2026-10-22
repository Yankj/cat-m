// Verification process only. Existing tests may replace fetch with synthetic stubs.
import net from 'node:net';
import tls from 'node:tls';
import http from 'node:http';
import https from 'node:https';
import http2 from 'node:http2';
import dns from 'node:dns';
import {syncBuiltinESMExports} from 'node:module';
const denied=()=>{throw new Error('CLOUD_VERIFICATION_NETWORK_FORBIDDEN');};
globalThis.fetch=denied;
globalThis.WebSocket=class {constructor(){denied();}};
net.connect=denied;
net.createConnection=denied;
net.Socket.prototype.connect=denied;
tls.connect=denied;
http.request=http.get=https.request=https.get=http2.connect=denied;
for(const name of Object.keys(dns)) if(/^(lookup|resolve|reverse)/.test(name)&&typeof dns[name]==='function') dns[name]=denied;
for(const name of Object.keys(dns.promises)) if(/^(lookup|resolve|reverse)/.test(name)&&typeof dns.promises[name]==='function') dns.promises[name]=denied;
syncBuiltinESMExports();
