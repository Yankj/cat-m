# 维护约定

每次变更在 [唯一主计划](docs/status/master-plan.md) 更新当前进展，适用验收与源码对应证据另按实际版本留存；其他索引只链接主计划，不维护并列状态/里程碑。明确fixture、合成本地façade、真实模型与云服务四层；测试计数写明来源、源码hash和最后实际运行层。没有成功终态的编译/测试不能标通过，局部PASS不代替产品接受。

当前原生维护入口为 `apps/ios-conversation/CatpawM.xcodeproj`，接手按 [handoff](handoff.md) 与 AF-1 合同核对。`apps/ios` 保留冻结 v1，`apps/ios-openmuse-demo` 保留冻结 r3；[旧整合记录](docs/status/openmuse-integration.md)只用于来源回溯。禁止覆盖另一任务的活动写目录；接口冻结文件不得顺手格式化。

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
