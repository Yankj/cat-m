// POST /households/{id}/captures — turn a parent's text (v0.2) or notice photo (v0.3) into confirm cards.
// Every candidate becomes item.propose (status needs_confirmation, never schedule). Command ids are derived from
// capture_id, so a retried capture returns the same receipts instead of duplicating cards (api-v1 §5).
import { FamilyError, UUID_RE, PROTOCOL } from './contract.mjs';
import { extractItemsFromText } from './extract-text.mjs';

export async function derivedId(captureId, n) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`catpaw.family.capture:${captureId}:${n}`))).slice(0, 16);
  d[6] = (d[6] & 0x0f) | 0x50; d[8] = (d[8] & 0x3f) | 0x80;
  const h = [...d].map(b => b.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

const SOURCE_KIND = { text: 'user_text', voice_transcript: 'user_voice_transcript', image: 'notification_extract' };

export function createCaptureRoute({ extractors = {} } = {}) {
  const ex = { text: async ({ text }, ctx) => extractItemsFromText(text, ctx), ...extractors };
  return async ({ req, actor, hh, sub, ctx }) => {
    if (sub !== '/captures' || req.method !== 'POST') return null;
    const b = await ctx.body(req);
    if (!b || typeof b.capture_id !== 'string' || !UUID_RE.test(b.capture_id) || !SOURCE_KIND[b.kind]) throw new FamilyError(422, 'command_invalid');
    if ((b.kind === 'text' || b.kind === 'voice_transcript') && (typeof b.text !== 'string' || !b.text.trim() || b.text.length > 2000)) throw new FamilyError(422, 'command_invalid');
    const fn = ex[b.kind === 'voice_transcript' ? 'text' : b.kind];
    if (!fn) throw new FamilyError(422, 'capability_unavailable');
    const p = await ctx.store.projection(actor, hh, ctx.todayIn('Asia/Shanghai', ctx.now()));
    if (!p) throw new FamilyError(404, 'not_found');
    const today = ctx.todayIn(p.timezone, ctx.now());
    const children = p.home.children.map(c => ({ member_id: c.member_id, display_name: c.display_name }));
    let cands;
    try { cands = await fn(b, { today, children, timezone: p.timezone }); }
    catch (e) { if (e instanceof FamilyError) throw e; throw new FamilyError(503, 'extract_unavailable', { retryable: true }); }
    const cards = [];
    for (const [n, c] of (cands ?? []).slice(0, 5).entries()) {
      const payload = { title: c.title, member_id: c.member_id ?? null, local_date: c.local_date ?? null, local_time: c.local_time ?? null,
        place: c.place ?? null, bring: c.bring ?? [], notes: c.notes ?? null, capture_id: b.capture_id,
        source: { source_kind: SOURCE_KIND[b.kind], source_ref: `capture:${b.capture_id}:${n}`, captured_at: new Date(ctx.now()).toISOString() } };
      const receipt = await ctx.apply(actor, { command_id: await derivedId(b.capture_id, n), household_id: hh, type: 'item.propose', proposal_id: await derivedId(b.capture_id, `p${n}`), target_id: await derivedId(b.capture_id, `i${n}`), payload }, hh);
      cards.push({ receipt, item_id: receipt.objects?.find(o => o.type === 'item')?.id ?? null, proposal_id: receipt.objects?.find(o => o.type === 'proposal')?.id ?? null,
        candidate: { ...payload, source: undefined, missing: ['local_date', 'local_time', 'member_id'].filter(k => payload[k] == null) } });
    }
    return new Response(JSON.stringify({ protocol: PROTOCOL, schema_version: 1, capture_id: b.capture_id, cards }), { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
  };
}
