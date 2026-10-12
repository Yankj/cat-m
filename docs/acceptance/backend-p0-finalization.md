# 后端 P0：撤权后的失败收尾

本记录对应独立 `fix/backend-p0-finalization` 分支。基线为 `b7fa4ee5f8d144208d51f6d0dcdee9259c4315b7`；冻结 P0 的来源提交为 `9d22974dd71ba7e122317c6968836dcfb4dd03b4`。当前进展只维护在[主计划](../status/master-plan.md)。精确源/日志 hash 见 [P0-FINALIZATION-MANIFEST.json](../../services/edge/P0-FINALIZATION-MANIFEST.json)，原候选身份见 [P0-PROVENANCE.json](../../services/edge/P0-PROVENANCE.json)。

撤权发生时，普通写入正确抛出 `grant_conflict`，但原 `fail()` 复用普通发布检查，收尾再次失败，`waitIdle()` 拒绝且 turn 留在 running。原13项离线复现为12过、1失败。

修复在现有 integration 上新增 `beforeFailure(tx, {owner, scope, turn})`。原租约/代际/scope-owner检查位于捕获之外；只有 typed `ApiError(409, grant_conflict)` 或 `ApiError(403, provider_consent_required)` 可返回拒绝原因并允许静态失败元数据。普通 `beforeWrite`、模型准入、工具、observer 每次yield授权不放宽。无失败hook的旧integration仍回落到原 `beforeWrite`。

`ChatService.fail()` 锁定会话后重读当前turn，只追加 `{code, retryable:false, reconciliation_required}` 的 `turn_failed` 和终态/时间。已终态、已脱敏、已删除行保持原值，不重复通知；不取旧env的正文、history、工具或成果。await写后再验相同栅栏，通过事务提交后才通知。明确撤权为failed；原timeout/dispatch不确定原因保持outcome_unknown。没有自动重发或把撤权变成completed。

验证：8文件合计62/62；dialogue P0为30/30，包括17项新增竞态。覆盖缓存通知撤权、source/consent拒绝、注销先结算、重复并发收尾、租约到期/holder接管/turn代际、慢元数据写跨租约、锁后terminal/redaction/deletion、真实source-erasure reducer、scope归属、typed/非typed意外数据库错误与unknown不重发。这里的“并发”由序列化TestRepository及确定性注入模拟，不是PostgreSQL多实例验收。

离线复现要求：已有Deno及官方固定依赖缓存（jose 6.2.12、postgres 3.4.7）。`build/cache`仅放公开依赖，`build/*.log`为忽略的运行输出；无需新凭据或外部服务。使用既有缓存，不自动安装：

```sh
cd services/edge
NPM_CONFIG_REGISTRY=https://registry.npmjs.org DENO_DIR=build/cache deno test --cached-only --no-prompt --deny-net --ignore-env --allow-read --config supabase/functions/deno.json test
NPM_CONFIG_REGISTRY=https://registry.npmjs.org DENO_DIR=build/cache deno check --cached-only --config supabase/functions/deno.json supabase/functions/catpaw-api/index.ts test/dialogue-p0.test.mjs
```

全套测试忽略全部环境变量，驱动typed/serializer测试使用显式合成参数且无reserve/connect；Deno禁网。入口check只证明当前checkJs=false配置下导入/语法图可检查，不替代强类型或运行验收。

集成时先引入来源提交，再引入本修复提交；若整合分支已含同字节P0，核对P0-PROVENANCE后只应用修复差异。两个生产文件为 `_shared/api.mjs` 与 `_shared/core/src/chat-service.mjs`；新hook仅由ChatService失败收尾调用。无需SQL迁移或新HTTP字段；既有v1事件形状保留。worker-stall候选、长授权、任务推进、模型route、发布配置和上游MIT原文保持独立。

真实PG事务/并发/重启、云部署、模型/tick、设备及MM01–05产品验收均未执行；不能将62项离线回归签为产品或云端放行。无push、merge、部署、tick或真实provider调用。
