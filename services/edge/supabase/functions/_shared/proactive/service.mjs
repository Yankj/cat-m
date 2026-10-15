import { validateTaskCreate, validateTaskPatch, computeNextFire, isUUID, TASK_TOOLS, TASK_TOOL_CONTRACT } from './contract.mjs';
import { nextOccurrence, bad } from './recurrence.mjs';
import { isQuiet, quietEndsAt, localDayStart, isExempt } from './throttle.mjs';

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });
const PUSH_ACTIONS = ['open', 'done', 'snooze_10m', 'snooze_1h', 'dismiss'];
const TOKEN_KINDS = ['apns', 'live_activity_update', 'live_activity_start'];

export function createProactiveService({ store, verifyUser, schedulerSecret, model = null, apns = null, decision = null, quietHours = { start: 22, end: 8 }, dailyPushCap = 5, defaultTimeZone = 'Asia/Shanghai', now = () => Date.now(), log = () => {} }) {
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
    const resurfaced = store.resurfaceSnoozed ? await store.resurfaceSnoozed(new Date(at).toISOString()) : [];
    const push = await flushPush();
    return { claimed: claimed.length, results, resurfaced: resurfaced.length, push };
  }
  async function fire(c, at) {
    {
      const fired = c.fire_count + 1;
      let text = null, source = 'template';
      if (model) { try { text = await model.reminder(c, at); if (text) source = 'model'; } catch (e) { log('model_failed', e.message); } }
      text ||= fallbackText(c);
      const owner = await store.getTask(c.user_id, c.task_id).catch(() => null);
      const ev = await store.insertEvent({ user_id: c.user_id, task_id: c.task_id, conversation_id: c.conversation_id, kind: 'reminder_due', title: c.title, body: text, payload: { scheduled_at: c.scheduled_at, due_at: c.due_at, occurrence: fired, source, created_by: owner?.created_by ?? 'user', time_zone: c.time_zone, actions: ['done', 'snooze_10m', 'snooze_1h', 'open_conversation'] }, dedupe_key: `due:${c.task_id}:${c.scheduled_at}` });
      const next = nextOccurrence(c.due_at ?? c.scheduled_at, c.recurrence, c.time_zone, Math.max(at, Date.parse(c.scheduled_at)), fired);
      await store.finishOccurrence(c, { next_fire_at: next, fire_count: fired, status: next ? 'open' : (c.recurrence ? 'done' : 'open') });
      return { task_id: c.task_id, event_id: ev?.id ?? null, next_fire_at: next, source };
    }
  }
  async function flushPush(limit = 100) {
    const at = now(), pending = await store.pendingPushEvents(limit, new Date(at).toISOString());
    const out = { sent: 0, skipped: 0, failed: 0, no_device: 0, deferred: 0, coalesced: 0, capped: 0 };
    const byUser = new Map();
    for (const ev of pending) (byUser.get(ev.user_id) ?? byUser.set(ev.user_id, []).get(ev.user_id)).push(ev);
    for (const [uid, evs] of byUser) {
      const tz = evs.find(e => e.payload?.time_zone)?.payload.time_zone ?? defaultTimeZone;
      const exempt = evs.filter(isExempt), rest = evs.filter(e => !isExempt(e));
      const deliver = [...exempt];
      if (rest.length) {
        if (isQuiet(at, tz, quietHours)) {
          const until = new Date(quietEndsAt(at, tz, quietHours)).toISOString();
          for (const ev of rest) { await store.deferPush(ev.id, until); out.deferred++; }
        } else {
          const used = await store.countPushedSince(uid, new Date(localDayStart(at, tz)).toISOString());
          if (dailyPushCap != null && used >= dailyPushCap) { for (const ev of rest) { await store.setPush(ev.id, 'skipped', 'daily_cap'); out.capped++; } }
          else if (rest.length === 1) deliver.push(rest[0]);
          else { // coalesce (e.g. backlog released at quiet-hours end) into one push about the newest event
            const head = rest[rest.length - 1];
            for (const ev of rest.slice(0, -1)) { await store.setPush(ev.id, 'skipped', 'coalesced'); out.coalesced++; }
            deliver.push({ ...head, title: `小猫有 ${rest.length} 条消息`, body: head.body, payload: { ...head.payload, coalesced: rest.length } });
          }
        }
      }
      for (const ev of deliver) await sendOne(ev, out);
    }
    return out;
  }
  async function sendOne(ev, out) {
    const tokens = (await store.tokensFor(ev.user_id)).filter(t => t.enabled);
    if (!tokens.length) { await store.setPush(ev.id, 'no_device', null); out.no_device++; return; }
    if (!apns?.configured) { await store.setPush(ev.id, 'skipped', 'apns_not_configured'); out.skipped++; return; }
    let ok = false, err = null;
    for (const t of tokens) {
      const r = await apns.send(t, ev).catch(e => ({ ok: false, reason: e.message }));
      if (r.ok) ok = true; else { err = r.reason; if (r.unregistered) await store.disableToken(t.id, r.reason); }
    }
    await store.setPush(ev.id, ok ? 'sent' : 'failed', ok ? null : err); ok ? out.sent++ : out.failed++;
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
    if (decision && (path.startsWith('/proactive/') || path.startsWith('/catpaw/proactive/v1/'))) { const r = await decision.route(uid, req, path, url, () => body(req)); if (r) { const res = json(r[0], r[1]); for (const [k, v] of Object.entries(r[2] ?? {})) res.headers.set(k, v); return res; } }
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
    if (path === '/push/test' && m === 'POST') { // demo: queue a test push to the caller's devices and flush now
      const at = now(), ev = await store.insertEvent({ user_id: uid, task_id: null, conversation_id: null, kind: 'agent_message', title: '小猫测试推送', body: '推送通道正常 🐾', payload: { test: true, created_by: 'user' }, dedupe_key: 'push-test:' + crypto.randomUUID() });
      const tokens = (await store.tokensFor(uid)).filter(t => t.enabled);
      const out = { sent: 0, skipped: 0, failed: 0, no_device: 0 }; if (ev) await sendOne(ev, out);
      const state = out.sent ? 'sent' : out.no_device ? 'no_device' : out.skipped ? 'apns_not_configured' : 'failed';
      return json(200, { event_id: ev?.id ?? null, state, devices: tokens.length, apns_configured: !!apns?.configured });
    }
    if (path === '/push/action' && m === 'POST') {
      const b = await body(req);
      if (!isUUID(b.event_id)) throw bad('event_not_found', 404);
      if (!PUSH_ACTIONS.includes(b.action)) throw bad('action_invalid');
      const ev = await store.getEvent(uid, b.event_id); if (!ev) throw bad('event_not_found', 404);
      if (ev.action) return json(200, { event_id: ev.id, action: ev.action, applied: false, task: null });
      const at = now(); let task = null;
      if (ev.task_id && b.action === 'done') task = await patchTask(uid, ev.task_id, { status: 'done' }).catch(() => null);
      if (ev.task_id && b.action.startsWith('snooze_')) task = await patchTask(uid, ev.task_id, { status: 'snoozed', snooze_until: new Date(at + (b.action === 'snooze_10m' ? 600 : 3600) * 1000).toISOString() }).catch(() => null);
      const won = await store.recordPushAction(uid, ev.id, b.action, new Date(at).toISOString());
      return json(200, { event_id: ev.id, action: b.action, applied: won, task: task && summary(task) });
    }
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
