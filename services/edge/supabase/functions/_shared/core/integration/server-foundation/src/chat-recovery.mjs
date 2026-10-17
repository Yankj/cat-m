import { ensure, clone, uuid, integer } from './common.mjs';

/** Optional integration fence for the SAME chat owner. No poller, task reducer or model call. */
export class ChatRecoveryFence {
  constructor(repository, { clock = () => new Date(), lease_ms = 30000 } = {}) {
    integer(lease_ms, 1000, 300000); this.repository = repository; this.clock = clock; this.lease_ms = lease_ms;
  }
  now() { return this.clock().toISOString(); }
  async acquire(owner, holder_id) {
    uuid(holder_id);
    return this.repository.transaction(async tx => {
      await tx.lock(owner, 'native-chat-runtime-leases', 'runtime'); const old = await tx.get(owner, 'native-chat-runtime-leases', 'runtime');
      if (old && old.holder_id !== holder_id && Date.parse(old.lease_until) > Date.parse(this.now())) return null;
      const newGeneration = old && (old.holder_id !== holder_id || Date.parse(old.lease_until) <= Date.parse(this.now()));
      const row = { id: 'runtime', holder_id, generation: old ? old.generation + (newGeneration ? 1 : 0) : 1, lease_until: new Date(Date.parse(this.now()) + this.lease_ms).toISOString() };
      if (old) return tx.compareAndSwap(owner, 'native-chat-runtime-leases', 'runtime', old, row);
      return tx.insertIfAbsent(owner, 'native-chat-runtime-leases', row);
    });
  }
  /** Read-only: ms until the current lease expires (0 when free/expired). Used for Retry-After. */
  async remainingMs(owner) {
    const row = await this.repository.transaction(tx => tx.get(owner, 'native-chat-runtime-leases', 'runtime'));
    return row ? Math.max(0, Date.parse(row.lease_until) - Date.parse(this.now())) : 0;
  }
  /** Owner-checked early release: expires the lease only if it is still held by this exact
   * holder+generation token, so it can never free another instance's (or a newer) lease. */
  async release(owner, token) {
    if (!token) return false;
    return this.repository.transaction(async tx => {
      await tx.lock(owner, 'native-chat-runtime-leases', 'runtime'); const live = await tx.get(owner, 'native-chat-runtime-leases', 'runtime');
      if (!live || live.holder_id !== token.holder_id || live.generation !== token.generation || Date.parse(live.lease_until) <= Date.parse(this.now())) return false;
      return !!(await tx.compareAndSwap(owner, 'native-chat-runtime-leases', 'runtime', live, { lease_until: this.now() }));
    });
  }
  async assertLive(tx, owner, token) {
    await tx.lock(owner, 'native-chat-runtime-leases', 'runtime');
    const live = await tx.get(owner, 'native-chat-runtime-leases', 'runtime');
    ensure(live && live.holder_id === token.holder_id && live.generation === token.generation && Date.parse(live.lease_until) > Date.parse(this.now()), 'runtime_lease_lost', 409);
    return live;
  }
  async renew(owner, token) {
    return this.repository.transaction(async tx => { const live = await this.assertLive(tx, owner, token); return tx.compareAndSwap(owner, 'native-chat-runtime-leases', 'runtime', live, { lease_until: new Date(Date.parse(this.now()) + this.lease_ms).toISOString() }); });
  }
  async stampTurn(tx, owner, token, turn) {
    await this.assertLive(tx, owner, token);
    // Fields must be included by owner before INSERT turn. Every subsequent owner write rechecks assertTurnLive.
    return { ...clone(turn), runtime_holder_id: token.holder_id, runtime_generation: token.generation };
  }
  async assertTurnLive(tx, owner, token, turn) {
    await this.assertLive(tx, owner, token);
    ensure(turn.runtime_holder_id === token.holder_id && turn.runtime_generation === token.generation, 'turn_runtime_fenced', 409);
  }
  async recoverExpiredOwner(owner, token) {
    return this.repository.transaction(async tx => {
      await this.assertLive(tx, owner, token);
      const changed = [], legacy_unfenced = [];
      for (const turn of await tx.list(owner, 'native-chat-turns')) {
        if (turn.state !== 'running') continue;
        if (!turn.runtime_holder_id || !turn.runtime_generation) { legacy_unfenced.push(turn.id); continue; }
        if (turn.runtime_holder_id === token.holder_id && turn.runtime_generation === token.generation) continue;
        // Runtime lease lock precedes conversation->delegation->task locks in this integrated mode.
        await tx.lock(owner, 'native-chat-conversations', turn.conversation_id);
        const current = await tx.get(owner, 'native-chat-turns', turn.id);
        if (current.state !== 'running' || current.runtime_generation === token.generation) continue;
        const error = { code: 'outcome_unknown', retryable: false, reconciliation_required: true };
        const first = current.events[0];
        const event = { ...(first ? Object.fromEntries(['schema_version','contract','scope_id','conversation_id','turn_id','grant_epoch','model_reality'].map(k => [k, first[k]])) : {
          schema_version: 1, contract: 'catpaw.native-chat.v1', scope_id: current.scope_id, conversation_id: current.conversation_id, turn_id: current.id, grant_epoch: current.grant_epoch, model_reality: 'provider_unverified'
        }), sequence: current.events.length + 1, cursor: `${current.id}:${current.events.length + 1}`, type: 'turn_failed', data: error };
        const updated = await tx.compareAndSwap(owner, 'native-chat-turns', current.id, { state: 'running', runtime_holder_id: current.runtime_holder_id, runtime_generation: current.runtime_generation, events: current.events },
          { state: 'outcome_unknown', error, finished_at: this.now(), events: [...current.events, event] });
        if (updated) changed.push(updated.id);
      }
      // Legacy turns need controlled single-instance migration; cannot prove no other instance is live.
      return { changed, legacy_unfenced };
    });
  }
}
