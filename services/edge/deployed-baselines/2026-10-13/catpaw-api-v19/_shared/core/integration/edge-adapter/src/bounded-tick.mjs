import { TaskWorker, LostLeaseError } from '../vendor/openmuse/runtime/engine/worker.mjs';
import { BoundedStore } from './bounded-store.mjs';
import { AdapterError, SafeRetry, clone, ensure, dispatched, iso, hash } from './common.mjs';

const statuses = new Set(['scheduled', 'succeeded', 'failed', 'outcome_unknown', 'waiting_input', 'waiting_approval']);
const resultKeys = new Set(['status', 'state', 'error', 'artifactIds', 'question', 'nextRunAt']);

/** One invocation, at most one claimed task and one injected owner step. No start(), scheduler or provider loop. */
export async function boundedTick({ repository, owners, admitTask, runStep, onCommit, signal, now = Date.now,
  budgetMs = 2000, settleReserveMs = 250, leaseMs = 5000, retryBaseMs = 1000, retryMaxMs = 30000, maxRetries = 3,
  Worker = TaskWorker }) {
  ensure(typeof runStep === 'function', 'step_runner_not_configured');
  ensure(Number.isSafeInteger(budgetMs) && budgetMs >= 20 && budgetMs <= 30000 && settleReserveMs >= 5 && settleReserveMs < budgetMs, 'invalid_budget');
  ensure(leaseMs > budgetMs + settleReserveMs && leaseMs <= 180000, 'invalid_lease');
  ensure(Number.isSafeInteger(maxRetries) && maxRetries >= 0 && Number.isSafeInteger(retryBaseMs) && retryBaseMs >= 1 && retryMaxMs >= retryBaseMs && retryMaxMs <= 300000, 'invalid_backoff');
  const startedAt = now();
  const invocation = { open: true, deadline: startedAt + budgetMs };
  const store = new BoundedStore({ repository, owners, admitTask, now, invocation, onCommit });
  const settled = [];
  let claimed = 0, stepCalls = 0;
  const worker = new Worker(store, async (owner, initial, original) => {
    claimed += 1;
    const controller = new AbortController();
    const deadline = invocation.deadline - settleReserveMs;
    const control = { signal: controller.signal, deadline,
      // Owner callback permission check inside its existing transaction, without a nested DB await.
      assertLive: () => store.stepLive(control), open: true };
    let abortCause = null, timeout, stepKind = null;
    let rejectAbort;
    const aborted = new Promise((_, reject) => { rejectAbort = reject; });
    aborted.catch(() => {}); // the guard may fail before Promise.race is installed
    const abort = cause => { if (controller.signal.aborted) return; abortCause = cause; const error = new AdapterError(cause); controller.abort(error); rejectAbort(error); };
    const externalAbort = () => abort('invocation_aborted');
    const workerAbort = () => abort('lease_lost');
    original.signal.addEventListener('abort', workerAbort, { once: true });
    signal?.addEventListener('abort', externalAbort, { once: true });
    if (signal?.aborted) externalAbort();
    if (original.signal.aborted) workerAbort();
    timeout = setTimeout(() => abort('step_deadline'), Math.max(0, deadline - now()));
    const context = {
      signal: controller.signal, deadline,
      // Owner callback permission check inside its existing transaction, without a nested DB await.
      assertLive: () => store.stepLive(control),
      remainingMs: () => Math.max(0, deadline - now()),
      guard: () => store.stepGuard(owner, initial.id, initial.leaseId, control).then(() => undefined),
      checkpoint: patch => store.checkpointStep(owner, initial.id, initial.leaseId, patch, control),
      event: (kind, title) => store.eventStep(owner, initial.id, initial.leaseId, kind, title, control),
      // Mirrors modelHandler's existing checkpoint shape. This is the sole dispatch admission helper.
      beforeDispatch: async requestHash => {
        ensure(stepKind === null, 'single_step_limit'); stepKind = 'remote';
        ensure(typeof requestHash === 'string' && /^[a-f0-9]{64}$/.test(requestHash), 'invalid_request_hash');
        const current = await store.stepGuard(owner, initial.id, initial.leaseId, control);
        ensure(!current.state.local_model?.round, 'round_already_checkpointed');
        const local = current.state.local_model ?? { step: 0, messages: [], round: null, artifact: null };
        await context.checkpoint({ state: { ...current.state, local_model: { ...local, round: { state: 'dispatched', request_hash: requestHash } } } });
        // Recheck deadline/cancel AFTER durable dispatch checkpoint and immediately before transport.
        await context.guard(); context.assertLive();
        return { operation_key: hash({ task: initial.id, step: local.step, request_hash: requestHash }) };
      },
      received: async output => {
        const current = await store.stepGuard(owner, initial.id, initial.leaseId, control);
        ensure(dispatched(current), 'dispatch_checkpoint_required');
        ensure(output && typeof output === 'object' && !Object.hasOwn(output, 'state') && !Object.hasOwn(output, 'request_hash'), 'invalid_received_round');
        return context.checkpoint({ state: { ...current.state, local_model: { ...current.state.local_model,
          round: { ...clone(output), state: 'received', request_hash: current.state.local_model.round.request_hash } } } });
      },
      /** Fenced local immutable effects must commit through the owner's transaction API.
       * Remote effects require a separate dispatched/received checkpoint and unknown policy. */
      localCommit: (operation, mutate) => {
        ensure(stepKind === null, 'single_step_limit'); stepKind = 'local';
        return store.commitStep(owner, initial.id, initial.leaseId, operation, mutate, control);
      },
    };
    let result, failure = null;
    try {
      // Interrupted dispatch is never replayed, even if a previous worker vanished.
      if (dispatched(initial)) return { status: 'outcome_unknown', error: 'dispatch_outcome_unknown; do not automatically resend' };
      await context.guard();
      stepCalls += 1;
      const step = Promise.resolve().then(() => runStep(owner, clone(initial), context));
      result = await Promise.race([step, aborted]);
      await context.guard();
      ensure(result && typeof result === 'object' && Object.keys(result).every(k => resultKeys.has(k)) && statuses.has(result.status), 'invalid_step_result');
    } catch (error) { failure = error; }
    finally {
      clearTimeout(timeout); control.open = false;
      controller.abort();
      original.signal.removeEventListener('abort', workerAbort);
      signal?.removeEventListener('abort', externalAbort);
    }
    // Settlement uses the original worker lease fence, outside the expired step signal.
    await original.guard();
    const latest = await store.get(owner, 'tasks', initial.id);
    if (latest.leaseId !== initial.leaseId || latest.status !== 'running') throw new LostLeaseError();
    store.prepareSettlement(latest);
    if (dispatched(latest)) return { status: 'outcome_unknown', error: 'dispatch_outcome_unknown; do not automatically resend' };
    if (failure) {
      if (failure instanceof LostLeaseError && !abortCause || abortCause === 'lease_lost') {
        // Let the real worker's own guard return its original LostLeaseError when applicable.
        await original.guard(); throw new LostLeaseError();
      }
      const retryable = failure instanceof SafeRetry || failure?.code === 'step_deadline' || abortCause === 'step_deadline' || abortCause === 'invocation_aborted';
      if (!retryable) return { status: 'failed', error: 'step_failed' }; // never persist arbitrary provider/tool error text
      const count = (latest.state.bounded_tick?.retry_count ?? 0) + 1;
      const state = { ...latest.state, bounded_tick: { version: 1, retry_count: count, reason: abortCause ?? failure.code ?? 'pre_dispatch_transient' } };
      if (count > maxRetries) return { status: 'failed', error: 'safe_retry_limit', state };
      return { status: 'scheduled', state, nextRunAt: iso(now() + Math.min(retryMaxMs, retryBaseMs * 2 ** (count - 1))) };
    }
    const state = result.state ?? latest.state;
    ensure(hash(state.catpaw) === hash(latest.state.catpaw), 'authority_patch_forbidden');
    const patch = { ...result, state: { ...state, bounded_tick: { version: 1, retry_count: 0, reason: result.status === 'scheduled' ? 'yield' : 'terminal' } } };
    if (result.status === 'scheduled') patch.nextRunAt ??= iso(now() + retryBaseMs);
    return patch;
  }, { now, leaseMs, settled: async (owner, task) => {
    settled.push({ owner, task_id: task.id, status: task.status, nextRunAt: task.nextRunAt ?? null });
  } });
  try {
    await worker.tick();
    return { execution_layer: 'local_bounded_worker_prototype', claimed, step_calls: stepCalls, settled, elapsed_ms: now() - startedAt };
  } finally {
    invocation.open = false;
    // TaskWorker clears its per-run heartbeat in run.finally. start() is never called.
  }
}
