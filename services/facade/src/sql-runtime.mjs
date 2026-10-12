// Dependency injection keeps this module safe to inspect and import: no .env / SDK / provider startup.
import { SqlRepository } from './sql-repository.mjs';
import { createRuntime } from './runtime.mjs';
import { check } from './common.mjs';
export function createSqlSyntheticRuntime({database,authenticate}={}) {
  check(database?.transaction&&typeof authenticate==='function',503,'configuration_missing');
  // Real principal -> allowed scopes is mandatory here; syntheticAuth cannot be an implicit fallback.
  return createRuntime({repository:new SqlRepository(database),authenticate,executionLayer:'actual_upstream_sql_runtime_unverified'});
}
