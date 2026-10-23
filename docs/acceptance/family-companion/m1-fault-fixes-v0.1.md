# M1 故障修复 v0.1（2026-10-23）

候选：`73b7ec668585a660e7a9fb9789892080147df6ef`（分支 `feat/family-backend-m1m2`）。基线：`docs/family-m0@245a3096`（产品源码等同 `789ad4fe`）。
命令：`node qa/family-cloud-verification/offline/run.mjs targets --candidate <sha>`，Node v24.10.0，离线 guard。

| 用例 | 修复前 | 修复后 | 修复 |
|---|---|---|---|
| BOOT-01 | PASS | PASS | — |
| BOOT-02 | FAIL | PASS | 初始化失败不再缓存被拒的 promise；释放连接，下次请求重建；503 标 `retryable:true` |
| BOOT-03 | PASS | PASS | — |
| MEM-01 | FAIL | PASS | 更正按起始版本（`updated_at`，或客户端 `expected_version`）CAS，迟到写 409 `memory_conflict` |
| MEM-02 | PASS | PASS | 附带：迟到 PATCH 现在返回 404 而非 500 |
| MEM-03 | FAIL | PASS | 每用户 clear generation；日记写入以开始时的 generation 为 fence |
| MEM-04 | FAIL | PASS | tombstone 记录 operation_id；重放已删除操作返回 `not_saved/previously_deleted` |
| MEM-05 | FAIL | PASS | 日记写失败时归还本组及未处理组的片段 |
| SAFE-01 | PASS | PASS | — |
| REM-01 | FAIL | PASS | occurrence claim 改为 30 s 租约，丢失的 worker 可被回收 |
| REM-02 | FAIL | PASS | 过期租约在 limit 之前筛选，不饿死后续 |
| REM-03 | FAIL | PASS | `reminder_due` 事件仅当任务仍为 open/snoozed 且 `next_fire_at` 等于该 occurrence 时写入（原子条件插入） |
| REM-04 | FAIL | PASS | fire 失败释放 claim、保留 due，不再清空 next_fire_at |
| REM-05 | FAIL | PASS | 同上 |
| REM-06 | FAIL | PASS | 同上 + 租约 |
| REM-07 | PASS | PASS | — |
| REM-08 | PASS | PASS | — |
| REM-09 | FAIL | PASS | 创建事件按 dedupe_key 每次幂等补写 |

合计：6 PASS / 12 FAIL → **18 PASS / 0 FAIL**。既有 edge Node 回归（`services/edge/scripts/ci-node-tests.sh`）修复前后均为 876 项：874 PASS / 0 FAIL / 2 SKIP。

迁移（仅文件，未应用）：`20261023100000_family_m1_reminder_lease.sql`、`20261023100100_family_m1_memory_fences.sql`。

## 未验证
- 真实 PostgreSQL：新迁移与 pg-store 改动只做了离线/内存 store 验证，未在真实 PG 跑过；多实例、租约时序未验。
- 内容日志 canary（不在 18 项内）：仅把 `fire_failed` 日志改为不带堆栈/内容，完整日志审计未做。
- 未部署，未触碰生产。
