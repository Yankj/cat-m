// catpaw-connectors — v1.1 Gmail connector entry. INERT: without CATPAW_GOOGLE_OAUTH_CLIENT_ID + CATPAW_CONNECTOR_TOKEN_KEY every
// mutating route returns 503 connector_not_configured. Not deployed; real ports (Google token endpoint, PG store) land in M2.
import { readConnectorConfig, connectorStatus, handleLink, handleUnlink } from '../_shared/connectors/gmail-connector.mjs';
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const notConfigured = async () => { throw new Error('connector_port_not_implemented'); };
const ports = { exchangeCode: notConfigured, revoke: notConfigured, store: notConfigured, remove: notConfigured };
Deno.serve(async req => {
  const cfg = readConnectorConfig((n: string) => Deno.env.get(n));
  const subjectID = null; // M2: Supabase JWT verification (createSupabaseTokenVerifier) supplies subjectID
  const path = new URL(req.url).pathname.replace(/^.*\/catpaw-connectors/, '');
  if (req.method === 'GET' && path === '/v1/connectors/gmail') return json(200, connectorStatus(cfg, subjectID));
  if (!cfg.configured) return json(503, { error: 'connector_not_configured' });
  if (!subjectID) return json(401, { error: 'unauthorized' });
  if (req.method === 'POST' && path === '/v1/connectors/gmail/link') { const r = await handleLink(cfg, { subjectID }, await req.json().catch(() => null), ports); return json(r.status, r.body); }
  if (req.method === 'DELETE' && path === '/v1/connectors/gmail') { const r = await handleUnlink(cfg, { subjectID }, ports); return json(r.status, r.body); }
  return json(404, { error: 'not_found' });
});
