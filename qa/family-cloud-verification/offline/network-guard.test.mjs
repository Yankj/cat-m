import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import tls from 'node:tls';
import http from 'node:http';
import https from 'node:https';
import dns from 'node:dns';
import {check} from './helpers.mjs';

test('SAFE-01 offline guard rejects fetch, sockets, TLS, HTTP, HTTPS and DNS before transport', async t => {
  const probes = [
    () => fetch('https://family-fixture.invalid'),
    () => net.connect({host: 'family-fixture.invalid', port: 443}),
    () => tls.connect({host: 'family-fixture.invalid', port: 443}),
    () => http.get('http://family-fixture.invalid'),
    () => https.get('https://family-fixture.invalid'),
    () => dns.lookup('family-fixture.invalid', () => {}),
  ];
  for (const probe of probes) assert.throws(probe, /family_qa_network_forbidden/);
  const denied = globalThis.__familyQANetwork.attempts.length;
  globalThis.__familyQANetwork.reset();
  check(t, 'SAFE-01', {deniedBeforeTransport: denied}, {deniedBeforeTransport: 6}, {deniedBeforeTransport: 6}, 'These six intentional guard checks are blocked synchronously; maintenance tests must have zero attempted network calls.');
});
