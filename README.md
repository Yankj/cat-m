# Catpaw-m

Catpaw-m 的主线是对话、服务端任务执行及成果回流。本仓库是固定本地目录中的独立整合仓库：保留 canonical 历史，只整合已提交源码，不移动旧仓和 owner worktree。来源与本轮边界见 [整合来源](docs/status/local-integration-source.json)；唯一实时进展仍是 [主交付计划](docs/status/master-plan.md)。局部离线通过不能代替当前 R1 产品验收。

## 工程入口

| 模块 | 实际入口 | 本次固定目录边界 |
|---|---|---|
| 主 iOS 客户端 | [apps/ios-conversation](apps/ios-conversation/README.md)，`CatpawM.xcodeproj`；`Sources/App/CatpawApp.swift` → `ConversationFirstView` | 已整合两项指定 P0 提交；本地配置为空，保留来源签名设置，不安装、不启动生产 Auth |
| 服务端 | [services/edge](services/edge/README.md)，`supabase/functions/catpaw-api/index.ts` / `catpaw-worker/index.ts` | v14 基线＋未部署 dialogue P0 / 撤权失败收尾；离线测试不代表真实 PostgreSQL 或云部署 |
| 侧栏组件 | [packages/ios-navigation](packages/ios-navigation/README.md) | 已整合独立组件；**未接入主 iOS 宿主**，不能据此声称已可用 |
| 独立 QA | [qa/ios-dialogue-p0](qa/ios-dialogue-p0/REPORT.md)、[qa/backend-finalization-p0](qa/backend-finalization-p0/REPORT.md) | 已提交的测试与报告；iOS QA 的冻结输入早于后续 P0 bridge，不扩大为当前全量通过 |
| 历史样机 | [apps/ios](apps/ios/README.md)、[apps/ios-openmuse-demo](apps/ios-openmuse-demo/README.md)、[services/facade](services/facade/README.md)、[services/offline](services/offline/README.md) | 保留 v1/r2/r3 的字节、合同和历史回归，不用作主客户端入口 |
| 候选与其他资产 | canonical 中的未跟踪 `candidates/`、`assets/`、`research/`、开发脚本等 | 本批未导入，固定目录中没有这些内容；worker-stall / 新视觉链 / 长期授权不在本次整合范围 |

文档从 [docs/README.md](docs/README.md) 开始。设计 tokens、A1 图标、上游 MIT 与冻结合同保持来源身份。

## 本地检查

使用已安装 Xcode，按实际位置设置进程 `DEVELOPER_DIR`，不要更改全局选择。以下只构建或执行合成测试，不安装 App：

```sh
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
zsh apps/ios-conversation/Scripts/check-source.sh
zsh apps/ios-conversation/Scripts/test-conversation-portable.sh
zsh apps/ios-conversation/Scripts/test-conversation-queue.sh
swift test --package-path packages/ios-navigation --scratch-path packages/ios-navigation/.build-verification
packages/ios-navigation/Scripts/verify-ios-sdk.sh
```

无签名 Simulator 构建：

```sh
xcodebuild -project apps/ios-conversation/CatpawM.xcodeproj -scheme DeviceTrial \
  -configuration DeviceTrial -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apps/ios-conversation/.build-integration CODE_SIGNING_ALLOWED=NO build
```

后端离线测试复用**已有公开依赖缓存**，不安装、不读取 `.env`、禁网络。提供已有 Deno executable 和缓存路径后运行：

```sh
CATPAW_DENO_BIN=<已有Deno路径> CATPAW_PUBLIC_NPM_CACHE=<已有Deno公开cache目录> \
  sh scripts/test-edge-offline.sh
```

该脚本在忽略的 `services/edge/build/` 生成 import map，将固定版本 jose/postgres 指向已有公开缓存；原生产源码/测试/lock 不改。没有缓存时明确失败，不联网补齐。原 QA `prepare.py` 需要相应冻结输入，且会重写其报告；不要在当前目录随意运行它或用新版本替换旧证据。

运行时 public config、凭据、设备安装、侧栏宿主接线、云部署与 GitHub push 均另由协调安排。首次整合记录中的远端状态是当时的快照；当前 GitHub 分支按分支管理约定维护。具体本次结果见 [固定目录验收](docs/acceptance/local-fixed-directory.md)。维护约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，分支职责与同步方式见 [分支管理](docs/development/branch-management.md)。
