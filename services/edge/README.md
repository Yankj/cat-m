# API v14 baseline and undeployed dialogue P0

本地维护入口为 `supabase/functions/catpaw-api/index.ts`，共享实现位于 `_shared/`。本目录没有 `catpaw-worker` 或独立 `catpaw-tick` 入口；线上tick v7的入口保存在deployed-baselines来源快照，不能据此声称本地维护树已经齐版。本地整合包含 v14 已部署来源基线、冻结 dialogue P0 和撤权失败收尾修复；这不表示 P0 已部署。当前进展只维护在 [主计划](../../docs/status/master-plan.md)。

`SOURCE-MANIFEST.json` 保留原 v14 身份；`P0-PROVENANCE.json` 描述来源差异，`P0-FINALIZATION-MANIFEST.json` 描述修复字节和原合成结果。不要用新 manifest 覆盖旧部署历史。配置模板、上游固定来源、worker 与 MIT 原文保留；本目录不包含凭据或生产运行配置。

## 本地离线验证

在仓库根目录，提供已有 Deno 和公开依赖缓存：

```sh
CATPAW_DENO_BIN=<已有Deno路径> CATPAW_PUBLIC_NPM_CACHE=<已有公开cache目录> \
  sh scripts/test-edge-offline.sh
```

脚本只读已有 jose 6.2.12 / postgres 3.4.7，通过忽略的 import map 映射原测试引用，禁网络并忽略环境变量。未安装依赖、启动服务或连接 PostgreSQL。原 owner 命令和补丁范围见 [后端 P0 验收](../../docs/acceptance/backend-p0-finalization.md)，本次固定目录结果见 [整合验收](../../docs/acceptance/local-fixed-directory.md)。

canonical 未跟踪的 worker-stall/长授权候选和 `scripts/catpaw` 未导入；本目录没有该启动脚本或候选目录。实际部署、真实 PG/多实例、worker 恢复/长期调度、视觉模型和设备链路由协调安排。不要从离线完成标记推断真实成果。OpenMuse 来源归属见 [pinned upstream](../../vendor/openmuse/README.md) 与 [MIT license](../../vendor/openmuse/LICENSE)。

## 维护与来源边界

当前职责见[目录角色](../../docs/development/repository-layout.json)与[架构审查](../../docs/architecture/repository-review-2026-10-13.md)。[部署来源](deployed-baselines/README.md)是当时API v19/tick v7的只读快照，14个共享文件不同；新功能进入维护代码，源对齐与API/tick双入口验证完成后再准备部署。不要用任意一份_shared覆盖全部版本，或覆盖旧manifest宣称已通过。
