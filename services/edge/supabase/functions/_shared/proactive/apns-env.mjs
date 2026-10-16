// catpaw-proactive APNs credentials. Production (catpaw-proactive v6) reads APNS_*; catpaw-api's core sender reads
// CATPAW_APNS_*. A complete APNS_* set wins, else a complete CATPAW_APNS_* set; a partial set is never mixed with the other.
const SETS = [
  { source: 'APNS_*', keyId: 'APNS_KEY_ID', teamId: 'APNS_TEAM_ID', privateKeyPem: 'APNS_PRIVATE_KEY', topic: 'APNS_BUNDLE_ID' },
  { source: 'CATPAW_APNS_*', keyId: 'CATPAW_APNS_KEY_ID', teamId: 'CATPAW_APNS_TEAM_ID', privateKeyPem: 'CATPAW_APNS_P8', topic: 'CATPAW_APNS_BUNDLE_ID' },
];
export function readProactiveApnsEnv(get) {
  for (const s of SETS) {
    const v = { keyId: get(s.keyId), teamId: get(s.teamId), privateKeyPem: get(s.privateKeyPem), topic: get(s.topic) };
    if (v.keyId && v.teamId && v.privateKeyPem && v.topic) return { ...v, source: s.source };
  }
  return { keyId: undefined, teamId: undefined, privateKeyPem: undefined, topic: undefined, source: 'none' };
}
