# 贡献指南

[← 返回 README](README.md)

## 分支、提交与 PR 约定

- **分支**：从最新 `main` 拉，命名 `feat|fix|docs|chore|refactor|test/<topic>`，一个分支一个主题；不在 `main` 直接提交，不 force-push 公开分支，不用 `--no-verify` 跳过 hook。
- **提交**：小步提交，一个提交一件事，信息写清「改了什么、为什么」。
- **作者身份**：必须使用 GitHub noreply 邮箱（`git config user.email "<id>+<用户名>@users.noreply.github.com"`），并在 GitHub 开启邮箱隐私。网页端合并同样如此。
- **PR**：base 为 `main`，用 [PR 模板](.github/pull_request_template.md)；默认 **merge commit**（不 squash，保留祖先）；合并后删除分支。被取代的 PR 关闭并注明取代者与原分支 SHA。
- **官网**：已迁出到 [Yankj/heydusk-site](https://github.com/Yankj/heydusk-site)，官网相关改动请在那个仓库提 PR。
- **需要所有者批准**：后端部署、数据库/迁移、发版与 tag、`.github/workflows` 改动。
- **不得提交**：密钥、`.env`、`Local.xcconfig`、真实用户数据、构建产物。

## 快速流程

1. 从最新 `main` 拉短分支（见 [分支规范](docs/development/branch-management.md)），不要在 `main` 直接提交。
2. 只改维护入口：iOS `apps/ios-conversation`，后端 `services/edge/supabase/functions`；冻结目录不改。
3. 运行下方提交前检查与相关测试（见 [README · 开发与测试](README.md#开发与测试)）。
4. 按 [PR 模板](.github/pull_request_template.md) 写明改动、实际运行层与证据。
5. Bug / 需求请用 [Issue 模板](.github/ISSUE_TEMPLATE/)。

## 维护约定

每次变更在 [唯一主计划](docs/status/master-plan.md) 更新当前进展，适用验收与源码对应证据另按实际版本留存；其他索引只链接主计划，不维护并列状态/里程碑。明确fixture、合成本地façade、真实模型与云服务四层；测试计数写明来源、源码hash和最后实际运行层。没有成功终态的编译/测试不能标通过，局部PASS不代替产品接受。

当前原生维护入口为 `apps/ios-conversation/cat.xcodeproj`，接手按 [handoff](handoff.md) 与 AF-1 合同核对。`apps/ios` 保留冻结 v1，`apps/ios-openmuse-demo` 保留冻结 r3；[旧整合记录](docs/status/openmuse-integration.md)只用于来源回溯。禁止覆盖另一任务的活动写目录；接口冻结文件不得顺手格式化。

规格基线保留在 `apps/ios/docs/spec`；新增需求和实现差异写 `docs/product`，实际实现以 `Sources` 为准。关键授权/状态/数据归属决策写 `docs/architecture`。长期保留精选合成截图、稳定验收记录和源 hash；每轮构建/截图缓存留在忽略目录，重要失败则在验收记录概述根因、修复和复验。

提交前执行：

```sh
python3 scripts/check-repository-layout.py
python3 scripts/check-repository.py
python3 scripts/check-deployed-source.py
python3 scripts/scan-repository.py
git diff --check
git diff --cached --check
git status --short
```

扫描只给出风险线索，必须审阅每个命中。不得纳入 key/token、`.env`、真实用户记录、内部资料、设备身份、绝对个人路径、构建产物或大归档；测试使用 `example.invalid`、具名合成身份和隔离数据目录。上游 LICENSE、固定 commit、原文与 patched 差异必须保留。未来实际发布前再次获取远端引用，确认无新用户修改，再按用户授权行动。分支用途、历史隔离与同步流程见 [分支管理](docs/development/branch-management.md)。

本仓已启用 `.githooks` 的CLI分支/路径/推送守卫，详见[分支规范](docs/development/branch-management.md)。它不替代内容敏感扫描和实际验证，也不覆盖连接器/API/浏览器；这些途径仍按同一主题的PR和commit/tree读回整合。当前私有仓库服务器保护未生效，不将规则文档当强制保护证明。
