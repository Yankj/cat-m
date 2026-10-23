# mimi 原生宿主（iOS）

本目录是唯一持续维护的 iOS App：Swift 5 / SwiftUI、iOS 17+、SwiftData、本机加密账本与 URLSession SSE。工程入口为 [`cat.xcodeproj`](cat.xcodeproj)。当前产品按[确认的 M1–M6 Roadmap](../../docs/product/mimi-roadmap.md)推进，候选默认进入“今天”；聊天是辅助入口。实际构建、原生操作、真机与线上结果只在[主计划](../../docs/status/master-plan.md)记录，不用旧 P0 或主动出行演示替代育儿验收。

## 维护入口

| 位置 | 职责 |
|---|---|
| `Sources/App/catApp.swift` / `NativeAuthApplicationModel.swift` | 登录、账号生命周期和宿主页面组合 |
| `Sources/Features/Parenting/` | 今天、孩子与成长、记录；原位整理、明确采用与确认 |
| `Sources/Domain/ParentingWorkspace.swift` / `ParentingIntakeDraft.swift` | 本机安排、完成与观察语义；AI 候选合同 |
| `Sources/Persistence/ParentingWorkspaceStore.swift` | 账号/分区隔离、加密持久化、版本检查与幂等 |
| `Sources/Providers/NativeChatHTTPBackend.swift` | 现有认证、受限整理请求、原请求查询与删除回执 |

Views 通过应用模型/服务使用 typed 合同；AI 候选、已保存安排、家长完成和系统提醒是不同事实。本机育儿账本没有接入家庭云同步或系统提醒。账号与存储细节见[架构](../../docs/architecture.md)，页面/操作边界见[育儿交互合同](../../docs/design/family-companion/parenting-core.md)。显示品牌为 mimi / 小咪，工程、Bundle、Keychain、存储和协议的[内部标识](../../docs/internal-identifiers.md)保留兼容。

## 验证入口

在本目录运行 `python3 Scripts/validate-project.py` 检查工程成员。已有完整 Xcode 和 iPhone simulator runtime 时，`Scripts/test-parenting-core-simulator.sh` 在独立空白模拟器运行育儿模块及 UI 合成旅程；它要求先完成 `build-for-testing`，拒绝存在 Local.xcconfig 的执行目录。完整 CI 命令见 [ci.yml](../../.github/workflows/ci.yml)，结果及失败保留在[日期 CI 证据](../../docs/acceptance/family-companion/parenting-ci-2026-10-23.md)。

测试使用合成身份、输入和模型边界，不能证明真实 Auth、模型、提醒送达或真机体验。签名和运行配置需另行准备；测试说明不授权依赖安装、生产调用、设备安装或发布。运行产物放 ignored `build/`，旧验收快照和哈希不重写。

## 既有主动能力与历史演示

`Features/Proactive/` 和设备适配器是可复用来源；育儿首页没有把旧出行提醒接到本机安排。DeviceTrial / BE5C 的主动出行演示从“设置 › 调试 › 主动信号模拟”注入望京会议，定位权限或模拟起点须显式标记；提前量使用真实记忆行。该演示涉及定位、记忆和系统效果，须在对应验证授权内使用，不能计入 M1 创建到完成旅程。

旧 v1 README 曾将 inbox、attendees、suggestions 列为明文风险。当前源码通过 `ProactiveSealedStore` 将这三类 payload 放入账号 L2，并有旧值迁移及隔离逻辑；这不等于所有主动模块数据已加密。`externalPendingDecision` 的外部提醒标识/操作元数据仍经 `ProactiveEngine.externalStore` 使用 UserDefaults。复用这些模块时需按实际账号、迁移和设备测试验收，不沿用旧“v1.1 将修复”的承诺。历史实现与测试保留在 Git 和日期验收中。
