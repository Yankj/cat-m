<a id="readme-top"></a>

<div align="center">

# cat

本地品牌迁移与保留身份见 [兼容说明](docs/development/cat-brand-migration.md)，验证范围见 [本地记录](docs/acceptance/cat-brand-2026-10-22.md)。

家庭成长助理入口：[主计划与当前范围](docs/status/master-plan.md) · [本地与云端总交接](docs/acceptance/family-companion/handoff-2026-10-23.md) · [独立官网候选及验证说明](https://github.com/Yankj/cat-m/tree/7ca0c4535dbfb6419a5000eab8275d08be051ceb/apps/website/family)。

**先你一步，把事办妥。** · *A step ahead. Things handled.*

对话优先的主动式个人助理 iOS App：自然对话 → 可审批的计划与设备动作 → 可恢复的任务与成果，人始终在回路中。

![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-SwiftData-0D96F6?logo=swift&logoColor=white)
![Supabase Edge](https://img.shields.io/badge/Supabase-Edge%20Functions-3ECF8E?logo=supabase&logoColor=white)
![Deno](https://img.shields.io/badge/Deno-tests-000000?logo=deno&logoColor=white)
![Backend](https://img.shields.io/badge/catpaw--api-v55%20(prod)-3ECF8E)
![App](https://img.shields.io/badge/App-v1.2.0%20on%20main-brightgreen)
[![下载](https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-Releases-2EA44F?logo=github&logoColor=white)](https://github.com/Yankj/catpaw-m/releases/latest)
![License](https://img.shields.io/badge/license-TBD-lightgrey)

<img src="docs/assets/slides/slide-01.png" alt="cat 介绍图" width="720">

<sub>设计示意（演示幻灯片封面），非 App 实拍。</sub>

[产品官网](#产品官网) · [快速开始](#quick-start) · [下载与安装](#下载与安装) · [功能](#核心功能) · [演示](#演示) · [架构](#架构) · [文档索引](docs/README.md) · [详细架构](docs/architecture.md) · [贡献指南](CONTRIBUTING.md)

</div>

> [!NOTE]
> **版本状态（2026-10-18）**：iOS **v1.2.0**（2026-10-18）已发布，见 [Releases](https://github.com/Yankj/catpaw-m/releases/latest)，下表所有能力都在 `main` 上；版本记录见 [CHANGELOG](CHANGELOG.md)。线上后端为 `catpaw-api` **v55**（#104）、`catpaw-proactive` **v10**（#101）。逐项进展以 [主计划](docs/status/master-plan.md) 为准。

<details>
<summary><b>目录</b></summary>

- [产品官网](#产品官网)
- [背景](#背景)
- [核心功能](#核心功能)
- [Quick Start](#quick-start)
- [下载与安装](#下载与安装)
- [使用](#使用)
- [演示](#演示)
- [架构](#架构)
- [目录结构](#目录结构)
- [配置参考](#配置参考)
- [开发与测试](#开发与测试)
- [Roadmap 与已知限制](#roadmap-与已知限制)
- [文档地图（Diátaxis）](#文档地图diátaxis)
- [Contributing](#contributing)
- [License](#license)
- [给 AI 助手的上下文](#给-ai-助手的上下文)

</details>

<!-- CATPAW-WEBSITE:START -->
## 产品官网

**先你一步，把事办妥。** 一个住在 iPhone 里的贴心助理。记住你的偏好，在合适的时候提醒你，确认后把事情办好。

[浏览官网](https://catpaw-product.kunjie-yan.chatgpt.site/) · [观看产品视频](https://catpaw-product.kunjie-yan.chatgpt.site/#film) · [25 页产品介绍](https://catpaw-product.kunjie-yan.chatgpt.site/assets/catpaw-product-deck.pdf) · [安全与隐私](https://catpaw-product.kunjie-yan.chatgpt.site/trust.html) · [技术设计](https://catpaw-product.kunjie-yan.chatgpt.site/technology.html)

- **主动**：到点之前，先来找你。
- **有记忆**：记住偏好，也真正用上。
- **能执行**：写进日历，留下回执。
- **可信**：先问你，再动手。

官网源码位于 [apps/website](apps/website)，独立构建与部署。演示素材保留 v1.1 版本；当前入口、状态与限制以 [能力清单](docs/product/capabilities/catpaw-capabilities.json) 和 [CHANGELOG](CHANGELOG.md) 为准。
<!-- CATPAW-WEBSITE:END -->

## 背景

传统助理 App 要么是“问一句答一句”的聊天框，要么是需要用户自己拆步骤的工具集合。cat 想做一个**先你一步**的助理：

- **从对话到行动**：用一句话说目标，助理产出计划、报告，或直接调用系统能力（日历、提醒事项、通讯录、地图），而不是只给文字建议。
- **主动但不打扰**：端上根据日历、提醒等信号判断时机，给出带“为什么找你”解释、可撤销的建议卡片。
- **人在回路**：任何会改变外部世界的动作都先以审批卡片呈现，确认后才执行；结果未知时按原决定核对，不重复执行。
- **账号隔离、可恢复**：会话、任务、成果与账号绑定；切换账号时自动停放并在重新登录时恢复，网络中断后按原 turn 续上。

本仓库同时是美团 CatPaw 面试大作业的交付仓：架构文档、可运行 App、后端源码、README 与演示材料。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 核心功能

“在哪里”一列：**main** = v1.1 之前已在 `main`；**v1.1.0** = 随 v1.1.0 发版（#98）进入 `main`；**线上 v53** = 已部署到生产的后端版本。路径相对 `apps/ios-conversation/Sources/`（iOS）或 `services/edge/supabase/functions/`（Edge）。

| 能力 | 说明 | 在哪里 | 主要代码 |
|---|---|---|---|
| 原生 Google / GitHub 登录 | Supabase OAuth（PKCE），回调 `catpawm://auth-callback`；侧栏顶部账号下拉：当前账号、切换/添加账户、退出登录；匿名试用可原地绑定 | v1.1.0 | `Domain/NativeOAuth.swift`、`Providers/NativeOAuthWebSession.swift`、`Features/NativeOAuthViews.swift` |
| 流式回复 | URLSession SSE，断线按原 turn 恢复；服务端按 512 字符 / 250 ms 批量落库 | main | `Features/ConversationSessionService.swift`、`Providers/NativeChatHTTPBackend.swift` |
| 实时逐字预览（live text） | 服务端 `text_preview` 帧约每 100 ms 一次，客户端带 `X-cat-Live-Text: 1` 才启用，旧版 App 不受影响 | 服务端 main（线上 v53）；iOS 端 v1.1.0 | `_shared/core/src/live-text.mjs`、`Features/Answer/AnswerPhaseModel.swift` |
| 上下文窗口管理 | 最近 40 条 / 80 kB 窗口按完整 turn 截断；超预算先省略旧工具结果、再缩窗口，最后返回 `413 conversation_too_long`；完整历史保留 | main（线上 v53） | `_shared/core/src/context-window.mjs` |
| 图片理解 | 相机 / 相册输入；视觉路由链 Gemini Flash-Lite → OpenRouter Gemma，`CATPAW_VISION_ROUTE=chain\|legacy` | main | `packages/ios-image-composer`、`_shared/core/src/vision-route-chain.mjs` |
| 语音输入 | 听写：iOS 26 用 SpeechAnalyzer，旧系统回退 SFSpeechRecognizer | main | `Voice/`、`Domain/DictationPolicy.swift` |
| 语音对话 | 免手动循环：听 → 发送 → 思考 → 朗读 → 继续听，支持插话打断、遇到审批卡片暂停；语音朗读回复默认开启 | v1.1.0 | `Domain/VoiceSession.swift`、`Features/Composer/ComposerDictation.swift` |
| 主动任务 | 端上规则 + 配额 + 「为什么找你」说明 + 撤销；Edge `catpaw-proactive` 负责决策与推送；含 Live Activity / Widget | main | `Features/Proactive/`、`catpaw-proactive/`、`App/catLiveActivityCoordinator.swift` |
| 设备集成 | EventKit（日历查询 / 创建、提醒事项）、Contacts（联系人搜索）、MapKit（附近地点 + 路程 ETA、打开地图），以及短信 / 邮件 / 电话 / 快捷指令跳转 | main | `Features/DeviceCalls/DeviceToolRouter.swift`、`Features/Nearby/NearbyPlaces.swift` |
| 人在回路 UI 卡片 | 审批卡片、任务计划、设备结果卡、Generative UI 内嵌组件（选择、确认、表单、列表、进度、地点、日程） | main | `Features/ConversationApprovalCardView.swift`、`Features/DeviceCards/`、`Features/GenerativeBlocks/` |
| 记忆 | 服务端 agent-memory：功能开关 + allowlist 准入，用户可关闭；`memory_forget` 需审批 | main（服务端） | `_shared/agent-memory/` |
| 记忆工具调用（iOS） | iOS 端审批工具白名单接纳 `memory_search/save/update`（自动）与 `memory_forget`（审批） | v1.1.0 | `Providers/NativeChatHTTPBackend.swift` |
| 吉祥物动画 | 毛绒猫姿态随对话状态切换（等待 / 思考 / 写作 / 执行 / 完成 / 出错） | main | `DesignSystem/catPlushMascot.swift` |
| 版本管理 | 设置 › 关于显示「版本 1.1.0 (build N) · 发布于 日期 时间」，轻点显示提交号、长按复制；构建号 = git 提交数，构建时自动写入；版本号只用 `Scripts/bump-version.sh` 修改，见 [CHANGELOG](CHANGELOG.md) 与 [iOS 版本规范](docs/development/ios-versioning.md) | v1.1.0 | `Domain/AppBuildInfo.swift`、`Features/ConversationFirstView.swift`（`AppVersionRow`） |
| 任务、成果、收件箱 | 计划生成 / 暂停 / 取消、报告阅读与编辑、待办汇总 | main | `Features/ConversationTaskPlan*`、`Features/ConversationArtifact*`、`Features/ConversationInbox*` |

<details>
<summary><b>主动能力设计示意（幻灯片）</b></summary>

<img src="docs/assets/slides/slide-04.png" alt="主动助理四条设计主张" width="720">
<img src="docs/assets/slides/slide-06.png" alt="四级主动" width="720">
<img src="docs/assets/slides/slide-08.png" alt="撤销与离线同步" width="720">
<img src="docs/assets/slides/slide-09.png" alt="多设备推送按代次领取" width="720">

<sub>设计示意，来自演示幻灯片，不是 App 实拍。</sub>

</details>

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## Quick Start

> **教程（Tutorial）**：在模拟器里跑起来，不需要任何账号或密钥。

**前置条件**

- macOS + **Xcode 26**（iOS 26 SDK；App 部署目标 iOS 17）。无第三方 Swift 依赖，两个本地 package 已随仓库检入。
- 可选：Python 3（仓库检查脚本）、Deno（Edge 离线测试）。

**步骤**

```sh
git clone https://github.com/Yankj/catpaw-m.git cat
cd cat
open apps/ios-conversation/cat.xcodeproj
```

1. 选择 scheme **`cat`**（Debug，使用人工 fixture），任选一个 iOS 17+ 模拟器。
2. `⌘R` 运行。未配置 Supabase / 模型时 App 走离线合成路径：可以浏览界面和组件，但**不会产生真实模型回答**。
3. 真实产品构建用 scheme **`DeviceTrial`**，需在本地提供公开配置与签名（见[配置参考](#配置参考)），仓库里这些值是空的。

不想自己编译时，可以直接装打包好的构建，见[下载与安装](#下载与安装)。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 下载与安装

> **操作指南（How-to）**：安装已打包的构建。所有构建都在 [Releases](https://github.com/Yankj/catpaw-m/releases/latest) 页面；仓库目前是私有的，需要有仓库访问权限才能下载。

> [!TIP]
> 最新版本：[cat 1.2.0](https://github.com/Yankj/catpaw-m/releases/tag/v1.2.0)（2026-10-18），文件为 `Catpaw-1.2.0-simulator.zip` 和 `Catpaw-1.2.0.ipa`（历史发行物，保留原名）。

| 方式 | 文件 | 适合 | 限制 |
|---|---|---|---|
| A. 模拟器 | `Catpaw-<版本>-simulator.zip` | 在 Mac 上快速体验 | 只能装在 iOS 模拟器上，不能装真机 |
| B. 真机（开发签名） | `Catpaw-<版本>.ipa` | 已登记的测试设备 | **只能装在开发者描述文件（provisioning profile）里登记过 UDID 的设备上** |
| C. 从源码构建 | — | 开发、评审 | 需要 Xcode 26 |

**A. 模拟器构建**

1. 从 Releases 下载 `Catpaw-<版本>-simulator.zip`，打开任意 iOS 17+ 模拟器（Xcode › Open Developer Tool › Simulator）。
2. 解压并安装，bundle id 从安装包自己的 `Info.plist` 读取：

```sh
unzip Catpaw-<版本>-simulator.zip -d catpaw-sim
APP=$(find catpaw-sim -maxdepth 2 -name '*.app' | head -1)
xcrun simctl install booted "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl launch booted "$BUNDLE_ID"
```

也可以直接把解压出来的 `.app` 拖进模拟器窗口安装。仓库里的默认 bundle id 是 `com.example.CatpawM.ConversationFirst.Auth`（Debug / Release）和 `com.example.CatpawM.OpenMuseDemo`（DeviceTrial）；正式包可能在本地签名配置里改过，以 `Info.plist` 为准。

**B. 真机 ipa（开发签名）**

> [!WARNING]
> 这个 ipa 用开发证书签名，**只能安装在开发者描述文件里登记过的设备上**，其他设备会安装失败。如需加入测试设备，请把设备 UDID 发给维护者重新签名。面向公众的分发需要走 TestFlight 或 App Store，目前还没有。

1. 下载 `Catpaw-<版本>.ipa`，用数据线连接 iPhone 并信任这台电脑。
2. 安装（二选一）：
   - **Xcode**：Window › Devices and Simulators › 选中设备 › 「Installed Apps」下的「+」› 选 ipa。
   - **Apple Configurator**：选中设备 › 添加 › App › 选 ipa（也可以把 ipa 拖到设备上）。
3. iOS 16 及以上运行开发签名的 App 需要先打开 设置 › 隐私与安全性 › 开发者模式（按提示重启）。如提示未受信任的开发者，在 设置 › 通用 › VPN与设备管理 里信任该开发者。

**C. 从源码构建**

见 [Quick Start](#quick-start)；真机构建用 `DeviceTrial` scheme 并在本地提供签名与公开配置（见[配置参考](#配置参考)）。

**确认版本**

装好后打开 App 的 设置 › 关于，应显示「版本 X.Y.Z (build N) · 发布于 日期 时间」，和 Release 页面、[CHANGELOG](CHANGELOG.md) 里的版本一致。轻点这一行可以看到提交号。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 使用

> **操作指南（How-to）**：典型对话与期望表现。离线评审模式对应 `run-simulator-review.sh` 的参数，可在无网络时复现界面。

| 场景 | 示例对话 | 期望表现 | 离线评审模式 |
|---|---|---|---|
| 基础对话 | “帮我想想周末怎么安排” | 流式回答，可停止与恢复 | `input` |
| 生成计划 | “把下周的读书计划拆成每天的任务” | 出现任务计划卡片，可逐项确认 | `plan` |
| 报告与编辑 | “整理一份竞品对比报告” → “第二节写短一点” | 生成成果，进入阅读 / 编辑 | `report` |
| 审批动作 | “周五下午 3 点提醒我交材料” | 弹出审批卡片；确认后写入系统日历 / 提醒事项 | `approval` |
| 任务控制 | “先暂停刚才那个任务” | 任务状态切换（暂停 / 取消） | `control` |
| 交互组件 | “帮我在这三个方案里选一个” | 回答内嵌选择 / 表单等结构化组件 | `calculator`（Generative UI 场景） |
| 附近与路程 | “附近有什么咖啡店，走过去要多久” | 请求定位后给出 3–5 个地点与 ETA | — |
| 看图 | 拍一张照片问“这是什么” | 图片经视觉路由链理解后回答 | — |

```sh
# 需要先按脚本说明构建好对应的模拟器包；脚本不会登录或调用模型
zsh apps/ios-conversation/Scripts/run-simulator-review.sh plan
```

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 演示

> App 实拍 GIF 与 3–5 分钟演示视频正在录制，完成后放在这里。

- 录屏分镜与讲稿：[docs/demo-script.md](docs/demo-script.md)
- 主动助理三个演示场景：会前主动提醒 +「为什么找你」、创建提醒 + 撤销、账号停放与恢复（详见分镜）。

<details>
<summary><b>场景配图（设计示意）</b></summary>

<img src="docs/assets/slides/slide-05.png" alt="决策流水线与会议出发助理" width="720">
<img src="docs/assets/slides/slide-07.png" alt="账号停放与恢复" width="720">

<sub>设计示意；虚线框为录屏贴片位，不是实拍画面。</sub>

</details>

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 架构

> **原理（Explanation）**：更完整的分层说明见 [docs/architecture.md](docs/architecture.md)。

```mermaid
flowchart LR
  subgraph iOS["iOS App · apps/ios-conversation"]
    UI["Views<br/>对话 · 卡片 · 侧栏 · 设置"]
    SVC["Services<br/>Session · TaskAction · Proactive"]
    DOM["Domain<br/>typed contracts"]
    PERSIST["Persistence<br/>SwiftData"]
    PROV["Providers<br/>SSE · OAuth · DeviceTools"]
    UI --> SVC --> DOM
    SVC --> PERSIST
    SVC --> PROV
  end
  subgraph OS["iOS 系统"]
    EK["EventKit"]
    CN["Contacts"]
    MK["MapKit"]
    SP["Speech"]
  end
  subgraph Edge["Supabase Edge · services/edge"]
    API["catpaw-api"]
    PRO["catpaw-proactive"]
    CORE["_shared/core<br/>context-window · live-text · approval"]
    API --> CORE
    PRO --> CORE
  end
  PG[("PostgreSQL")]
  LLM["免费模型路由链"]
  VIS["视觉路由链"]
  PROV -->|"HTTPS / SSE"| API
  PROV --> EK
  PROV --> CN
  PROV --> MK
  PROV --> SP
  CORE --> PG
  CORE --> LLM
  CORE --> VIS
```

**关键时序 1：设备动作经审批后执行**

```mermaid
sequenceDiagram
  actor U as 用户
  participant App as iOS App
  participant API as catpaw-api
  participant EK as EventKit
  App->>API: 发送消息
  API-->>App: 待审批动作（如写日历）
  App->>U: 展示审批卡片
  U->>App: 确认
  App->>API: 提交决定（带版本校验）
  API-->>App: 授权执行
  App->>EK: 请求权限并写入
  EK-->>App: 事件标识
  App->>API: 回报结果（成功 / unknown）
  Note over App,API: 结果未知时按原决定核对，不重复执行
```

**关键时序 2：实时逐字预览（live text）**

```mermaid
sequenceDiagram
  participant App as iOS App
  participant API as catpaw-api
  participant DB as PostgreSQL
  App->>API: POST 消息（X-cat-Live-Text: 1）
  API-->>App: 每步第一个 delta 立即发出
  loop 约每 100 ms
    API-->>App: text_preview（未落库尾部，不入库）
  end
  API->>DB: TextBatcher 落库（512 字符 / 250 ms）
  API-->>App: 持久化事件（总是先于后续 preview）
  Note over App: 断线重连按最后持久化 sequence 续传
```

**核心原则**

1. **授权在后端**：展示层和流结束都不能授予权限或宣告完成。
2. **人在回路**：外部副作用先审批，再在设备上执行。
3. **账号隔离**：App 与云端数据随账号停放 / 恢复；只有系统里的外部副作用（如 EventKit 提醒）由用户决定保留或删除。
4. **证据分层**：fixture、合成、真实模型、云端四层结果严格区分。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 目录结构

```text
cat/
├── apps/
│   ├── ios-conversation/        # ★ 当前唯一维护的 iOS App（cat.xcodeproj）
│   │   ├── Sources/             #   App · Domain · Features · Persistence · Providers · Voice · DesignSystem · Shared
│   │   ├── Tests/               #   XCTest / UITest 与可移植 runner
│   │   ├── Scripts/             #   可移植测试、源码检查、版本、模拟器评审脚本
│   │   ├── Configuration/       #   xcconfig（含 Version.xcconfig）、Info.plist、entitlements
│   │   ├── Resources/           #   资源与 UIStrings 本地化
│   │   └── Widgets/             #   Widget / Live Activity
│   ├── ios/                     # 冻结的 v1（只读历史）
│   └── ios-openmuse-demo/       # 冻结的 r3（只读历史）
├── packages/
│   ├── ios-navigation/          # 侧栏导航本地 Swift package
│   └── ios-image-composer/      # 图片输入本地 Swift package
├── services/
│   ├── edge/                    # ★ 后端维护源
│   │   ├── supabase/functions/  #   catpaw-api · catpaw-proactive · _shared
│   │   ├── supabase/migrations/ #   数据库迁移
│   │   ├── docs/                #   接口契约与部署清单
│   │   └── test/                #   Edge 离线测试
│   ├── facade/                  # 冻结的 native contract v1
│   └── offline/                 # 离线服务来源
├── scripts/                     # 仓库检查、敏感扫描、Edge 离线测试
├── docs/                        # 文档（索引见 docs/README.md）
├── qa/                          # 独立 QA 报告
├── design/ · research/          # 设计与研究输入
├── vendor/openmuse/             # 固定版本上游（MIT）
├── CHANGELOG.md                 # iOS 版本记录（Keep a Changelog + SemVer）
├── AGENTS.md                    # 人机共读的仓库约定
└── handoff.md                   # 接手说明
```

目录角色以 [`docs/development/repository-layout.json`](docs/development/repository-layout.json) 为准。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 配置参考

> **参考（Reference）**：仓库不含任何凭据或生产配置；这里只列名称与用途。

<details>
<summary><b>Edge 环境变量（services/edge/supabase/functions/_shared/config.mjs）</b></summary>

| 名称 | 类型 | 用途 |
|---|---|---|
| `SUPABASE_URL` | 配置（必需） | Supabase 项目地址 |
| `CATPAW_PUBLISHABLE_KEY` | 配置（必需） | Supabase publishable key |
| `CATPAW_DATABASE_URL` | Secret（必需） | PostgreSQL 连接 |
| `CATPAW_PRIVATE_MODEL_KEY` | Secret（必需） | 模型路由访问密钥 |
| `CATPAW_TICK_HMAC_KEY` | Secret（必需） | 后台 tick 请求签名 |
| `CATPAW_MEMORY_GUARD_KEY` | Secret（必需） | 记忆数据保护 |
| `CATPAW_GEMINI_API_KEY` / `CATPAW_GROQ_API_KEY` | 可选 | 免费模型路由链的提供方密钥 |
| `CATPAW_MODEL_ROUTE_ORDER` | 可选 | 路由链顺序 |
| `CATPAW_VISION_ROUTE` | 可选 | `chain`（默认，有 Gemini 密钥时）或 `legacy` |
| `CATPAW_SSE_TEXT_INTERVAL_MS` | 可选 | live text 间隔，默认 100，限制在 80–120 |
| `CATPAW_PUBLIC_SOURCE_POLICY` | 可选 | 公开网页读取的来源策略 JSON |

完整列表见 `config.mjs` 与 [部署清单](services/edge/docs/deploy-checklist.md)；路由契约见 [model-routes-contract](services/edge/docs/model-routes-contract.md) 与 [vision-route-chain](services/edge/docs/vision-route-chain.md)。

</details>

<details>
<summary><b>iOS 配置（DeviceTrial.Info.plist / xcconfig）</b></summary>

| 键 | 用途 |
|---|---|
| `CatpawSupabaseProjectURL` | Supabase 项目地址 |
| `CatpawSupabasePublishableKey` | Supabase publishable key |
| `CatpawBackendOrigin` | 后端 API origin |
| `CatpawServerScopeID` | 服务端作用域标识 |
| `DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER` | 签名与包名，本地提供 |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `Configuration/Version.xcconfig`；`MARKETING_VERSION` 只用 `Scripts/bump-version.sh major\|minor\|patch` 修改，真实构建号由「Stamp Build Info」阶段（`Scripts/app-version.py stamp`）按 git 提交数写入 |

权限：相机、麦克风、相册、语音识别、日历、提醒事项、通讯录、定位（使用期间）。

</details>

<details>
<summary><b>脚本环境变量</b></summary>

| 名称 | 用途 |
|---|---|
| `CATPAW_DENO_BIN` | Edge 离线测试使用的 Deno 路径 |
| `CATPAW_PUBLIC_NPM_CACHE` | 已有的公开依赖缓存目录 |
| `CATPAW_REVIEW_DEVICE` | 模拟器评审脚本的目标设备 |

</details>

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 开发与测试

```sh
# 仓库完整性与敏感扫描（提交前必跑）
python3 scripts/check-repository-layout.py
python3 scripts/check-repository.py
python3 scripts/scan-repository.py

# iOS：可移植测试（macOS swiftc，无需模拟器）、源码与本地化检查
zsh apps/ios-conversation/Scripts/test-conversation-portable.sh
zsh apps/ios-conversation/Scripts/check-source.sh
python3 apps/ios-conversation/Scripts/check-localization.py

# iOS：XCTest / UITest
xcodebuild test -project apps/ios-conversation/cat.xcodeproj -scheme cat \
  -destination 'platform=iOS Simulator,name=<你的模拟器>'

# Edge：离线测试（禁网络，只读已有依赖缓存）
CATPAW_DENO_BIN=<Deno路径> CATPAW_PUBLIC_NPM_CACHE=<公开cache目录> sh scripts/test-edge-offline.sh
```

- 分支：不在 `main` 直接开发，按 [分支规范](docs/development/branch-management.md) 用短分支；`.githooks` 提供本地守卫。
- 部署：Edge 函数与数据库迁移只在用户明确批准后部署，步骤见 [部署清单](services/edge/docs/deploy-checklist.md)。
- CI：GitHub Actions 当前因额度用尽暂停，PR 需附本地编译与测试记录。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## Roadmap 与已知限制

- [x] **v1.1.0 发版**：已通过 #98 合入 `main`（OAuth 登录与账号下拉、iOS live text、语音对话、记忆工具调用、版本管理等）
- [x] 版本号自动化：构建号自动递增，设置 › 关于显示发布时间与提交号
- [x] [CHANGELOG](CHANGELOG.md) 记录 1.1.0 发布日期（2026-10-18）
- [ ] 打 `v1.1.0` 标签，发布首个 GitHub Release（模拟器 zip + 开发签名 ipa），见[下载与安装](#下载与安装)
- [ ] 1.1.1 修复版：标题溢出、时间格式（见 [CHANGELOG](CHANGELOG.md)）
- [ ] App 实拍录屏 / GIF 与演示视频
- [ ] v1.2：EventKit CI 测试、Release / ipa 自动分发
- [ ] 云电脑托管：仅为[提案](docs/architecture/cloud-computer-proposal.md)

**已知限制**

- 无配置时只能跑离线合成路径，不产生真实回答。
- 主动提醒：后端兜底规则还不读取「提前 N 分钟」偏好，会前 10–25 分钟的提醒可能不出现；修复（`catpaw-proactive` v10）在评审中，部署需用户批准。
- 记忆：「自动记住新内容」关闭时，明确说「记住」也可能没有保存；修复（`catpaw-api` v54）在开发中。
- live text：重连到另一实例时退回普通批量推送；未落库尾部超过 4000 字符时暂停预览。
- 私有仓库计划下 GitHub 分支保护未生效。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 文档地图（Diátaxis）

| 类型 | 适合 | 入口 |
|---|---|---|
| Tutorials 教程 | 第一次跑起来 | [Quick Start](#quick-start)、[接手说明](handoff.md)、[iOS 工程说明](apps/ios-conversation/README.md) |
| How-to 操作指南 | 完成具体任务 | [下载与安装](#下载与安装)、[使用](#使用)、[录屏分镜](docs/demo-script.md)、[Edge 离线验证](services/edge/README.md)、[部署清单](services/edge/docs/deploy-checklist.md)、[贡献指南](CONTRIBUTING.md) |
| Reference 参考 | 查准确信息 | [配置参考](#配置参考)、[CHANGELOG](CHANGELOG.md)、[iOS 版本规范](docs/development/ios-versioning.md)、[Edge 接口契约](services/edge/docs/)、[目录角色](docs/development/repository-layout.json) |
| Explanation 原理 | 理解为什么 | [架构总览](docs/architecture.md)、[架构索引](docs/architecture/README.md)、[研究索引](docs/research/README.md) |

完整索引见 [docs/README.md](docs/README.md)。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## Contributing

见 [CONTRIBUTING.md](CONTRIBUTING.md)：分支规范、提交前检查、敏感信息规则；PR 请使用 [PR 模板](.github/pull_request_template.md)，问题请用 [Issue 模板](.github/ISSUE_TEMPLATE/)。

## License

开源协议待定，仓库根目录暂无 LICENSE 文件。第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；`vendor/openmuse` 保留上游 MIT 原文。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>

## 给 AI 助手的上下文

- **技术栈**：Swift 5 / SwiftUI（部署目标 iOS 17，Xcode 26 编译）、SwiftData（CloudKit 关闭）、URLSession SSE、EventKit / Contacts / MapKit / Speech；后端 Supabase Edge Functions（Deno，`.ts`/`.mjs`）+ PostgreSQL。
- **维护入口**：iOS 只改 `apps/ios-conversation`；后端只改 `services/edge/supabase/functions`。`apps/ios`、`apps/ios-openmuse-demo`、`services/facade`、`services/edge/deployed-baselines`、`vendor` 为冻结快照。
- **分层**：`Views → *Service → Domain contracts`；`Providers` 封装网络、认证、系统框架；`Persistence` 封装 SwiftData。UI 不直接持有账号或执行副作用。
- **核心领域模型**：Conversation / Turn、TaskPlan、TaskAction（审批）、DeviceEffect / DeviceCall、Artifact、Inbox、Memory、GenerativeUI、ProactiveSuggestion。
- **约定**：结果未知标 unknown 并按原决定核对；合成结果不得冒充真实验收；不新增依赖或凭据；部署需用户批准；进度只写 [主计划](docs/status/master-plan.md)。
- 完整规则见 [AGENTS.md](AGENTS.md)。

<p align="right">(<a href="#readme-top">返回顶部</a>)</p>
