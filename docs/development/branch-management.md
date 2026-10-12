# 分支与同步约定

本仓库采用一个主干与短期功能分支。分支记录源码集成状态；产品可用性和验收结论仍以 [主计划](../status/master-plan.md) 为准。

## 分支职责

| 分支 | 用途 | 合并与保留 |
|---|---|---|
| `main` | 已检查、可追溯的 GitHub 源码基线 | 从功能分支通过 PR 合入；不直接推送功能开发，不强制推送 |
| `integration/local-fixed-directory` | 首次整理发布快照 `c1e23c28` | 保留来源锚点，后续开发从 main 新建分支 |
| `feat/<topic>`、`fix/<topic>`、`docs/<topic>` | 单一主题的功能、修复、文档 | 合入且无未提交改动后，才删除对应分支和工作树 |
| `test/<topic>` | 独立 QA，绑定被测源码提交 | 保留报告与被测 SHA；验收结果不自动并入产品源码 |
| `local/*`、`import/*` | 早期本地历史、来源导入 | 本地保留；不把原始历史直接推送到 GitHub |
| `prepare/local-assets` | 首次初始化分支 | 临时保留；将 GitHub 默认分支切到 main 后再评估清理 |

现有 owner 工作树继续由原任务维护。正在使用、存在未提交修改或尚未整合的分支不能自动删除或重置。

## 首次发布的历史边界

本地原始代码历史从 `358d689b` 开始；GitHub 的初始化历史从 `c1075e10` 开始。二者没有共同祖先。首次发布通过连接器创建了 `c1e23c28`，其源码对应本地 `cc10a722`，两份签名配置已参数化，具体差异见 [PUBLICATION.json](../../PUBLICATION.json)。

同名分支不代表同一条历史。禁止将早期本地 integration 分支直接设置为远端同名分支的 upstream，禁止用 force push 或 merge --allow-unrelated-histories 连接两套历史。原始历史包含只应保留在本地的签名和机器记录。

后续发布以 GitHub main 为基线，逐次导入经过检查的源码差异和文档；提交注明来源 SHA、验证层和剩余门槛。不要整段推送早期本地历史。

## 日常开发

已有可用 Git CLI 身份时：

```sh
git fetch origin --prune
git switch main
git pull --ff-only
git switch -c feat/topic
# 修改、检查、提交
git push -u origin HEAD
```

为并行任务创建独立工作树：

```sh
git worktree add -b fix/topic ../catpaw-topic origin/main
git worktree list
git branch -vv
```

当前发布使用已有 GitHub 连接器。连接器身份不会自动提供给终端；终端没有现成认证时由连接器发布，再读回验证 commit/tree。不要通过复制 token、绕过 SSH 主机校验或新增凭据解决分支问题。

本地建议配置：

```sh
git config --local pull.ff only
git config --local push.default simple
git config --local push.autoSetupRemote false
git config --local fetch.prune true
git config --local remote.pushDefault origin
```

新功能分支仅在首次明确发布后建立 upstream。本地历史分支没有 GitHub upstream；导入来源 remote 仅用于读取，不向来源工作区推送。

## 提交与清理

提交前运行 CONTRIBUTING 中的完整性、敏感信息和 diff 检查；仅有源码快照不代表编译、CI、真实模型或产品验收通过。PR 写清触发问题、修改后行为、实际检查和未验范围。

清理顺序：确认远端 PR 已合入 main，确认工作树干净，确认分支没有未保留提交，再移除工作树、用 `git branch -d` 删除本地分支，最后删除对应远端分支。不要使用 `-D`、强制覆盖或无范围的批量删除。验收证据和来源分支按实际归档需要保留。

GitHub 默认分支应为 main。现有连接器未提供修改默认分支及分支保护的接口；在仓库 Settings → General → Default branch 将其设为 main。可随后在 Rulesets 要求通过 PR 合入并禁止删除和强推；未实际设置前不要声称这些服务器规则已生效。
