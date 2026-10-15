# Catpaw-m

Swift优先的通用主动Agent应用：自然对话、可恢复任务、审批、成果、记忆与持续跟进。当前处于重启整合阶段，真实产品验收尚未通过；readiness、合成测试和安装成功都不等同模型/主动任务可用。

本仓是用户指定维护目录的主代码入口。旧本地仓和工作树保留为来源；原始历史只在本地保存。GitHub发布基于远端main，使用经检查的差异，不发布机器/签名凭据。

| 内容 | 入口 |
|---|---|
| 长任务开发与对话交互 | [启动合同](docs/planning/AF-1/development-start-contract.md)、[可复制prompt](docs/planning/AF-1/long-task-development-prompt.md)、[CGUI-1](docs/design/conversation-generative-ui-spec.md)、[10项验收](docs/acceptance/conversation-generative-ui-acceptance.md) |
| Goal与唯一实时进度 | [master-plan](docs/status/master-plan.md) |
| 新spec / 验收 | [AF-1 spec](docs/product/agent-foundation-spec.md) / [验收标准](docs/acceptance/agent-foundation-acceptance.md) |
| 切片与依赖 | [delivery-slices.json](docs/status/delivery-slices.json) |
| iOS主工程 | [apps/ios-conversation](apps/ios-conversation/README.md)，CatpawM.xcodeproj |
| 服务端 | [services/edge](services/edge/README.md)，supabase/functions/ 下 catpaw-api＋_shared；独立tick入口见部署来源快照 |
| 云电脑讨论 | [Proposed方案](docs/architecture/cloud-computer-proposal.md)，确认前不实施 |
| 接手 / 来源 | [handoff](handoff.md) / [候选hash](docs/status/restart-import-candidate-2026-10-13.json) |
| 架构与目录职责 | [最新代码与分支复核](docs/architecture/repository-review-2026-10-15.md) / [布局表](docs/development/repository-layout.json) / [2026-10-13基础审查](docs/architecture/repository-review-2026-10-13.md) |
| Git治理 / 文档 | [branch-management](docs/development/branch-management.md) / [docs](docs/README.md) |
| 历史过程资料 | [归档索引](docs/archive/README.md)，旧规格与阶段报告保留追溯，不作为当前开工入口 |

## 本地验证

需要已有Xcode；原生Swift与本地两个package无新增依赖。运行时模型与Supabase配置沿用本地配置/安全存储，不提交凭据。无配置可跑明确的离线合成测试，不能制造正常产品回答。

```sh
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
python3 scripts/check-agent-foundation-plan.py
zsh apps/ios-conversation/Scripts/test-conversation-portable.sh
zsh apps/ios-conversation/Scripts/test-conversation-queue.sh
zsh apps/ios-conversation/Scripts/check-source.sh
```

SwiftUI宏、XCTest和Simulator可能需要主机允许相应进程。`CatpawM`方案的Debug测试使用人工fixture；`DeviceTrial`用于真实产品构建。模型、PG、安装与系统动作按同版验收记录执行。历史apps/ios、apps/ios-openmuse-demo和冻结来源保留，不用作当前入口。
