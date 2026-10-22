// Fail closed before importing any maintenance source. No host credentials are read.
import net from 'node:net';
import tls from 'node:tls';
import http from 'node:http';
import https from 'node:https';
import http2 from 'node:http2';
import dgram from 'node:dgram';
import dns from 'node:dns';
import {syncBuiltinESMExports} from 'node:module';

const attempts = [];
const denied = () => { attempts.push('network_denied'); throw Error('family_qa_network_forbidden'); };
globalThis.__familyQANetwork = {attempts, reset: () => { attempts.length = 0; }};
globalThis.fetch = denied;
globalThis.WebSocket = class { constructor() { denied(); } };
net.connect = net.createConnection = tls.connect = http.request = http.get = https.request = https.get = http2.connect = denied;
net.Socket.prototype.connect = dgram.Socket.prototype.send = denied;
for (const name of ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCaa', 'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr', 'resolveSoa', 'resolveSrv', 'resolveTxt', 'reverse']) {
  if (name in dns) dns[name] = denied;
  if (name in dns.promises) dns.promises[name] = denied;
}
syncBuiltinESMExports();
globalThis.Deno = {args: [], env: {get: () => undefined, has: () => false, toObject: () => ({})}};
