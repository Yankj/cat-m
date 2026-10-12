import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import dns from 'node:dns';
const denied=()=>{throw Error('QA external network forbidden');};
globalThis.fetch=denied;net.connect=denied;net.createConnection=denied;net.Socket.prototype.connect=denied;
http.request=denied;http.get=denied;https.request=denied;https.get=denied;
dns.lookup=denied;dns.resolve=denied;
