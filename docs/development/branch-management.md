# 开发分支与整合规范

本文件的操作规则持续有效；下文“本轮结果”和“远端保留”是 **2026-10-13 日期快照**。2026-10-15 的分支整合与当前保留边界见[新架构复核](../architecture/repository-review-2026-10-15.md)，实时交付状态仍只在[主计划](../status/master-plan.md)。

2026-10-13按本地Git、旧工作树、GitHub分支/PR和管理页重新核对。当前唯一主干是 `main`；GitHub默认分支已设为main，合并后自动删除head分支已启用。[本轮审查](../architecture/repository-review-2026-10-13.md)与[分支快照](../status/branch-inventory-2026-10-13.json)记录实际操作。

## 分支与工作树

| 分支/引用 | 规则 |
|---|---|
| `main` | 已集成、可追溯源码；功能通过PR进入。源码集成不等于真实产品签收 |
| `feat/<slice-topic>` | 一片可验收功能，例如 `feat/s03-plan-persistence` |
| `fix/<topic>`、`refactor/<topic>` | 一个故障或一个有回归证据的结构调整 |
| `docs/<topic>`、`chore/<topic>` | 规格/治理、工具与维护；不夹带未审阅业务实现 |
| `test/<topic>` | 独立验证，固定被测SHA；结果注明真实/合成层 |
| `docs/restart-design-integration` | 本轮把原51项未提交文档从main原样带出的临时整合分支；收齐后PR合入并删除，不发展为第二主干 |
| `refs/remotes/legacy-local/*` | 9个只读原始来源引用，与GitHub历史无共同祖先，永不整段推送或强行merge |

分支名用小写英文/数字/短横线，可有一个子路径；一个分支一个主题。当前不设长期develop、integration或按人员命名的维护分支。多人/多任务并行时一份工作树只有一个写入者；共享工作树里的WIP不能直接全量暂存、重置、stash或拿去他处发布。

新工作从已核对的origin/main建立短分支。已有未提交内容先按明确文件清单保存/提交；不要切换分支让别人的改动进入main。可用CLI身份时先fetch并用 `pull --ff-only`；无身份时使用既有GitHub连接器，读回commit/tree，不能提取token或绕过SSH主机校验。新分支首次实际发布后才设upstream。

## PR与验收

PR默认base为main，提交一个可审阅结果：具体问题、修改后行为、验证命令/结果、源码/包/部署身份及未验范围。使用[模板](../../.github/pull_request_template.md)，已有commit与合成结果不能替代真实模型/数据库/设备验收。

合入前至少运行：

```sh
python3 scripts/check-repository-layout.py
python3 scripts/check-repository.py
python3 scripts/check-deployed-source.py
python3 scripts/scan-repository.py
git diff --check
```

规划/验收变更加跑相关AF/FINAL/CGUI检查；业务代码按受影响组件及用户路径验证。测试数不作为完成指标。连接器创建PR后附到当前任务，合并后读回远端commit/tree；本地仅在安全保留WIP后对齐，禁止硬重置代替整合。

默认保留merge commit，方便来源和祖先回溯。若使用squash，另记录原SHA/PR/tree；删除前核对内容已合入，不能只看旧branch祖先。不得对公开分支force push，也不得用allow-unrelated-histories连接旧本地历史；从旧来源选取经审核字节，并保存provenance。

## 清理规则与本次结果

删除前确认：无活动工作树占用、无未保留WIP、branch SHA已记录、无未整合独有提交/开放PR。先归档，再用 `git branch -d`，不使用-D。远端分支删除后只移除相同SHA的缓存引用；main与未合入候选不批量删除。

本轮已清理6个合入PR #1–6的远端短分支，加上已被main包含的prepare/local-assets与integration/local-fixed-directory，共8个；4个对应本地短分支及旧origin缓存已移除。全部tip在main历史中，完整本地历史bundle与原WIP已在local-audit备份，旧主仓/6个旧工作树与legacy-local引用未动。

2026-10-13 当日远端保留：

- `main`：当前源码基线。
- `feat/grok-cat-companion`：3个独有提交、落后main4个；产品/视觉参考，另一套内存App不合入宿主，保留固定来源。
- `feat/proactive-goal-kernel`：4个独有提交、落后main13个；合成内核和恢复屏障候选。先选取与现有领域接口相容的机制，按S03/S05单独移植/验证，不直接覆盖主计划、存储或协议。

## 已启用规则与实际限制

本仓配置：pull.ff=only、push.default=simple、push.autoSetupRemote=false、fetch.prune=true、remote.pushDefault=origin、core.hooksPath=.githooks。legacy-local的push地址禁用；9个来源引用保留。

[pre-commit](../../.githooks/pre-commit)拒绝main/不规范分支与明显私有/生成文件路径；[pre-push](../../.githooks/pre-push)限制origin目标、拒绝直接写main、非快进和无关历史。9个只读正反例已核对。内容敏感扫描仍需单独运行；hooks不读取真实账号、模型或数据库。

这些是本机CLI防误操作规则，可被绕过且不覆盖连接器、API、浏览器或另一台机器。新checkout需运行 `git config --local core.hooksPath .githooks` 并复核本仓配置，不覆盖已有自定义hook而不检查。

GitHub当前私有仓库的rulesets读请求返回403，classic页面明确提示“该私有仓库规则不会执行，需迁移到相应组织套餐”。未升级套餐、未改公开、未创建假生效规则。因此服务器强制PR/禁止force/delete **尚未生效**；当前按PR规范、本地hook及人工读回执行，不能称全面受保护。
