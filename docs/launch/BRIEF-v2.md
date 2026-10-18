# Catpaw v1.1 演示内容大纲 v2（deck ＋ 视频的共同背景）

2026-10-18 08:40（UTC+8），待用户确认。v1 保留在 BRIEF.md。重点是逻辑和内容，不讲视觉细节。
标签：**✅ 已交付**（v1.1 包或生产 v53 已有）·**◐ 部分**（有代码，但有前提或限制）·**🔜 v1.2**（只是计划，不当作已有功能讲）。证据编号 [E#] 见文末附录。

## 0. 理念与定位
- **用户原话**：贴心助理：不用自己记、不用自己提醒；安全、简单。
- **一句话定位**：**Catpaw，先你一步，把事办妥。**一个住在 iPhone 里的贴心助理，替你记着、替你盯着，到点主动提醒，你点一下就办好。
- 支撑语：
  1. **不用自己记，也不用自己提醒**：看日历、记偏好，到时候主动来提醒你。
  2. **把交代的事，变成可用成果**：结果写进系统日历和提醒，不只是给你建议。
  3. **从容，清楚，可靠**：进度看得见；动手前先问你；它看到什么、记住什么，都由你决定。
- **同类产品对照**（各一行：借鉴什么 / 有什么不同）：
  - ChatGPT Pulse（[OpenAI](https://openai.com/index/introducing-chatgpt-pulse/)）：定位是 "ChatGPT can start the conversation"，每天早上推送卡片简报。借鉴它的主动卡片和「为什么给你看」；不同在于 Catpaw 按具体时刻触发，并且直接在手机上把事做完，不只是给一份简报。
  - Google Gemini / Gemini Live（[Live](https://gemini.google/overview/gemini-live/)、[Tasks](https://support.google.com/gemini/answer/17094507?co=GENIE.Platform%3DiOS&hl=en)）：语音优先，跨 Google 应用执行，支持定时和事件触发的任务。借鉴「任务＋触发条件」的思路；不同在于 Catpaw 是 iOS 原生，执行前必须确认，没有 Google 生态。
  - Apple Siri AI / Apple Intelligence（[Apple](https://www.apple.com/apple-intelligence/)）：主打「个人上下文、在 App 里执行、隐私」。借鉴它和系统深度结合（EventKit、实时活动、App Intents）；不同在于 Catpaw 会主动来找你，而且有可以查看、可以删除的记忆。
  - Samsung Galaxy AI Now Brief（[Samsung](https://www.samsung.com/sg/support/mobile-devices/how-to-set-up-and-use-now-brief-on-your-samsung-galaxy-device/)）：按时间、地点、日程生成锁屏卡片，强调「只在适当时间出现」。借鉴锁屏入口和少打扰；不同在于 Catpaw 在一个对话里能接着办，不只是展示信息。

## 1. 作业四项要求：做了什么，亮点是什么
### 主动
- ✅ **端上主动引擎**：读取日历里的下一个事件、后台刷新等信号 → 规则预筛 → 去重台账 → 评估（服务端评估，离线时用本地规则）→ 卡片和可操作的本地通知 → 用户确认 → 写入提醒，重复执行也只写一次 [E1]。
- ✅ **打扰有分寸**：分四级（silent / card / notify / interrupt），有免打扰时段（推迟后合并发送）和每人每日推送上限 [E2]。卡片有「为什么推荐」和撤销 [E1]。
- ✅ **服务端定时任务**：pg_cron 每分钟跑一次 → Vault 取密钥 → /scheduler/tick → 主动任务表（`proactive.*`，含 `proactive.touch` 触发器）[E3]。
- ◐ 位置：只用在「附近」查询和出发提醒，只请求「使用期间」权限，不做后台持续定位 [E4]。**消息类信号没有实现**。**服务端推送（APNs）没配置**，到点提醒靠本地通知。

### 有记忆
- ✅ **长期记忆**：存在 `agent_memory.memories`，分 profile / preference / person / fact 几类。模型只能记稳定的偏好和事实，明确禁止记密钥、健康和财务标识 [E5]。
- ✅ **记忆真的被用上**：记忆里写了「提前 N 分钟」，主动提醒的提前量就会改，并在卡片上注明出处 [E1]。每轮对话会带上置顶记忆和最相关的 6 条，并标注为「不可信数据」[E6]。
- ✅ **你说了算**：设置里有总开关、更正和「忘记」。「忘记」会删除主记忆和派生索引，并阻止它从旧来源再学回来 [E7]。功能先按白名单逐步开放 [E5]。
- ✅ **对话上下文**：服务端保存权威历史，按最近 40 条或 80 kB 的窗口发给模型；被取消的那一轮下一轮也知道 [E8]。
- 🔜 滚动摘要、向量检索。现在的检索按关键词匹配，没有接 embedding。

### 能执行
- ✅ **写进系统日历和提醒（EventKit）**：先出确认卡，系统写入成功后给回执卡；没有权限时自动降级并引导 [E9]。
- ✅ **实时活动**：锁屏和灵动岛上显示进度，另有「该出发了」实时活动；主屏有小组件 [E10]。
- ✅ **Siri 和快捷指令入口**：App Intents（`OpenCatpawConversationIntent`、`CatpawAppShortcuts`）[E11]。
- ✅ **服务端工具**：委托任务、读取用户给的公开网页链接、生成有引用的报告、向用户追问、提议记忆 [E12]。
- 🔜 生图、按任务选模型、Gmail 连接器。

### 可信
- ✅ **动手前必确认**：确认卡上点了确认才执行，以系统回执为准，结果不确定时显示「未确认」[E9][E13]。
- ✅ **账号级同意**：同意后才把图片发给模型，同意和模型路由绑定，路由一变就失效 [E14]。
- ✅ **状态如实**：状态显示在消息里，不用浮层；状态行只显示真实发生的步骤 [E13]。
- ✅ **能解释**：主动卡片有「为什么推荐」，还能撤销 [E1]。

## 2. 交互与功能亮点
- ✅ **进度到处看得见**：对话里有状态行，锁屏和灵动岛上有实时活动（只能由 App 内对话触发）[E10][E13]。
- ◐ **语音**：✅ 听写（按住说话，或点按进入全屏听写）。◐ 完整语音对话「说→回→读」已进包，**真机还在修，不演示** [E15]。
- ✅ **毛绒小猫陪你**：6 个状态（等待、思考、写作、执行、完成、出错）和对话状态一一对应 [E16]。5 段小猫动画 .mov 和弹出动画（CatpawMascotPopHold）在 v1.1 集成分支上 [E17]。
- ✅ **边生成边看**：实时文字（text_preview）、状态行、等待时的光效 [E18]。
- ✅ **及时确认**：需要你决定时，就在消息里弹出卡片，不跳页。
- ✅ **生成式 UI**：模型按协议输出表单卡片，支持文本、数字、开关、选择、步进器、日期时间这些控件，由 App 渲染、校验并保存状态 [E19]。

## 3. 设计（讲为什么）
- **品牌**：logo 是猫耳和猫爪的形状，加一道向前的笔触，意思是「先你一步」。口号「先你一步，把事办妥」，品牌主张「把交代的事，变成可用成果」，调性「从容，清楚，可靠」（user-assets/brand-board.png、splash-dark.png）。
- **配色**：暖橙代表温暖、可托付。规则是 #FF702A 只用在图形上，不用于正文；需要橙色文字时用 #C64A0B，保证对比度；底色 #FFFCF8，正文 #292622，次要灰 #929298。字体用系统字体，为了清楚、跟随系统、支持动态字号 [E20]。
- **视觉和交互一致**：没有浮层，状态就在消息上；全 App 只有一个输入框；小猫状态等于真实状态，不做装饰性动画。
- **方便**：启动页一次淡出，不循环。可以先用体验账号，不用注册，之后再原地绑定 Google，数据不丢 [E21]。

## 4. 记忆、安全与账号
- **账号级同意**：同意按账号记录，对话里用的副本取两者中更严格的那个，撤回立即生效 [E14]。
- **按用户隔离**：每张表开 RLS，条件是 `user_id = auth.uid()` [E22]。
- **密钥只在服务端**：定时任务密钥放在 Vault，模型 key 只在 Edge Function 的 secrets 里，客户端和仓库里都没有。开源扫描查了 888 个提交，没有发现真密钥 [E3][E23]。
- **Edge 鉴权**：每个请求都校验 JWT，并且区分体验账号和正式账号 [E24]。定时入口没有正确密钥就返回 403。
- **体验账号**：使用 Supabase 官方匿名登录；之后可以在原账号上绑定 Google，不换号 [E21]。
- **退出登录**：立即标记为已退出，再撤销服务端会话，最后无论网络成败都清掉 Keychain 里的凭据 [E25]。
- **删除记忆**：见 §1「有记忆」[E7]。
- **图片用完即删**：图片字节只在当前这一轮存在，附件发送后就删除，之后的轮次只保留文字 [E8]。

## 5. 技术设计亮点（4 项）
1. **流式实时文字**：只有请求带 header 才下发，大约 100 ms 一帧。按 UTF-16 偏移合并，以保存的正文为准；坏帧直接丢掉，不会影响整轮 [E18]。
2. **服务端说了算的上下文**：客户端只上传最新一条。40 条的窗口正好对应同意文案，所以不需要重新同意 [E8]。
3. **同意绑定路由，加免费模型故障转移**：生产顺序 OpenRouter → Gemini → Agnes，遇到 429 自动换下一家，看图另有一条备用链 [E26]。
4. **端上主动的流水线**：信号 → 规则 → 去重 → 评估 → 确认 → 写入，每步可重复执行也只生效一次，离线时用本地规则顶上 [E1]。
- 工程上：发布前在 Mac 上跑 release_check.py 和单测，GitHub CI 不作为发布门槛。

## 6. 叙事线
**Deck（约 15 页，附录另放）**
1. 问题：要记的事太多，提醒全靠自己，AI 只会问一句答一句。
2. 理念：贴心助理，加上 §0 的定位和三条支撑语；对照 4 个同类产品。
3. 四项要求各一页：主动、记忆、执行、可信，每页写清「做了什么、亮点、演示截图」。
4. 交互亮点：进度、小猫、实时文字、确认卡、生成式 UI。
5. 设计为什么这样做：品牌、配色、一致性、方便。
6. 安全与账号。
7. 技术亮点 4 项。
8. v1.1 状态和 v1.2 路线，标签要分清。
9. 结束页，用口号收尾。

**视频（80 秒，无配音）**
钩子（启动页口号）→ 痛点（「又忘了」）→ 主动卡片带出处（主动＋记忆）→ 确认 → 写进日历或提醒（执行）→ 锁屏和灵动岛进度（看得见）→ 小猫完成 → 设置里能忘记记忆（可信）→ v1.2 只出文字 → 口号。必须拍到四项要求各一个镜头。开头不能有大片空白：用左字右机，或手机居中两侧加字幕。

## 7. 不要说
- 不说已验收、已发布、全过；不说优于某个竞品。
- 不说服务端推送可用（APNs 没配置；视频里的推送要标「模拟器推送」）。
- 不说语音对话能用；不说读消息、后台定位。
- 不说 Gemini 优先，也不说 OpenRouter 或 Gemini「零留存」。
- v1.2 的内容不当作已上线：生图、按任务选模型、滚动摘要、回声消除、逐句朗读。
- 不报资料里没有的数字，比如启动耗时或用户量。

## 证据附录（路径相对仓库根目录，基线 main 694d19e；`Sources/`、`Resources/`、`Widgets/` 开头的 iOS 路径都在 `apps/ios-conversation/` 下；`functions/`、`migrations/` 开头的边缘函数路径都在 `services/edge/supabase/` 下。`codex-review/…` 是团队内部工作区，不在仓库里，其中与材料有关的已复制到 `docs/launch/assets/`，见 `docs/launch/ASSETS.md`）
- E1 `Sources/Features/Proactive/ProactiveEngine.swift`（文件头注释）、`ProactiveWhySheet.swift`、`ProactiveUndo.swift`、`ProactiveRules.swift`
- E2 `functions/_shared/proactive/throttle.mjs`、`migrations/20261016013000_proactive_push_throttle.sql`
- E3 `migrations/20261015120000_proactive_tasks.sql`（`proactive.touch`）、`20261015120100_proactive_cron.sql`（Vault）
- E4 `Sources/Features/Nearby/NearbyPlaces.swift`、`ProactiveEngine.swift`（requestWhenInUse）
- E5 `functions/_shared/agent-memory/contract.mjs`（MEMORY_KINDS、memory_save）、`service.mjs`（allowlist）
- E6 `agent-memory/service.mjs`；`codex-review/context-memory/PLAN.md` §1.2
- E7 `Sources/Features/ConversationMemoryView.swift`（忘记、更正）、`migrations/20261016100000_agent_memory_tombstones.sql`
- E8 `codex-review/context-memory/PLAN.md` §1、`functions/_shared/core/src/chat-service.mjs`、`_shared/attachments.mjs`
- E9 `Sources/Features/DeviceCalls/*`、`DeviceCards/{PermissionCard,PermissionDegradeCard,ReceiptCard}.swift`、`Sources/Providers/NativeCalendarEffectExecutor.swift`
- E10 `Widgets/CatpawWidgets/CatpawWorkLiveActivity.swift`（含 CatpawLeaveLiveActivity）、`CatpawHomeWidgets.swift`、`Sources/App/CatpawLiveActivityCoordinator.swift`
- E11 `Sources/App/CatpawApp.swift:267-276`
- E12 `functions/_shared/core/src/tools.mjs`
- E13 `codex-review/inline-status/`、`codex-review/demo-deck/REVIEW-v3.md` §1（状态行）
- E14 `functions/_shared/consent.mjs:4-6`、`_shared/image-consent.mjs`、`codex-review/inline-status/C-consent-sheet-v11-*.png`
- E15 `Sources/Features/Composer/ComposerDictation.swift`、`codex-review/voice-audit/REPORT.md`
- E16 `Sources/DesignSystem/CatpawPlushMascot.swift`、`Resources/Assets.xcassets/CatpawBrand/Mascot/`
- E17 `codex-review/pr-triage/required.yaml`、`codex-review/release/mac-logs/integration-5f98d29d/commits.txt`（不在 main 上）
- E18 `functions/_shared/core/src/live-text.mjs`、`services/edge/test/live-text.test.mjs`、`codex-review/live-text/REPORT.md`
- E19 `Sources/Features/GenerativeBlocks/*`、`ConversationGenerativeUIView.swift`
- E20 `docs/brand-theme.md`、`Sources/DesignSystem/CatpawBrandTokens.swift`
- E21 `Sources/Providers/NativeAuthSessionManager.swift:183`、`NativeAuthHTTPRemote.swift:47`、`codex-review/account-menu/REPORT.md`（attach 原地升级）、`codex-review/splash-login/REPORT.md`、`codex-review/launch-v2/SPEC.md`
- E22 `migrations/20261016090000_agent_memory.sql` 等（`auth.uid()`）
- E23 `codex-review/oss-audit/REPORT.md`
- E24 `functions/_shared/authority.mjs:137-153`、`_shared/tick-auth.mjs`
- E25 `Sources/Providers/NativeAuthSessionManager.swift:74-86`
- E26 `functions/_shared/core/src/free-route-chain.mjs`、`vision-route-chain.mjs`、`codex-review/context-memory/PLAN.md` §2.1

## 未能核实
- 服务端滑动窗口是否已在 v53 上线（请三角确认）。
- 小猫 .mov 和语音对话代码不在 main 上，只按集成分支的记录引用。
- 每日上限在生产是否开启；模型选择器的白名单清单。
- logo 寓意（猫耳猫爪加向前笔触）来自 brief 要求，仓库里没找到原文出处。
