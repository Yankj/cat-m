# 已交付 iOS v1

这是已交付 `CatpawM native delivery v1` 的源码维护快照，36 个 App Swift 文件。业务源码、资源、Xcode project 和测试从 v1 保持字节一致；原 spec 的 10 项 hash 保持一致。整理仅移动项目归属回归测试到 `Tests/ProjectReplyOwnershipRegression.swift`、更新其脚本引用，并将原生测试日志输出改到被忽略的 `.build`。

打开 `CatpawM.xcodeproj`，选择共享 `CatpawM` scheme。默认模拟 provider 不联网；演示数据分区每次启动需主动开启，用户分区与演示分区隔离，存储禁用 CloudKit。

源码职责：`Domain` 管身份/状态/策略，`Persistence` 管 Repository/SwiftData/内容文件，`Providers` 管 provider/流观察，`Features` 管原生页面和服务，`Voice` 管主动授权与音频 session，`DesignSystem` 管语义颜色与组件。`Development/gateway` 是零依赖合成演示、不是 OpenMuse façade。

```sh
zsh Scripts/check-source.sh
zsh Scripts/test-portable.sh
zsh Scripts/test-gateway-portable.sh contract
```

原生测试由 `Scripts/test-ios.sh [unit|ui|all]` 执行，调用者显式提供已有 Xcode 的 `DEVELOPER_DIR` 与已有设备的 `CATPAW_SIMULATOR_UDID`。本轮仓库准备不运行它，也不记录实际设备身份。该脚本会启动测试 App/Simulator；它不修改全局 Xcode 选择。原始 Xcode 工程不是重新生成的，不要用生成脚本覆盖已有用户修改。

冻结输入在 [docs/spec](docs/spec/README.txt)。它描述目标与历史开工条件；当前完成程度以仓库 [状态记录](../../docs/status/README.md) 与 [验收矩阵](../../docs/acceptance/README.md) 为准，不能将冻结规格里的目标当完成证明。
