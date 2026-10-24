# mimi 后端维护源

唯一维护入口为 [`supabase/functions/`](supabase/functions/)；当前产品及阶段边界见[Roadmap](../../docs/product/mimi-roadmap.md)，部署版本、候选和验收结果只在[主计划](../../docs/status/master-plan.md)记录。本目录从早期 API v14 来源继续演进，不能再把整个维护树称为“冻结 P0”，也不能用旧来源 manifest 判断当前线上版本。

| 入口 / 模块 | 职责 |
|---|---|
| `catpaw-api/index.ts` | 现有 API 装配、认证与授权入口 |
| `_shared/api.mjs` / `_shared/core/src/chat-service.mjs` | 对话、任务及受限 parenting intake；后者只返回可核对候选 |
| `_shared/family/` | 保留 `catpaw.family.v1` 家庭云合同；尚不是 M1 本机账本的同步权威 |
| `catpaw-proactive/index.ts` / `_shared/proactive/` | 既有主动建议与调度能力；不代表育儿安排已获得提醒 |

本目录没有独立 `catpaw-worker` 或 `catpaw-tick` 维护入口；它们与历史快照的职责见[目录角色](../../docs/development/repository-layout.json)和[架构](../../docs/architecture.md)。`verify_jwt = false` 仅表示网关不校验：函数内部的 bearer/session、scope、consent、撤权与 scheduler secret 校验仍是权限边界，不得跳过。M1 的本机安排与家长完成由原生账本持久化，服务端整理不能确认安排、写家庭记忆、执行工具或设置提醒。

## 本地验证

在仓库根目录，使用已有 Deno 和明确提供的公开依赖缓存：

```sh
CATPAW_DENO_BIN=<已有Deno路径> CATPAW_PUBLIC_NPM_CACHE=<已有公开cache目录> \
  sh scripts/test-edge-offline.sh
```

脚本只读已有 jose 6.2.12 / postgres 3.4.7，通过 ignored import map 映射，禁网络并忽略环境变量；不安装依赖、启动服务或连接 PostgreSQL。定点育儿 HTTP 回归也可使用支持 `stripTypeScriptTypes` 的已有 Node：

```sh
node --no-warnings \
  --import ./qa/family-cloud-verification/offline/offline-prelude.mjs \
  --import ./services/edge/test/support/node-strip-loader.mjs \
  --test services/edge/test/parenting-intake-http.test.mjs
```

该用例运行实际 handler / ChatService，加合成身份、模型和 Repository，不证明真实 SQL 多实例、供应商响应或线上部署。GitHub 使用既有 [`scripts/ci-node-tests.sh`](scripts/ci-node-tests.sh)；其依赖与 quarantine 边界在脚本中，不与上面的本机禁网命令混称同一证据。

## 来源与部署边界

`SOURCE-MANIFEST.json` 保留原 v14 身份；`P0-PROVENANCE.json` 和 `P0-FINALIZATION-MANIFEST.json` 保留当时差异、修复字节与合成结果。原验收见[后端 P0](../../docs/acceptance/backend-p0-finalization.md)与[固定目录整合](../../docs/acceptance/local-fixed-directory.md)。[deployed-baselines](deployed-baselines/README.md)是当时 API v19 / tick v7 的只读来源，14 个共享文件差异保留，不能覆盖快照或改 manifest 冒充同版。

配置模板、固定上游及 MIT 原文保留；本目录不包含生产凭据。OpenMuse 来源见 [pinned upstream](../../vendor/openmuse/README.md)与 [MIT license](../../vendor/openmuse/LICENSE)。其他 owner 的 canonical 未跟踪候选和脚本不会自动进入本目录。

部署前须冻结候选、核对现有线上来源、适用入口和数据合同，并准备验证及回退；合并、部署和发版仍需用户单独确认。离线测试、旧部署快照和平台状态均不能证明当前育儿链路已在线上可用。
