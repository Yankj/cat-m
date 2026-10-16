# catpaw-api 部署记录（生产 dbyklgxdvjbutxzsjeth）

整理时间 2026-10-16（CST）。本文件不含任何密钥。部署包（bundle）不入库，可按下文从提交重建。

## 生产版本对应

| 函数版本 | 源提交 | 分支 | 内容 |
|---|---|---|---|
| catpaw-api v36 | — | — | 部署前基线（源码备份在维护者本机，未入库） |
| catpaw-api v37 / v39 | `eb3bf1c` | 本地 detached（v2 `b09077f` + #57 `14d282d` + #41 `e819e0a` + #49 `e369290`） | wave 2 |
| （w3，未上线） | `3628c45` | 包含在 `chore/w4-model-routes` 中 | #70 + #71 |
| catpaw-api v42 | `cc98949` | `chore/w4-model-routes` | #70 + #71 + #72（FreeLLMAPI 版） |
| catpaw-api v43（当前） | `952ca4e` | `chore/w5-opencode-zen` | #72 改为 OpenCode Zen 直连 |

catpaw-proactive v3、catpaw-tick v11 本轮未改动。

wave 2 已应用的迁移：proactive_tasks、proactive_task_tools_runtime、proactive_push_throttle、proactive_push_actions、proactive_decisions、agent_memory。**proactive_cron 未应用**。

## 构建（esbuild）

在 `services/edge/supabase/functions` 下执行（v43 已验证可逐字节复现）：

```sh
npx -y esbuild@0.24.0 catpaw-api/index.ts --bundle --format=esm --platform=neutral \
  --target=es2022 --keep-names \
  "--external:npm:*" "--external:node:*" "--external:jsr:*" "--external:https:*" \
  --outfile=<out>/catpaw-api/index.ts
```

部署包目录结构：`<out>/catpaw-api/index.ts` + `<out>/deno.json`，deno.json 内容为
`{"compilerOptions":{"checkJs":false,"strict":false},"lock":"deno.lock","nodeModulesDir":"none"}`。

## 部署参数

- 函数名 `catpaw-api`，入口 `catpaw-api/index.ts`
- `import_map_path` 使用相对路径 `deno.json`（用绝对路径会失败）
- `verify_jwt=false`（鉴权在函数内部做）
- 生产部署、迁移、改 secret 必须由用户本人在对话中明确确认

## 回滚

1. checkout 目标版本的提交（如 v42 → `cc98949`，v39 → `eb3bf1c`）。
2. 用上面命令重建，以同样参数重新部署 `catpaw-api`。
3. Secrets 与模型路由无关的配置不需要回滚；回滚后跑 smoke：`/readyz`、中文对话、`calendar_create`、`GET /catpaw/model-routes/v1`。
4. wave 2 数据库回滚（会删掉 wave 2 全部数据，仅在必要时）：`drop schema agent_memory cascade; drop schema proactive cascade; drop extension vector;` 并删除 `supabase_migrations.schema_migrations` 中 version >= '20261015174355' 的行。

## 未完成

- #63、#69 的迁移没上生产（因此部署包基于 eb3bf1c 系列，不基于 integration-v2）；proactive_cron、pg_cron/pg_net 未启用。
- `CATPAW_OPENROUTER_MODEL` 待在 Dashboard 改为 `google/gemma-4-31b-it:free`（当前默认模型已下架，每轮 failover 到 Gemini）。
- OpenCode Zen：用户放弃（需境外信用卡）。代码已在 v43，`CATPAW_OPENCODE_API_KEY` 未配置，路由不出现。
- 设备工具闸门目前对所有人开放，待收回到 `allowlist`。
- 匿名测试账号（4122078e、3137bd48）待清理。

## 生产化待办（优先 1、2、5、6，其次 3、7）

1. 付费兜底路由 + 免费模型可用性定期巡检
2. 路由健康/熔断状态放共享存储（Postgres/Redis），而非实例内存
3. 长任务异步化（后台任务 + 状态轮询/队列），规避 Edge 执行时长上限
4. 流中断可重试（续写或可重试错误码）
5. 按用户/IP 限流 + 全局成本上限
6. 可观测性：每轮追踪（路由、耗时、token、切换原因）、告警、看板
7. 设备工具幂等（Idempotency-Key，在 #63）
8. 测试债：4 个历史失败、新 handler 端到端测试、压测与故障注入
9. 安全：设备工具白名单、清理匿名账号、Prompt 注入防护
10. CI 自动测试 + 灰度发布 + 一键回滚

## 合并顺序（2026-10-16 开放 PR 的堆叠关系）

后端：
- #70 `feat/gemini-interactions` → v2
- #71 `fix/calendar-device-prompt` → v2（建议在 #70 之后）
- #72 `feat/opencode-route-status` → v2（draft，叠在 #70+#71 上，需先合它们）
- #63 `feat/proactive-s1s2` → v2；#69 `feat/feature-enroll` → #63（两者都带未上线迁移，合并后部署前须先申请迁移）
- #41 / #46 / #49 / #50 / #51 / #57 后端 wave 2，已在 v37+ 生产代码中
- #80 `fix/nobug-p0` → v2

iOS 堆叠：
- #65 → v2；#66 → #65；#67 → #66（#67 依赖 #63 的 SSE 事件）
- #58 → v2；#59 → #58
- #33 → v2；#38 → #33
- #54 → v2；#56 叠在 #54
- #62 → v2；#64 叠在 #62
- 被取代：#24（→#26）、#25（→#27）、#35→#36→#37→#39（保留 #39）
- 其余 iOS PR（#26–#34、#39、#40、#42–#45、#47、#48、#52、#53、#55、#60、#61、#68）各自 → v2

建议顺序：#70 → #71 → #72 → #63 → #69 → #65 → #66 → #67，然后各 iOS 独立 PR。
