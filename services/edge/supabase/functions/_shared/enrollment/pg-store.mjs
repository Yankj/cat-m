// Postgres store for catpaw.feature-enrollment.v1 (migration 20261016110000). Redemption + rate limit run inside the
// security-definer function feature_access.redeem_invite(), so the API role never reads invite_codes.
export function createPgEnrollmentStore(sql) {
  return {
    async listEnrollments() { return await sql.unsafe('select subject_id::text as subject_id, feature from feature_access.enrollments limit 20000'); },
    async redeem(subject, hash) { const r = (await sql.unsafe('select status, features from feature_access.redeem_invite($1::uuid, $2::text)', [subject, hash]))[0]; return { status: r?.status ?? 'invalid', features: r?.features ?? [] }; },
  };
}
