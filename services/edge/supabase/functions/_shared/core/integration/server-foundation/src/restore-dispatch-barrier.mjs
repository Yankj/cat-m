import { clone, ensure, exact, hash, integer, instant, text, uuid } from './common.mjs';

const pointer = marker => ({ schema_version: 1, scope_id: marker.scope_id, authority_id: marker.authority_id,
  recovery_epoch: marker.recovery_epoch, incarnation_id: marker.incarnation_id });

/** Trusted composition port, NOT a user/model command or an external service implementation.
 * readMarker must obtain fresh authority from OUTSIDE the database/backup being restored.
 * A second DB table, a static env value or a cached copy does not meet that contract.
 */
export class RestoreDispatchBarrier {
  constructor({ readMarker, authorizeBinding, clock = () => new Date() } = {}) {
    Object.assign(this, { readMarker, authorizeBinding, clock });
  }
  async marker(scopeId, state, control) {
    ensure(typeof this.readMarker === 'function', 'restore_authority_missing', 503);
    control?.assertLive();
    let marker;
    try { marker = await this.readMarker({ scope_id: scopeId, signal: control?.signal, deadline: control?.deadline }); }
    catch { ensure(false, 'restore_authority_unavailable', 503); }
    control?.assertLive();
    ensure(marker, 'restore_authority_missing', 503);
    exact(marker, ['schema_version', 'scope_id', 'authority_id', 'recovery_epoch', 'incarnation_id', 'state', 'valid_until']);
    ensure(marker.schema_version === 1, 'restore_marker_invalid', 409); uuid(marker.scope_id); uuid(marker.incarnation_id);
    text(marker.authority_id, 160); integer(marker.recovery_epoch, 1); instant(marker.valid_until);
    ensure(marker.scope_id === scopeId, 'restore_marker_scope_conflict', 403);
    ensure(Date.parse(marker.valid_until) > this.clock().getTime(), 'restore_marker_expired', 409);
    ensure(marker.state === state, 'restore_dispatch_locked', 409);
    return clone(marker);
  }
  /** Only a separately authorized recovery operator may call this under the scope transaction.
   * No auto bind/rebind on startup, proposal, approval, retry or dispatch. External state stays locked.
   */
  async bind(recordTx, owner, scopeId, { expected_revision, review_id }) {
    integer(expected_revision); text(review_id, 160);
    ensure(typeof this.authorizeBinding === 'function', 'restore_binding_operator_required', 403);
    await recordTx.withScope(scopeId, async tx => { ensure((await tx.scope()).identity.owner === owner, 'scope_forbidden', 403); });
    const marker = await this.marker(scopeId, 'locked');
    await recordTx.lock(owner, 'catpaw-recovery-bindings', scopeId);
    const old = await recordTx.get(owner, 'catpaw-recovery-bindings', scopeId);
    ensure((old?.revision ?? 0) === expected_revision, 'restore_binding_conflict', 409);
    ensure(await this.authorizeBinding({ scope_id: scopeId, marker: clone(marker), review_id, previous_revision: old?.revision ?? 0 }) === true, 'restore_binding_operator_required', 403);
    const fresh = await this.marker(scopeId, 'locked');
    ensure(hash(pointer(fresh)) === hash(pointer(marker)), 'restore_marker_changed', 409);
    const row = { id: scopeId, schema_version: 1, revision: expected_revision + 1, marker: pointer(marker), review_id };
    const saved = old ? await recordTx.compareAndSwap(owner, 'catpaw-recovery-bindings', scopeId, { revision: expected_revision }, row)
      : await recordTx.insertIfAbsent(owner, 'catpaw-recovery-bindings', row);
    ensure(saved, 'restore_binding_conflict', 409);
    const final = await this.marker(scopeId, 'locked');
    ensure(hash(pointer(final)) === hash(pointer(marker)), 'restore_marker_changed', 409); return saved;
  }
  async snapshot(recordTx, owner, scopeId, control) {
    const marker = await this.marker(scopeId, 'open', control);
    const binding = await recordTx.get(owner, 'catpaw-recovery-bindings', scopeId);
    ensure(binding?.schema_version === 1 && binding.revision >= 1, 'restore_binding_missing', 409);
    ensure(hash(binding.marker) === hash(pointer(marker)), 'restore_binding_mismatch', 409);
    const fresh = await this.marker(scopeId, 'open', control);
    ensure(hash(pointer(fresh)) === hash(pointer(marker)), 'restore_marker_changed', 409);
    control?.assertLive();
    ensure(Date.parse(fresh.valid_until) > this.clock().getTime(), 'restore_marker_expired', 409);
    return { ...pointer(marker), binding_revision: binding.revision };
  }
  async assert(recordTx, owner, scopeId, frozen, control) {
    ensure(frozen?.schema_version === 1, 'restore_fence_missing', 409);
    const current = await this.snapshot(recordTx, owner, scopeId, control);
    ensure(hash(frozen) === hash(current), 'restore_fence_mismatch', 409); return current;
  }
}
