# catpaw-api 部署记录（生产 <your-project-ref>）

整理时间 2026-10-18（UTC+8）。本文件不含任何密钥。部署包（bundle）不入库，可按下文从提交重建。
约定（2026-10-17）：只从已推送到 origin 的 SHA 部署；部署当天合入 main（分支历史已有 merge commit 时用 merge commit，保留生产 SHA，不 squash）；每个函数版本 ↔ SHA 都记在这里。

## 当前生产

- **catpaw-api v53 = `59b5aae6`**（fix/context-window-v11x），2026-10-17 22:21 部署；main `694d19ec`（PR #96）与之一致。
- **回滚目标：catpaw-api v52 = `a00518f4`**（fix/vision-route-fallback-r3）。
- catpaw-proactive v9（792587e 构建）、catpaw-tick v16：本轮未改动。

## 生产版本对应

| 函数版本 | 源提交 | 分支 / PR | 部署时间（UTC+8） | 内容 |
|---|---|---|---|---|
| catpaw-api v43 | `952ca4e` | `chore/w5-opencode-zen` | 10-16 | #72 改为 OpenCode Zen 直连 |
| catpaw-api v45 | `c20ddd5` | `chore/w6-gemini-default` | 10-16 | w6：默认路由改 Gemini。v46/v47 是 Management API 计数（= Dashboard + 1），内容仍是 w6 |
| catpaw-api v48 | `792587e` | `chore/catpaw-final` | 10-17 13:40 | 最终集成（含 #89/#90/#91 返工）；index.ts `d75898a2…` |
| catpaw-api v49 | `e9383ca`（= `99e5296` 字节一致） | `fix/chat-runtime-lock` → PR #92 | 10-17 14:10 | chat runtime lease 修复；index.ts `447f9cea…` |
| catpaw-api v50 | `cd780f7c` | `fix/v11-edge-a` → PR #93 | 10-17 18:15 | v1.1 备选版 a（chat context）；index.ts `fc4a6f90…` |
| catpaw-api v51 | `51e76163` | `fix/v11-edge` → PR #94 | 10-17 19:20 | v1.1 完整版 r3（账号级模型同意）；index.ts `181505ad…` |
| catpaw-api v52 | `a00518f4` | `fix/vision-route-fallback-r3` → PR #95 | 10-17 19:51 | 免费视觉路由链 r3（图片上传）；index.ts `e13a61e3…6180` |
| **catpaw-api v53（当前）** | **`59b5aae6`** | `fix/context-window-v11x` → PR #96 | **10-17 22:21** | 上下文滑动窗口、413 conversation_too_long、model_history_conflict 移除失败 turn、Gemini 占位思维签名、实时文本预览 text_preview；index.ts `12e12652…57c7` |

所有版本的 deno.json 均为 `bca24584…`，verify_jwt=false，入口 `catpaw-api/index.ts`，import map `deno.json`。

catpaw-proactive v9：10-17 13:44 从 792587e 部署（index.ts `445abb73…`）；HEAD 构建只差 ApiError 的可选参数，无行为变化。

## 迁移

- 10-17 13:36–13:37 应用了 9 个迁移（proactive_cron … proactive_feedback_kind_intrusive），pg_cron 1.6.4 / pg_net 0.20.4 已启用。
- 10-17 17:01 应用 `20261017060000_agent_memory_extensions_usage`（`grant usage on schema extensions to catpaw_records;`，sha256 `174d5d83…7c7f`，用户批准）；prod 版本 `20261017090112`。仓库提交 `cf5287a8`。文件头注释“WRITTEN ONLY — NOT APPLIED”写于应用之前，已过时。回滚：`revoke usage on schema extensions from catpaw_records;`
- repo 文件名和 prod 迁移版本号不一致（按名字对应），`supabase db push` 会报 drift；用 CLI 前要先对齐。

## 构建（esbuild）

在 `services/edge/supabase/functions` 下执行（v43、v49、v52、v53 已验证从提交重建与线上 index.ts 逐字节一致）：

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
- 生产部署、迁移、改 secret 必须由用户本人在对话中明确确认；冒烟测试（会写生产）也要单独批准
- 部署前备份当前版本，部署后用 get_edge_function 回读 index.ts / deno.json 哈希

## 回滚（当前 v53 → v52）

1. 只关 Gemini 占位签名，不重新部署：设置 `CATPAW_GEMINI_PLACEHOLDER_SIGNATURE=false`（env 变更，需用户单独批准）。
2. 完整回滚：先等进行中的窗口化 turn 结束（只读查 running/awaiting_approval 且 model_window_start>0 的 turn 数为 0，最多等 10 分钟），再 checkout `a00518f4`，用上面的命令重建（index.ts 应为 `e13a61e3…6180`），以同样参数重新部署 `catpaw-api`。
3. v52 的视觉路由可以不重新部署就回退：`CATPAW_VISION_ROUTE=legacy`（单路 Gemma）。
4. 回滚后只读检查：`/healthz`、`/readyz`（ready=true、vision_route）、函数日志无 5xx、无启动错误。

更早的回滚目标：v51 = `51e76163`，v50 = `cd780f7c`，v49 = `99e5296`。

## 未完成

- v52、v53 的冒烟测试未获批准，没有跑（发图走 Gemini、429 回退、Retry-After；长回复/表情中文流式）。
- catpaw-proactive `/health` 为 apns:false：APNs 的 secret 组不完整，推送会是 apns_not_configured。
- 文本路由：openrouter 429 → gemini 400 provider_failed → agnes ok（v52 部署前就有，非回归）。
- GitHub Actions 自 10-17 18:14 起没有 runner（额度/账单），#93–#96 的 CI 待补跑。
- 迁移版本号与 prod 不对齐（见上）。
