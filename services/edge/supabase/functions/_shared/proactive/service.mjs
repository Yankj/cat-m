import { validateTaskCreate, validateTaskPatch, computeNextFire, isUUID, TASK_TOOLS, TASK_TOOL_CONTRACT } from './contract.mjs';
import { nextOccurrence, bad } from './recurrence.mjs';

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });
const TOKEN_KINDS = ['apns', 'live_activity_update', 'live_activity_start'];

export function createProactiveService({ store, verifyUser, schedulerSecret, model = null, apns = null, now = () => Date.now(), log = () => {} }) {
  async function user(req) {
    const p = await verifyUser(req.headers.get('authorization')).catch(e => { throw bad(e.code === 'auth_key_service_unavailable' ? e.code : 'session_required', e.status === 503 ? 503 : 401); });
    if (!isUUID(p?.sub)) throw bad('session_required', 401);
    return p.sub;
  }
  async function body(req) { const t = await req.text(); if (t.length > 32000) throw bad('request_too_large', 413); try { return t ? JSON.parse(t) : {}; } catch { throw bad('json_invalid', 400); } }

  async function createTask(uid, input, createdBy = 'user') {
    const v = validateTaskCreate(input);
    const task = { ...v, status: 'open', fire_count: 0, created_by: createdBy };
    task.next_fire_at = computeNextFire(task, now());
    const { row, created } = await store.createTask(uid, task);
    if (created) await store.insertEvent({ user_id: uid, task_id: row.id, conversation_id: row.conversation_id, kind: 'task_created', title: row.title, body: row.due_at ? `已设置提醒：${row.title}` : `已记下：${row.title}`, payload: { task: row, created_by: createdBy }, dedupe_key: 'created:' + row.id, push_state: 'skipped' });
    return { task: row, created };
  }
  async function patchTask(uid, id, input) {
    if (!isUUID(id)) throw bad('task_not_found', 404);
    const p = validateTaskPatch(input);
    const cur = await store.getTask(uid, id); if (!cur) throw bad('task_not_found', 404);
    if (p.expected_revision != null && p.expected_revision !== cur.revision) throw bad('revision_conflict', 409);
    const { expected_revision, ...fields } = p;
    const merged = { ...cur, ...fields };
    if (fields.recurrence !== undefined && merged.recurrence && !merged.due_at) throw bad('recurrence_requires_due_at');
    fields.next_fire_at = computeNextFire(merged, now());
    if (merged.status !== 'snoozed') fields.snooze_until = null;
    const row = await store.updateTask(uid, id, fields, cur.revision);
    if (!row) throw bad('revision_conflict', 409);
    return row;
  }
  /** Agent tool executor. Called by the conversation dispatcher with the authenticated user id. */
  async function executeTool(uid, call, ctx = {}) {
    const { name } = call; let args = call.arguments;
    if (typeof args === 'string') { try { args = JSON.parse(args || '{}'); } catch { return { ok: false, error: 'arguments_invalid' }; } }
    args ??= {};
    try {
      if (name === 'create_task') {
        const opId = ctx.operation_id ?? args.operation_id; if (!isUUID(opId)) throw bad('operation_id_invalid');
        const { task, created } = await createTask(uid, { ...args, operation_id: opId, conversation_id: ctx.conversation_id ?? null, source_turn_id: ctx.turn_id ?? null }, 'agent');
        return { ok: true, created, task: summary(task) };
      }
      if (name === 'update_task') { const { task_id, ...rest } = args; return { ok: true, task: summary(await patchTask(uid, task_id, rest)) }; }
      if (name === 'list_tasks') { const rows = await store.listTasks(uid, { status: args.status ?? 'open', limit: Math.min(args.limit ?? 20, 50) }); return { ok: true, tasks: rows.map(summary) }; }
      return { ok: false, error: 'unknown_tool' };
    } catch (e) { return { ok: false, error: e.code ?? 'tool_failed' }; }
  }

  async function tick() {
    const at = now(), claimed = await store.claimDue(new Date(at).toISOString(), 50), results = [];
    for (const c of claimed) {
      try { results.push(await fire(c, at)); }
      catch (e) { log('fire_failed', c.task_id, e.stack ?? e.message); await store.finishOccurrence(c, { next_fire_at: null, fire_count: c.fire_count + 1, status: 'open' }).catch(() => {}); results.push({ task_id: c.task_id, error: 'fire_failed' }); }
    }
    const push = await flushPush();
    return { claimed: claimed.length, results, push };
  }
  async function fire(c, at) {
    {
      const fired = c.fire_count + 1;
      let text = null, source = 'template';
      if (model) { try { text = await model.reminder(c, at); if (text) source = 'model'; } catch (e) { log('model_failed', e.message); } }
      text ||= fallbackText(c);
      const ev = await store.insertEvent({ user_id: c.user_id, task_id: c.task_id, conversation_id: c.conversation_id, kind: 'reminder_due', title: c.title, body: text, payload: { scheduled_at: c.scheduled_at, due_at: c.due_at, occurrence: fired, source, actions: ['done', 'snooze_10m', 'snooze_1h', 'open_conversation'] }, dedupe_key: `due:${c.task_id}:${c.scheduled_at}` });
      const next = nextOccurrence(c.due_at ?? c.scheduled_at, c.recurrence, c.time_zone, Math.max(at, Date.parse(c.scheduled_at)), fired);
      await store.finishOccurrence(c, { next_fire_at: next, fire_count: fired, status: next ? 'open' : (c.recurrence ? 'done' : 'open') });
      return { task_id: c.task_id, event_id: ev?.id ?? null, next_fire_at: next, source };
    }
  }
  async function flushPush(limit = 100) {
    const pending = await store.pendingPushEvents(limit); const out = { sent: 0, skipped: 0, failed: 0, no_device: 0 };
    for (const ev of pending) {
      const tokens = (await store.tokensFor(ev.user_id)).filter(t => t.enabled);
      if (!tokens.length) { await store.setPush(ev.id, 'no_device', null); out.no_device++; continue; }
      if (!apns?.configured) { await store.setPush(ev.id, 'skipped', 'apns_not_configured'); out.skipped++; continue; }
      let ok = false, err = null;
      for (const t of tokens) {
        const r = await apns.send(t, ev).catch(e => ({ ok: false, reason: e.message }));
        if (r.ok) ok = true; else { err = r.reason; if (r.unregistered) await store.disableToken(t.id, r.reason); }
      }
      await store.setPush(ev.id, ok ? 'sent' : 'failed', ok ? null : err); ok ? out.sent++ : out.failed++;
    }
    return out;
  }

  async function route(req) {
    const url = new URL(req.url), path = url.pathname.replace(/^.*\/catpaw-proactive/, '') || '/', m = req.method;
    if (m === 'OPTIONS') return new Response(null, { status: 204 });
    if (path === '/health') return json(200, { ok: true, contract: TASK_TOOL_CONTRACT, apns: !!apns?.configured, model: !!model });
    if (path === '/scheduler/tick' && m === 'POST') {
      if (!schedulerSecret || req.headers.get('x-catpaw-scheduler-secret') !== schedulerSecret) throw bad('forbidden', 403);
      return json(200, await tick());
    }
    if (path === '/tools' && m === 'GET') return json(200, { contract: TASK_TOOL_CONTRACT, tools: TASK_TOOLS });
    const uid = await user(req);
    if (path === '/tasks' && m === 'GET') return json(200, { tasks: await store.listTasks(uid, { status: url.searchParams.get('status') ?? 'open', limit: Math.min(Number(url.searchParams.get('limit')) || 50, 200) }) });
    if (path === '/tasks' && m === 'POST') { const r = await createTask(uid, await body(req)); return json(r.created ? 201 : 200, r); }
    let mm = path.match(/^\/tasks\/([^/]+)$/);
    if (mm && m === 'GET') { const t = isUUID(mm[1]) && await store.getTask(uid, mm[1]); if (!t) throw bad('task_not_found', 404); return json(200, { task: t }); }
    if (mm && m === 'PATCH') return json(200, { task: await patchTask(uid, mm[1], await body(req)) });
    if (mm && m === 'DELETE') return json(200, { task: await patchTask(uid, mm[1], { status: 'cancelled' }) });
    if (path === '/tools/execute' && m === 'POST') { const b = await body(req); return json(200, await executeTool(uid, b.call ?? {}, b.context ?? {})); }
    if (path === '/events' && m === 'GET') { const after = url.searchParams.get('after'); return json(200, { events: await store.listEvents(uid, after && Number.isFinite(Date.parse(after)) ? new Date(after).toISOString() : null, Math.min(Number(url.searchParams.get('limit')) || 50, 200)) }); }
    mm = path.match(/^\/events\/([^/]+)\/read$/);
    if (mm && m === 'POST') { if (!isUUID(mm[1])) throw bad('event_not_found', 404); return json(200, { ok: await store.markRead(uid, mm[1], new Date(now()).toISOString()) }); }
    if (path === '/devices/tokens' && m === 'PUT') {
      const b = await body(req);
      if (typeof b.device_id !== 'string' || !b.device_id || b.device_id.length > 200 || !TOKEN_KINDS.includes(b.kind) || typeof b.token !== 'string' || !/^[0-9a-fA-F]{32,400}$/.test(b.token) || !['sandbox', 'production'].includes(b.environment ?? 'sandbox') || typeof b.bundle_id !== 'string' || !b.bundle_id) throw bad('token_invalid');
      return json(200, { token: await store.upsertToken(uid, { device_id: b.device_id, kind: b.kind, token: b.token.toLowerCase(), environment: b.environment ?? 'sandbox', bundle_id: b.bundle_id, activity_id: b.activity_id ?? null }) });
    }
    if (path === '/devices/tokens' && m === 'DELETE') { const b = await body(req); return json(200, { removed: await store.deleteToken(uid, String(b.device_id ?? ''), b.kind ?? null) }); }
    throw bad('not_found', 404);
  }
  return {
    tick, flushPush, executeTool, createTask, patchTask,
    async handle(req) { try { return await route(req); } catch (e) { const s = e.status ?? 500; if (s >= 500) log('error', e.stack ?? e.message); return json(s, { error: s >= 500 && !e.status ? 'internal_error' : (e.code ?? 'error') }); } },
  };
}
const summary = t => ({ id: t.id, title: t.title, due_at: t.due_at, time_zone: t.time_zone, status: t.status, recurrence: t.recurrence, next_fire_at: t.next_fire_at, revision: t.revision });
export function fallbackText(c) { return c.notes ? `提醒：${c.title}\n${c.notes}` : `提醒：${c.title}`; }
