import { clone } from '../../supabase/functions/_shared/core/integration/server-foundation/src/common.mjs';

// Deliberately separate from TestRepository.snapshot. This is an injection contract fixture,
// not proof of a real durable external authority, signature or automatic restore detection.
export class SyntheticRestoreAuthority {
  constructor({ scope_id, incarnation_id, valid_until }) {
    this.current = { schema_version: 1, scope_id, authority_id: 'synthetic-external-recovery-operator', recovery_epoch: 1,
      incarnation_id, state: 'locked', valid_until };
    this.available = true;
  }
  readMarker = async () => this.available ? clone(this.current) : null;
  authorizeBinding = async ({ review_id }) => review_id.startsWith('synthetic-reviewed-');
  open() { this.current.state = 'open'; }
  lock() { this.current.state = 'locked'; }
  restore(incarnation_id) { this.lock(); this.current.recovery_epoch++; this.current.incarnation_id = incarnation_id; }
}
