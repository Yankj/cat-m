// In-memory stand-in for tests; same semantics as pg-store.mjs / feature_access.redeem_invite().
import { normalizeInviteCode, hashInviteCode, FEATURES } from './contract.mjs';
export function createMemoryEnrollmentStore({ now = () => Date.now(), maxFailures = 5, windowMs = 15 * 60000, globalMaxFailures = 30 } = {}) {
  const invites = [], enrollments = [], attempts = [];
  return {
    _enrollments: enrollments, _attempts: attempts,
    async createInvite({ features = [...FEATURES], maxUses = 1, ttlMs = 30 * 86400000 } = {}) {
      const pick = () => 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'[crypto.getRandomValues(new Uint8Array(1))[0] % 31];
      const raw = Array.from({ length: 12 }, pick).join('');
      invites.push({ hash: await hashInviteCode(normalizeInviteCode(raw)), features, max_uses: maxUses, uses: 0, expires_at: now() + ttlMs, revoked: false });
      return `CP-${raw.slice(0, 4)}-${raw.slice(4, 8)}-${raw.slice(8)}`;
    },
    revokeAll() { for (const i of invites) i.revoked = true; },
    async listEnrollments() { return enrollments.map(e => ({ ...e })); },
    async redeem(subject, hash) {
      const t = now(), win = attempts.filter(a => !a.ok && t - a.at < windowMs);
      if (win.filter(a => a.subject === subject).length >= maxFailures || win.filter(a => t - a.at < 60000).length >= globalMaxFailures) return { status: 'rate_limited', features: [] };
      const inv = invites.find(i => i.hash === hash && !i.revoked && i.expires_at > t);
      const mine = enrollments.filter(e => e.subject_id === subject).map(e => e.feature);
      if (!inv) { attempts.push({ subject, at: t, ok: false }); return { status: 'invalid', features: [] }; }
      if (inv.features.every(f => mine.includes(f))) { attempts.push({ subject, at: t, ok: true }); return { status: 'already_enrolled', features: inv.features }; }
      if (inv.uses >= inv.max_uses) { attempts.push({ subject, at: t, ok: false }); return { status: 'invalid', features: [] }; }
      inv.uses++; for (const f of inv.features) if (!mine.includes(f)) enrollments.push({ subject_id: subject, feature: f });
      attempts.push({ subject, at: t, ok: true }); return { status: 'ok', features: inv.features };
    },
  };
}
