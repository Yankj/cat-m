# 后端撤权收尾补丁：独立 QA review

2026-10-12。本批只 review `fix/backend-p0-finalization` 的来源 `9d22974dd71ba7e122317c6968836dcfb4dd03b4` → 修复 `14495bede7dcdb66956c52add6aca78b48764464`。**所审合成层未发现 blocker，可以作为这一个补丁的独立 review 证据；不构成云端或产品放行。** 用户手机 build13 的产品 FAIL 保留。

## 输入与执行

只读核对 owner 的 `P0-FINALIZATION-MANIFEST.json`、`P0-PROVENANCE.json` 与 `docs/acceptance/backend-p0-finalization.md`。4 个变更源码/测试文件、6 个保留基线文件的 SHA256 同时匹配 manifest、owner 当前文件及指定修复提交。只在 QA 分支 `test/ios-dialogue-p0` 写入独立 fixture/报告，生产源码通过 Git 对象提取到忽略的 `build/before`、`build/after`，不修改 owner 源码、canonical index 或其他 worktree。

实际使用已有 Node **22.17.1**、其 `--experimental-transform-types` 和离线 npm loader；复用 owner 既有**公开 jose 6.2.12 缓存**，没有安装依赖。测试 preload 禁止 fetch、TCP connect、HTTP(S) 和 DNS；注入 provider 若被调用即失败。配置使用显式 synthetic getter，不读取环境/凭据。没有真实 PG、模型、Auth、tick、网络请求、部署、push 或 merge。

第一次测试调用少了 Node TypeScript 标志，模块加载因 `ERR_UNKNOWN_FILE_EXTENSION` 失败，未执行测试体；补旗后重跑成功。原工具失败保留在忽略 build，不计为 App 或补丁故障。

## 结果与证据

| 运行 | 结果 | 含义 |
|---|---|---|
| 来源提交，独立撤权核心用例 | **0 PASS / 1 FAIL（预期 red）** | `ChatService.fail()` 复用正常 beforeWrite，source 拒绝时 `grant_conflict` 抛出，未能提交失败回执 |
| 修复提交，全部独立测试 | **20 PASS / 0 FAIL / 0 SKIP** | 真实生产 hook/service 在 QA 新 fixture 上执行；非 owner 原 62 项测试的重复计数 |
| manifest 与测试后 Git 源码身份 | **PASS** | 两份执行副本在测试后仍匹配各自提交 |

结果：[RESULTS.json](RESULTS.json)；源身份：[INPUT-VERIFICATION.json](INPUT-VERIFICATION.json)；测试/报告哈希：[SHA256.json](SHA256.json)。原始 TAP 为 `build/before-stage2.tap`、`build/after-stage2.tap`，摘要记录其 SHA。

## 审计结论

- **beforeFailure 没有放宽内容发布。** `api.mjs:20–33` 的正常 beforeWrite 仍执行 originalBefore 与 source/consent 检查；新增 failure hook 先执行原 lease/turn/scope-owner 栅栏，再检查 frozen source 的 scope/subject。仅实际 ApiError 的 `(409, grant_conflict)` 或 `(403, provider_consent_required)` 返回拒绝原因；同形普通 Error、错误 status、其他 typed code 都继续抛出。独立测试确认撤权后 append、tool effect、complete、HTTP observation 仍被拒绝，failure 只追加静态 `{code,retryable:false,reconciliation_required}`。
- **旧 lease 不能收尾新 owner。** expired lease、replacement holder、replacement lease generation、replacement turn holder 均拒绝，行与通知不变；metadata put 期间跨 lease 到期也因第二次栅栏回滚。`chat-service.mjs:158,169` 的两次检查实际执行，lease/scope 检查处于授权豁免 catch 之外。
- **已删除、已脱敏、终态与 unknown 不覆盖。** `chat-service.mjs:157,161` 在首次读取及 conversation lock 后重新检查；测试在锁后分别注入删除、脱敏、completed、outcome_unknown，保持原值且没有通知。fail 不从旧 env 拷贝 text/history/tool/artifact，已有 events/history/input/auth/checkpoint 保留。
- **unknown 保持不重发。** 明确 provider_timeout 的 reconciliation 原因优先于后续撤权，记录 outcome_unknown、retryable=false。再 fail 不变；精确相同 admission hash 的重复 POST 复用原 turn，provider 计数仍为 0；撤权 HTTP observation 仍在 SSE 前拒绝。这里的 dispatched checkpoint 是 fixture，不冒充真实模型已发送。
- **重复 fail 幂等。** 8 次 Promise.all 加顺序重试只追加 1 个 turn_failed、通知 1 次；旧 integration 缺 beforeFailure 时仍回落到严格 beforeWrite。并发由串行内存 TestRepository 实现，不能推广为真实 PG 多实例证明。

本批 seam 是公开 production integration hook、ChatService 行为及 Repository 提交结果；不复制 owner 测试 fixture，不测试私有标志。fixture 手动建立 admitted-shaped turn，调用真实 stamp/fence；没有完整真实模型准入链。源/consent 的拒绝是合成注入，生产 auth 数据库权威本轮未运行。

## 未覆盖门槛与下一步

**NOT_RUN**：真实 PostgreSQL 事务隔离/行锁/多实例接管、真实 DB 断连重启、进程在 COMMIT 后通知前崩溃、真实 session/consent/source authority 查询、真实 provider/network timeout、Deno runtime 与 owner 62 项全套、部署及手机/产品验收。内存事务中的锁后状态变化是确定性故障注入，不证明现实锁交错。

集成 owner 可依据精确两生产文件差异继续整合；真实 PG/权限竞态另待明确环境和授权安排。QA 本批结束，不触发 tick、模型调用或部署。结果只在当前线程交付，不跨线程发送。

复现（现有 Node 22 executable 放入 `$QA_NODE`，owner worktree 放入 `$BACKEND_OWNER`；首次 prepare 拒绝覆盖旧目录）：

```sh
python3 qa/backend-finalization-p0/prepare.py --owner "$BACKEND_OWNER"
"$QA_NODE" --experimental-transform-types --experimental-loader ./qa/backend-finalization-p0/npm-loader.mjs --import ./qa/backend-finalization-p0/offline-prelude.mjs --test --test-name-pattern='revocation permits one static receipt' qa/backend-finalization-p0/build/before/test/qa-finalization.test.mjs > qa/backend-finalization-p0/build/before-stage2.tap 2>&1
# 以上 red 预期退出 1；继续执行独立 after 测试。
"$QA_NODE" --experimental-transform-types --experimental-loader ./qa/backend-finalization-p0/npm-loader.mjs --import ./qa/backend-finalization-p0/offline-prelude.mjs --test qa/backend-finalization-p0/build/after/test/qa-finalization.test.mjs > qa/backend-finalization-p0/build/after-stage2.tap 2>&1
python3 qa/backend-finalization-p0/collect-results.py
```

仓库 integrity、敏感性与 Git diff 检查在证据提交前执行；运行缓存与原始 TAP 不纳入 Git。
