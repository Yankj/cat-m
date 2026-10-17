/**
 * Codex PR91 v3-1: memory stores for the production bootstrap. The privacy store (read of the user's saved agent-memory
 * off) is installed UNCONDITIONALLY — independent of CATPAW_AGENT_MEMORY_ENABLED — so closing the feature never brings
 * legacy memory back. The full agent-memory store still follows the feature gate.
 */
export function memoryStores(config, sql, makeStore) {
  return { agentMemoryStore: config.agentMemory !== 'off' ? makeStore(sql) : null, agentMemoryPrivacyStore: makeStore(sql) };
}
