// Synthetic driver boundary. Bootstrap, pool wrappers, repository and runtime stay real.
export const driver = {
  reset() { this.created = 0; this.reserved = 0; this.released = 0; this.roleQueries = 0; this.jsonQueries = 0; this.failRole = false; this.barrier = null; },
};
driver.reset();
export default function postgres() {
  driver.created++;
  return {
    async reserve() {
      driver.reserved++;
      let released = false;
      return {
        typed: value => value,
        release() { if (released) throw Error('family_qa_double_release'); released = true; driver.released++; },
        async unsafe(sql) {
          if (released) throw Error('family_qa_query_after_release');
          if (sql.includes('pg_roles')) {
            driver.roleQueries++;
            if (driver.barrier) await driver.barrier;
            if (driver.failRole) throw Error('synthetic_transient_database_failure');
            return [{rolsuper: false, rolbypassrls: false, owns_records: false, records_cap: true, auth_cap: true}];
          }
          if (sql.startsWith('SELECT jsonb_typeof')) {
            driver.jsonQueries++;
            return [{object_type: 'object', array_type: 'array', string_type: 'string', null_type: 'null'}];
          }
          throw Error('family_qa_unexpected_sql');
        },
      };
    },
    async unsafe() { throw Error('family_qa_unexpected_driver_access'); },
    async begin() { throw Error('family_qa_unexpected_transaction'); },
  };
}
