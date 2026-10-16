# Catpaw-m 产品评估（2026-10-16，分支 feat/peripheral-polish）

> 范围：iOS `apps/ios-conversation`，服务端 `services/edge`。行号以本分支为准（基线是 origin/feat/chat-ux-p0 @4270393，加上本地 cherry-pick 的 PR #91）。
> 状态标记：✅ 已有且可用｜🔧 本分支补强｜⚠️ 未验证（需要在 Mac 或真机上验证）｜❌ 缺失。

## 1. 产品判断：怎么理解「主动」

**现状**
- 主动 = 在**有把握的时刻**、用**最轻的打扰方式**提供**能直接执行**的帮助，而不是频繁推送。具体由三层组成：
  1. **信号**：日历临近会议，并做时间窗过滤。见 `ProactiveRules.admit` 去重（`Sources/Features/Proactive/ProactiveRules.swift:22`），以及服务端 `signal_hash` 时间窗。
  2. **决策**：服务端把介入程度分为 `silent → card → notify → interrupt` 四档（`services/edge/supabase/functions/_shared/proactive/decision.mjs:9`）。最终置信度 = 模型置信度 × 该类触发的学习权重；低于阈值就降档（`decision.mjs:99-101`）。最低降到 card，不会直接打断用户。
  3. **反馈闭环**：`有帮助 / 没帮上 / 打扰到我` 会改变该类触发的权重和阈值（`decision.mjs:119-132`）。客户端用 `ProactiveFeedbackLedger` 按同样的算法在本机持久化（`ProactiveRules.swift:70`，PR #91）。
- 价值落点：每张建议卡都附带可执行动作（建提醒、告诉参会人），并给出「为什么找你」：信号、用到的记忆、做过的动作，都可以撤销（`ProactiveWhySheet.swift`）。

**问题**
- 本机决策 `evaluateLocal`（`ProactiveEngine.swift:286`）还没有接入反馈台账，所以负面反馈目前只通过服务端生效。这部分代码归方块。
- 本地建议没有 trigger 字段，反馈统一记在 `meeting_upcoming` 下。
- 触发源单一（只有日历）；位置、出行、邮件类信号还停留在模拟阶段（`ProactiveSignalDebugView`）。

**改进**
- 🔧 PR #91：反馈按账号持久化，重启后还在；没同步到服务端的显示「待同步」，不会假装已经记下。
- 建议：
  - `evaluateLocal` 调用 `ProactiveFeedbackSync.shared.gate(...)`；
  - 把「打扰预算」做成显式指标，例如每天 notify 档最多 N 次，夜间只出 card；
  - 用 A/B 比较「接受率 / 打扰率」，而不是只看触达量。

**面试讲法**：「主动」的难点不在于能不能推送，而在于什么时候值得打扰。我们把打扰程度做成可降级的四档，用置信度和每类触发的学习权重来决定落在哪一档，并让用户的反馈可以被量化地回写。

## 2. 架构设计：触发、记忆、能力、交互四块

| 模块 | 边界 | 关键位置 |
|---|---|---|
| 触发 | 信号 → 规则（portable，纯函数）→ 引擎（EventKit/BG/通知） | `ProactiveRules.swift`（可单测）、`ProactiveEngine.swift`、服务端 `proactive/decision.mjs`、`proactive/service.mjs`（`/scheduler/tick`） |
| 记忆 | `MemoryLibraryBackend` 协议，背后有云端（agent-memory.v1）和本机两种实现；只有一个「使用记忆」开关 | `MemoryLibrary.swift:78` `MemoryRecallGate`、`MemoryLibraryLocal.swift:142/165` |
| 能力 | `catpaw.device.v1`：服务端只声明工具，手机执行；结果用 args_hash 绑定，带 TTL，并且幂等 | `core/src/device-call.mjs`、`DeviceToolContract.swift`、`DeviceToolRouter.swift`、`DeviceCall.swift` |
| 交互 | 一律走 approval 中断：确认卡 → 回执 → 撤销；用 `catpaw-card` 围栏承载生成式 UI | `DeviceCallConfirmCard.swift`、`core/src/approval.mjs`、`GenerativeBlock*` |

**优点**
- 能力层的扩展点清晰。新增一个设备工具只需要：
  1. 在 `DEVICE_TOOLS` 里加一行；
  2. 在客户端 `clientTools` 和 router 里加一个 case；
  3. 合同测试（`test/device-tool-client-contract.test.mjs`）自动校验枚举、状态值和客户端声明的工具是否一致。
- 服务端只提供客户端声明过的工具（`X-Catpaw-Device-Tools`），旧版客户端会被降级处理，而不是让调用失败。
- 规则层做成 portable 纯函数，可以在没有模拟器的情况下单测（`Scripts/test-nobug-p0.sh`）。

**问题**
- `ProactiveEngine.swift` 接近 1000 行，混合了信号扫描、决策、提醒写入、通知和 BG 任务，所有权交叉（决策和去重归方块，撤销和反馈归我们）。
- 记忆有两套实现（ConversationMemoryService 和 MemoryLibrary）。

**建议**：把 `ProactiveEngine` 拆成 `SignalSource / Decider / Effector / Notifier` 四个类型，与上表四块一一对应。

## 3. 移动端工程：后台、权限、系统入口

| 项 | 状态 | 位置 / 说明 |
|---|---|---|
| SSE 断开与恢复 | ✅ | 进入后台时主动断开 SSE（`ConversationFirstModel.swift:923` `beginSuspension`），但服务端的 turn 继续跑；回到前台后用 `GET …/events?after_sequence=N` 重新接上（`NativeChatHTTPBackend.swift:380`），并循环读取未完成的 turn。 |
| 后台宽限 | 🔧 ⚠️ | 新增 `CatpawBackgroundGrace`（`ConversationFirstModel.swift:969`），保证草稿和 UI 状态的 flush 以及 stopObserving 在挂起前完成。 |
| BGTaskScheduler | ✅ 🔧 | `com.yankj.catpawm.proactive.refresh` 在 Info.plist 里登记过（`ProactiveEngine.swift:670`）。本分支补了 `expirationHandler`，并在任务一开始就预约下一次，避免超时被系统强杀后整条刷新链断掉。 |
| 未完成任务恢复 | ✅ | 设备调用中途被杀：幂等工具按 call_id 去重后重跑，非幂等工具报告 `interrupted_outcome_unknown`（`DeviceCall.swift:172`）；待上报的结果和撤销会持久化，下次启动或回前台时补发。 |
| 本地通知 / 类别 | ✅ | `CATPAW_REMINDER` 和任务类别带「完成 / 10 分钟 / 1 小时」按钮（`CatpawPushNotifications.swift` 的 `CatpawPushAction.categories`），主动建议有自己的类别。 |
| APNs | ⚠️ | 已注册 device token 并上传（`PUT /devices/tokens`），entitlement 是 `aps-environment=development`。服务端 `apns.mjs` 有实现，但需要 APNs key 和生产 entitlement。 |
| 点击通知的深链接 | ✅ 🔧 | 带会话的推送 → `catpawm://conversation/<id>`。本分支补了：没有会话的主动推送 → 打开主动建议收件箱（之前点了没有反应）。 |
| catpaw-tick | ⚠️ | 代码通路是通的：catpaw-api 的 `runtime.tick`（HMAC + nonce，`_shared/api.mjs:415`）和 catpaw-proactive 的 `/scheduler/tick`（`proactive/service.mjs:125`），都有单测（`test/minimum.test.mjs`）。但 pg_cron 迁移标注了「NOT APPLIED automatically」，生产上有没有定时调用方没有验证（本次不碰生产库）。 |
| 小组件 | 🔧 ⚠️ | Widget target 已存在并嵌入 App（`Widgets/CatpawWidgets`），数据通过 App Group 下的 `catpaw.widget.snapshot.v1.json` 共享（`ProactiveEngine.swift:818`）。**之前 App 和 Widget 都没有 App Group entitlement，所以小组件永远是空的。** 本分支给两边都加上了（`Configuration/CatpawM.entitlements`、新文件 `Configuration/CatpawWidgets.entitlements`、pbxproj 中 widget 的 3 个配置）。需要在开发者后台注册 `group.com.yankj.catpawm`。 |
| Live Activity / 灵动岛 | ✅ ⚠️ | `NSSupportsLiveActivities` 已开启，`CatpawLiveActivityCoordinator`（`App/CatpawLiveActivityCoordinator.swift:32`）支持 push token 和 push-to-start，Widget 里有 `CatpawWorkLiveActivity.swift`。远程更新依赖 APNs。 |
| 长按图标快捷操作 | 🔧 ⚠️ | 新增 `UIApplicationShortcutItems`（新对话 / 主动提醒 / 记忆），通过 `CatpawSceneDelegate`（`CatpawPushNotifications.swift:153`）分发到 `CatpawAppRoute(quickActionType:)`，冷启动和热启动都覆盖。 |
| App Shortcuts / Siri | ✅ 🔧 | 原来只有一个「打开」的 intent，打开后不做任何路由。新增 `NewCatpawConversationIntent`（`CatpawApp.swift:260`），直接进入新对话，不会自动发送消息。 |
| 权限 | ✅ 🔧 | 按需申请（`PermissionCard` 说明用途），不在启动时弹窗。本分支在「设置」里新增「小猫能看到什么」（`PermissionCard.swift:177`），集中展示各项权限状态和用途，并可以跳转到系统设置。 |

## 4. 可信与安全

- **风险分级**：
  - 服务端：工具按 `approval: always | per_class` 和 `risk: device_write | external_write …` 声明，未声明的工具默认按最高风险处理（`core/src/tools.mjs:44-55`）。
  - 客户端（🔧）：`DeviceRiskTier` 分为 read / undoable / handoff / outbound 四级（`DeviceToolContract.swift:91`），确认卡上用一行文字告诉用户「会写入，可以撤销」「会打开其他 App」「会联系他人，系统界面还会再确认一次」。
- **用户确认**：
  - 除只读工具外，所有工具都要在确认卡上点击确认；联系人查询即使服务端标为 `confirm:none` 也必须点击（`tapRequiredTools`）。
  - 发短信、邮件、打电话都要在系统界面里再确认一次，不会静默发送。
- **解释「为什么」（🔧）**：服务端给所有需要确认卡的工具加了可选参数 `why`（`core/src/device-call.mjs` 的 `WHY`），确认卡顶部显示「为什么：…」；主动建议有完整的「为什么找你」页面。
- **隐私划分**：
  - 本机记忆按账号或访客隔离，用 AES-GCM 存在 L2SecureStore 里；只能迁移给原来的账号；登出时清除记忆、主动建议、待上报数据、通知和小组件（PR #91，`MemoryLibraryLocal.swift:142/165`）。
  - 「使用记忆」只要有一处关闭，所有读取路径都引用 0 条记忆（`MemoryRecallGate`，`MemoryLibrary.swift:78`）。
  - 联系人只返回最少字段：姓名和最多 3 个电话，邮箱只在明确要求时返回（`minimalContact`）。
- **幂等**：
  - 设备结果绑定 `operation_id + args_hash`，带 TTL；
  - 写入日历和提醒前，先用 notes 里的 call_id 标记查重（`DeviceToolRouter.swift`、`DeviceCall.swift:172`）；
  - 主动建议的动作带 `operation_id`。
- **可撤销**：
  - 日历、提醒、闹钟可以从回执里撤销，撤销结果分为 undone / already_gone / failed 并上报给模型（`deviceUndoNote`）；
  - 主动建议的撤销在删除失败时保留原状态（PR #91，`ProactiveEngine.swift:439`）。
- **不夸大结果**：打开外部 URL 超时返回 `handoff_unknown`，回执显示「已请求打开，结果未知」；服务端也要求模型对这类工具只能说「已请求打开」（🔧）。

**仍有的问题**：「设置」里还没有整体的「操作历史」入口（`DeviceLedgerSection` 已经存在，可以挂上去）；`why` 由模型生成，不可信，只作展示，并且限制在 80 个字符以内。

## 5. 实现质量

- **优点**：
  - 合同测试横跨客户端和服务端（edge 测试会读取 Swift 源码校验枚举）；
  - portable 测试覆盖持久化、迁移、幂等和撤销；
  - 失败不会被包装成成功：本机记忆写入失败会抛错、撤销失败会保留原状态、超时就是「结果未知」。
- **问题**：
  - 一些 UI 和引擎文件过大，代码密度高（`ConversationFirstModel.swift`、`ProactiveEngine.swift`），单行承载了很多逻辑，评审成本高；
  - 历史上有 `try?` 吞掉错误的写法（PR #91 修了撤销和反馈两处）；
  - 有一部分 edge 测试被隔离，依赖 jose/postgres 的真实库（issue #81，#83 修了 7/8）；
  - `generative-ui-demo-recording` 在基线上就是失败的。
- **本分支的测试**：
  - edge：设备相关 18/18；全量 602/610，失败的 8 个都是基线上已经失败或已被隔离的用例。
  - Swift：box 上没有工具链，新增的 portable 测试（`peripheralPolish()`）需要在 Mac 上运行 `Scripts/test-nobug-p0.sh`。

## 6. 走通的演示路径

| 路径 | 端到端 | 证据 |
|---|---|---|
| 对话 → 创建日历 → 回执「打开」(calshow) → 撤销 | ✅（v45 冒烟测试实测 calendar_create device_call 成功） | `DeviceToolRouter.swift` 中的 calendar_create，撤销走 `deviceUndo` 测试 |
| 对话 → 地图导航（地名或坐标、出行方式） | 🔧 ⚠️ 之前会忽略 lat/lng | `DeviceToolContract.mapsURL` 加 portable 测试 |
| 对话 → 运行快捷指令（记一笔等，可以带文本输入） | 🔧 ⚠️ | `DeviceToolContract.shortcutURL` 加测试；回执显示「已请求打开」 |
| 对话 → 提醒事项 | ✅ | reminder_create 用 call_id 去重，可以撤销 |
| 对话 → 购物 App 搜索或直接打开 https 链接 | 🔧 | 之前会忽略 `url` 参数；现在只接受 https |
| 记事本（备忘录） | ❌ | 苹果没有公开 API；可以用「快捷指令」路径替代 |

## 7. 需要在 Mac 上验证的步骤

1. `Scripts/test-nobug-p0.sh`：全部 PASS，包括新增的 `peripheralPolish`、P0-2 和 P0-4 测试。
2. 用 `xcodebuild build-for-testing` 编译（本分支的 Swift 改动没有在 box 上编译过）。
3. App Group：
   - 在开发者后台注册 `group.com.yankj.catpawm`，并加到 App 和 Widget 两个 App ID 上；
   - 真机触发一条主动建议后，确认桌面小组件显示内容。
4. 长按图标：
   - 「新对话」冷启动和热启动都能进入新对话；
   - 「主动提醒」打开收件箱；「记忆」打开记忆页。
5. Siri / Spotlight：「New conversation in Catpaw-m」能进入新对话。
6. 后台：
   - 发出一条长回复后立刻切到后台再回来，回复应能从断点继续，而不是重发；
   - 在 Xcode 用 `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.yankj.catpawm.proactive.refresh"]` 模拟后台刷新，日志里应出现 `BGAppRefresh fired`。
7. 确认卡：服务端部署 `why` 之后（本次不部署），卡片显示「为什么：…」和风险说明；旧服务端不传 `why` 时卡片不显示这一行。
