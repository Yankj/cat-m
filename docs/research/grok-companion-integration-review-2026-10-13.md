# Grok Cat Companion 分支与当前 Agent 底座的整合核读

日期：2026-10-13。类别：固定源码静态研究和设计建议，不是产品通过记录。范围：用户要求综合 Grok 分支、本地方案与具名竞品，重点检查流式可交互 UI、Human-in-the-loop、记忆和主动性。当前执行定义仍为 [AF-1-G3-UX1](../planning/AF-1/goal.md)；实际进展只见 [master-plan](../status/master-plan.md)。本文不修改 Goal、冻结 v1/v2 HTTP 合同、模型路线、生产配置或资源授权。

## 1. 决策结论

采纳 Grok 方案中“每次主动说明原因、记忆可查可改可忘、控制与动作结果可找回”的产品要求，补入既有 AF-1/UX-1 的行为细节。保留 SwiftUI、conversation-first、A1 图标、现有模型路线及 Supabase 底座；不合并新的四 Tab App，不引入第二套状态库、假执行日志和暖橙深色主题。

Grok 分支是一个可阅读的产品草案和内存界面骨架。它没有连接模型、Agent、日历、通知、数据库或执行回执，不能作为“主动 Agent 已实现”的证据。最需要修正的是把“用户确认”和“真实执行完成”分开：代码现在点击确认后直接写入“已确认并执行”，实际只修改内存数组。应由当前底座的审批、执行、核对和回执决定界面状态。[固定 AppStore 第40–45行](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Core/Stores/AppStore.swift#L40)

Meta Muse、OpenAI dots、xAI Grok Bot 均找到一手官方产品资料；用户已确认 Grok Bot 指 xAI 的实际产品。Grok 文档中的“主动最强”“移动非优先”“个人生活弱”等排名仍无测量或出处，不能用于决定我们的优势。CopilotKit 的 OpenMuse/OpenDots/OpenBot 开源模板与这些闭源官方产品分别记录，名称相近不构成代码来源或功能等价证据。

## 2. 源码身份与核读范围

| 项目 | 本次固定输入 |
| --- | --- |
| 仓库/分支 | Yankj/mimi；feat/grok-cat-companion |
| commit | 38c44457cb3f360beed9ee0dab5ab87b001db0c9；[固定 tree](https://github.com/Yankj/mimi/tree/38c44457cb3f360beed9ee0dab5ab87b001db0c9) |
| 已读 | README、Docs 7篇、CatCompanion 9个 Swift 文件，共17文件、22544字节 |
| 只读缓存 | build/research-grok-companion-20261013/source/ |
| manifest | build/research-grok-companion-20261013/READ-SOURCES.json；tree_truncated=false |
| manifest SHA256 | 6a16d90d65d2e6303610dc1adc4f5829d6bd2e17edc4ec53cf099b96ae8666bd |
| 校验 | 17/17文件长度与 Git blob SHA1 均吻合 manifest；全部逐文件阅读 |
| 证据边界 | 未安装依赖、编译、运行 App、调用模型、执行系统动作或连接生产服务；不声称能构建或通过原生验收 |

本次新增 CatCompanion 骨架范围没有独立 Xcode 工程、Package.swift 或构建配置；完整分支仍包含既有 apps/ios-conversation 等工程、根 Package.swift 与 THIRD_PARTY_NOTICES.md，不能把17个选读文件当作完整仓库。这里只记录新增骨架的静态边界；本次没有复制源码或引入依赖。README 所列 Core/Services 和 Features/Proactive 目录未在新增骨架中实现；EventKit、UserNotifications、BGTaskScheduler、云 API 是文档计划，9个 Swift 文件没有实现这些连接。[README 目录与运行说明](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/README.md#L19)

## 3. 具名竞品：官方声明与未确认边界

以下只用于建立参照，不是实机评分，也不能证明内部实现、稳定性或执行一致性。

| 参照 | 本轮一手资料确认的能力 | 比较时必须保留的边界 |
| --- | --- | --- |
| Meta Muse | 官方介绍个人 Agent、App/WhatsApp、iOS/Android、专用安全 VM/浏览器、主动建议、记忆/遗忘、Sentinel 审查和敏感动作用户确认 | 美国 rollout 与账户实际可用性需逐版本核实；不得据宣传推断审批幂等或崩溃恢复；“深度记忆弱”未获证据。[Meta 官方介绍](https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/) |
| OpenAI dots | 官方介绍持续云端电脑、长期目标/反馈、主动研究和手机消息；主动研究的连接应用权限为只读，不能自行发消息、改应用或操作电脑，规则与自动审核控制后续动作 | 主动研究与交互式执行的授权边界不能混同；具体移动创建入口随 rollout/版本核对；“移动非优先”“价格高”不能代替实际体验和费用比较。[OpenAI 官方介绍](https://openai.com/index/introducing-dots/) |
| xAI Grok Bot | 官方介绍持久云端电脑、文件/浏览器/终端、长期上下文、routines、手机对话和审批；同账号 bots 共享电脑，bot 对话上下文分别保存 | 上下文分开不等于电脑隔离；不能推定开源 OpenBot 就是其实现；“个人生活触达弱”没有证据。[xAI overview](https://docs.x.ai/grok-bot/overview) |

xAI 的移动文档（更新2026-10-12）明确 iOS 18+ 和 Android；手机可处理对话、语音、文件、审批及电脑接管。手机目前可查看 routine 的计划/历史并暂停、恢复或删除；编辑计划/指令与测试运行仍需桌面。这给小咪的候选机会是把既有公开网页跟进的完整设置/修订闭环做在 iPhone，而不是声称我们的执行能力全面领先。[xAI mobile](https://docs.x.ai/grok-bot/mobile)

xAI 审批文档（更新2026-10-12）提供允许一次、允许规则和拒绝，ask-first 优先；无人值守待批约10分钟过期，过期动作不执行，事后允许规则只影响未来。自动审核不保证零风险；共享电脑也不是 bot 间安全边界。小咪应保留原动作版本、明确过期和 unknown，不把“永远允许”或多点击一次当默认解决办法。[xAI approvals/security](https://docs.x.ai/grok-bot/approvals-security-and-privacy)

xAI 区分 skill（可复用指令）和 routine（何时调用），建议先跑通一次真实任务再自动化，明确来源、时区、预期结果和待批/缺资料处理。小咪可借鉴创建跟进时的确认摘要；多 Specialist、任意技能市场和更多连接器仍是扩展。[xAI skills/routines](https://docs.x.ai/grok-bot/skills-routines-and-automations)

原表的 Instinct、Gemini Spark、Apple Siri AI 身份与排名未在本轮逐项核验，不据此下结论；“移动瓶颈不是模型”“最被认可的隐私架构”等断言也没有给出研究方法。现有模型尚未通过本轮真实路由验证，不能先排除模型可用性、工具调用或速度问题。[原竞品表与结论](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/01-competitive-research.md#L5)

## 4. 七篇文档的采纳、修正与延期

| 输入 | 可采纳 | 必须修正或延期 | 对应当前合同 |
| --- | --- | --- | --- |
| [01 竞品调研](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/01-competitive-research.md#L14) | 解释、确认、遗忘作为首要产品要求 | 补一手来源、实际版本与比较方法；去掉无出处排名；不从竞品存在推断我方已拥有云电脑 | AF-R03/07/08；AF-A09–13 |
| [02 产品定位](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/02-product-positioning.md#L7) | 长期上下文、可控主动、端云协作 | 用户已选通用 Agent 底座，不能改成“对话只是入口之一”的商家个人层；“猫伴”只作候选名称，不新增品牌授权 | AF-1-G3-UX1；AF-U01 |
| [03 产品说明书](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/03-product-spec.md#L5) | 日程/提醒、任务完成/待批、用户关注事项、可追溯副作用 | 日程输入对应CP-03；公开变化跟进对应CP-02；商家指标、账号连接器、未知变化即时推送延期；交通延误不能用示例伪装实时数据 | AF-A08/12–15；CP-01–03 |
| [04 交互设计](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/04-interaction-design.md#L3) | 为什么现在、动作预览、修改/拒绝、候选记忆、来源提示、勿扰和日志入口 | 默认对话＋侧栏；精确许可取代“低风险自动/高风险二次确认”的硬编码分类；关闭sheet≠决定；锁屏摘要属于系统通知能力，不能当独立已实现渠道 | AF-A02/09–11/14–16；AF-U01/07/09 |
| [05 视觉设计](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/05-visual-design.md#L3) | 语义区分、原生sheet、记忆列表和克制动效 | 保留UX-1的A1/中性黑白与现有强调色、系统浅深色、17pt动态正文、44pt目标；不引入橙/紫/青三套主视觉或固定15pt正文；只依靠色条不够 | AF-U02/07/09–11 |
| [06 技术选择](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/06-tech-selection.md#L3) | SwiftUI为主；手机负责可用设备动作；重执行继续现有API；后台调度与前台UI分开 | 该骨架没有SwiftData实现；主工程保留已有Repository／SwiftDataPersistence，不另建权威状态；BGTaskScheduler不是定点服务端调度；TS局部由体验/互通探针决定，不能绝对禁止；不得自行修改部署版本或引入依赖 | AF-R05/08/09/12；S01–S07 |
| [07 落地节奏](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/Docs/07-solution-roadmap.md#L9) | 先验一个真实闭环，控制面随主动能力同步实现 | 4–6周无估算依据，不作为承诺；不另开以商家灰度为结束条件的MVP；按现有切片和门槛推进，同一候选全部18A/12U/3CP仍必需 | [AF计划](../planning/AF-1/plan.md)、[验收](../acceptance/agent-foundation-acceptance.md) |

Apple 明确 BGTaskRequest 的 earliestBeginDate 仅保证不早于所设时间，不能保证该时间启动。因而本地调度可以补足缓存/设备工作，不能关闭 AF-A12 的服务端独立调度验收。已知时间的本地提醒与云端未知变化 APNs 也分别验收。[Apple earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)、[当前AF-A12/15](../acceptance/agent-foundation-acceptance.md)

## 5. 九个 Swift 文件的真实边界

| 固定文件 | 实际行为 | 整合决定 |
| --- | --- | --- |
| [CatCompanionApp.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/App/CatCompanionApp.swift#L3) | 新建AppStore，独立 @main 注入环境 | 不导入第二个App入口；维护入口仍是 apps/ios-conversation/CatpawM.xcodeproj |
| [RootView.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/App/RootView.swift#L7) | 永久四Tab，默认今日页 | 不采纳；记忆、跟进与设置通过现有侧栏/对象详情进入 |
| [Domain.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Core/Models/Domain.swift#L3) | UUID记忆、主动建议与文字日志；没有账户/Task/Run/effect/approval身份；confidence默认0.9，source默认“用户确认” | 仅借助reason/actionPreview的表达思路；映射现有对象、scope、revision、来源和确认状态，不把默认数字/文案当事实 |
| [AppStore.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Core/Stores/AppStore.swift#L6) | 内存样例：口味、会议、路况12分钟、门店报告；增删/确认/忽略均只修改数组 | 示例必须明示，不注入真实用户历史；禁止“确认即执行成功”；不作为Store替代实现 |
| [Theme.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/DesignSystem/Theme.swift#L3) | 固定深色颜色；卡只显示title/reason和确认/忽略，没有actionPreview/risk详情、修改入口或提交中状态 | 可参考紧凑原因文案；仍按UX-1语义tokens和完整状态实施，不直接复制组件 |
| [AssistantView.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Features/Assistant/AssistantView.swift#L3) | messages:[String]按数组下标辨认，发消息后追加固定“已记录”回复；无模型、网络、SSE、角色/turn身份、附件、许可或恢复 | 不复用聊天链路；固定回复不能宣称记忆已保存；保留现有连续对话/队列/附件/阅读位置合同 |
| [HomeView.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Features/Home/HomeView.swift#L11) | 展示全部样例建议；proactiveEnabled仅改变header文案，关闭后卡片仍在 | 不让开关只改变标签；既有结果可保留，暂停必须在服务端拒绝新due，区别通知静默 |
| [MemoryView.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Features/Memory/MemoryView.swift#L11) | 原生List、类型picker、内存新增/滑动删除、固定置信度展示；没有编辑详情/候选确认/持久化/删除屏障 | 借鉴原生列表表达；逐条来源、范围、候选/确认、修订和删除效果由AF-R07实现；不要求用户手填类型才可记忆 |
| [SettingsView.swift](https://github.com/Yankj/mimi/blob/38c44457cb3f360beed9ee0dab5ab87b001db0c9/CatCompanion/Features/Settings/SettingsView.swift#L9) | 两个RAM布尔量、静态确认策略、内存日志；没有系统权限申请或实际策略 enforcement | 控制页面必须来自真实授权/Trigger状态；勿扰变量目前不改变任何行为，不能算通知或调度已实现 |

源码不含并发claim、持久待批、lease/fence、执行意图或可核对回执。因此未提交、已执行、已拒绝、超时unknown和断网恢复在这里无法区分；终止后重开将重新生成样例，旧决定/日志丢失。任何宣称“不会重复执行/遗忘不复活/退出后继续任务”都需现有底座和真实测试提供证据。

## 6. 对终版设计可直接采用的细化

### 6.1 流式可交互 UI

正文持续增量呈现；计划/澄清/审批/成果使用既定六种受控原生卡。生成中可呈现摘要与骨架，参数未完整、schema不合格或权威对象未就绪时不可提交；正文仍可阅读、复制和回看。显示已保存与用户已读分开，不能因模型流结束把步骤全标完成。[AF-R10及状态细化](../product/agent-foundation-spec.md)、[UX-1卡片状态](../design/ios-codex-experience-spec.md)

ProactiveItem.reason可改成展示层的“为什么现在”摘要，必须从任务、变化证据或约定时间导出；actionPreview可用于实际对象的预览。保留当前cardID/objectID/objectRevision/actionID与typed payload映射，不能用随机UUID和自然语言重新构造副作用，也不改冻结wire。未知卡有可读降级和回原事项入口，不运行模型生成脚本。

### 6.2 Human-in-the-loop

用户从同一对话补条件、改计划、拒绝/修改动作；修改对象或参数使旧审批失效。sheet关闭只是关闭；原消息/任务/收件箱保留待决入口。提交后先处理中，服务端确认后才展示结果；已成功但续聊/刷新失败只重读，unknown只核对原effect，不重新创建动作。理由、对象、参数、影响和许可范围比强制“再点一次”更有价值。[AF-A09/10](../acceptance/agent-foundation-acceptance.md)、[AF-U06/07/12](../acceptance/ios-codex-experience-acceptance.md)

风险标签可作说明，不授予权限：创建本地提醒也必须满足既定精确许可和系统权限；对外发信、下单、账号登录未进入当前资源/功能范围。若后续允许规则，需要单独的权限范围与撤销设计，不能从Grok文档中的“低风险自动”直接继承授权。

### 6.3 主动性、记忆与可控性

“主动”先由用户托付的时间/条件/预算/结束约定驱动，不假造知道路况或用户日程。每次触达显示触发来源、变化或到期依据，并回同一Task/成果；无变化静默、重复去重、失败退避。主动开关的作用须明确为暂停新执行；勿扰仅延迟提醒、保留成果，已运行任务按现有取消策略收尾。服务端独立运行的托管缺口如未解决，仍记录BLOCKED，不用手机BGTask或常开Mac替代。[AF-R08细则](../planning/AF-1/spec-details.md)

记忆列表优先展示内容、来源/范围、确认和更新时间；有编辑/删除详情。隐式抽取是候选，显式保存按合同确认；更正带revision，删除有屏障阻止迟到job复活。置信度数字并非用户确认或真实性的替代品；任务使用哪些已确认版本可查。SwiftData/本地缓存只可作为投影，服务端及既定持久对象的权威身份保留。[AF-R07细则](../planning/AF-1/spec-details.md)、[AF-A11](../acceptance/agent-foundation-acceptance.md)

### 6.4 布局与视觉体验

以当前iPhone单列对话为默认，侧栏组织活动/成果/记忆/跟进；等待确认和成果从原消息一次点按进入同一对象。今天摘要可成为既定对话或活动中的内容，不新增强制首页。延用A1、系统浅深色、17pt动态正文、44pt动作，正文优先；主动原因用短句和可展开来源表达，不靠多色大卡、数字置信度或常驻调试区。[UX-1](../design/ios-codex-experience-spec.md)

## 7. 八项可验证的优势候选

这些是比较实验建议，尚无结果，也不新建执行Goal。必需产品门槛沿用现有AF合同；新增比较阈值由终版比较合同确认。只在同类能力、相同人工材料、同语言/设备条件、具名版本与可用账户上比较；竞品无权限/未开放记为不可比较，不算输。公开宣传与截图只能构建假设，不能关闭实机比较。更多模型调用、设备包或第三方账户操作仍须具体授权。

| 候选优势/场景 | 测量与证据 | 我方最低结果及比较判断 |
| --- | --- | --- |
| 1. 流式阅读与卡片同时可用 | 公开资料报告，先澄清再计划，正文增量时上滑阅读；记录回显/首字/完成时间、锚点、schema就绪时点、卡动作状态 | 沿用AF-A04的真机回显p95≤150ms、首字目标p95≤10s/短答完成p95≤60s；不重复/回退，参数未完成动作启用数0。比较任务完成时间与阅读误跳次数，不用模拟网络证明真实速度。AF-A04/16、U03/04 |
| 2. 手机内引导与改稿 | 同对话补一个条件、改计划，再改同一份报告；记录找到入口所需tap、误建任务、revision冲突和草稿保留 | 一个真实Task，修改进原计划/成果，不盲覆盖；作为候选比较目标，主要卡一次点按可达。比较无帮助完成率、tap与用时，不宣称竞品不支持。AF-A07/08、U06/08；CP-01 |
| 3. 审批可找回且结果未知时安全 | 关审批sheet、切会话、终止重开、重放旧卡、模拟已写回执丢失；用户说明将做什么 | 同approval/effect，无重复写入；关闭不决定；unknown只核对，过期0执行。比较待决找回耗时、预览理解正确率和误批准次数。AF-A02/09/10、U07/12 |
| 4. 记忆可更正、删除且不复活 | 人工保存“三条结论＋表格”→新会话→改“两条”→删除→释放迟到抽取job；查看使用来源 | 新任务按当前版本，删除后0旧值注入/复活；跨scope读取失败。比较独立完成更正/删除的用时及用户对删除范围的理解，不用“最强记忆”作为指标。AF-A11、U09；CP-01 |
| 5. iPhone内完整创建与修订跟进 | 公开测试页，创建条件/时区/频率/预算/结束，改规则、暂停/恢复/结束，不借桌面；记录回手机后的结果 | 既有AF-A12真实两次due各≤120s受理、一个due一个run、暂停后0新run；完整配置在手机可完成。xAI手机编辑routine的当前桌面依赖是具名机会，仍需实机同版确认。AF-A12/13、U09；CP-02 |
| 6. 主动及时且克制 | 无变化两轮、同一变化重复投递、失败/恢复、静默时段与暂停；查看“为什么现在” | 无变化0新提示、同变化1逻辑结果，失败有界退避；静默保留成果/延迟提醒，暂停拒绝新due。比较有效触达比例、重复率和来源理解，不把通知次数多当主动强。AF-A12/13、U09；CP-02 |
| 7. 可核对的原生设备闭环 | 人工创建日程/已知时间提醒，精确预览，系统权限允许/拒绝，点击提醒返回；核对系统对象 | 确认后1真实对象、拒绝0写入，device等待明确，提醒回同task；未知远端推送未验证就明示。比较入口用时/身份一致率/错误恢复，不添加对外发信、购物或第三方账户。AF-A14/15、U07/09；CP-03 |
| 8. 中文与可访问的持续工作体验 | 同一报告/审批在375/390/430pt、浅深色、中文IME、最大辅助字号、VoiceOver、Reduce Motion；后台5s/30s并重开 | AF-U10–12全部通过；主要动作44pt、无裁切/页面横滚、草稿和同对象位置保留、无额外发送。比较无帮助完成率和可读性偏好，而非靠截图相似度宣布全面优于。AF-A05/17、U01–12 |

比较执行前固定任务脚本、产品/build、材料hash、设备/网络、账户能力和次数；顺序交叉，分别记录服务等待和用户决策时间。先用至少5名目标使用者做方向性评审，报告样本数与逐人结果；这不是市场总体结论或p95性能认证。真实模型调用仍按现有最多两次短检查范围，不能为统计量扩量；正式性能采样另按验收合同固定上限与授权。只有双方在可比较条件下完成实际观察，才写某个具名场景的优势，保留失败/限制和日期。

## 8. 建议的实施顺序与不扩展项

1. 先验证现有路由和当前包的正常入口，收齐输入→许可→受理→provider→事件→存储→呈现证据；失败定位原段，未经讨论不换供应商或付费fallback。
2. 沿S01–S03完成连续对话、可找回审批、队列/阅读、真实Task/计划/成果与六卡状态；同时按D10–D30核对iPhone布局。
3. 沿S04–S06接通候选记忆/更正/删除、独立调度/公开变化、精确设备动作与可控提醒；控制按钮的实际语义必须与服务行为一同验收，按D40推进。
4. S07/D50对同一候选做完整AF-A01–18、AF-U01–12和CP-01–03。模型、SQL竞争、云调度、系统设备证据不能由内存App、HTML或历史合成结果代替。

资源范围继续遵守现有Supabase优先、新增计算预算0，云电脑托管/供应商/区域只做Proposed；不引入CopilotKit、第二套SwiftData存储或新依赖，不导入Grok分支，不引入收费服务、第三方登录、APNs即时远端变更、多Specialist、任意MCP、短信/WhatsApp、自动外发或购买。选择某框架不构成产品验收，也不缩减现有同版总Goal。

## 9. 本轮输出与局限

本轮交付的是17文件固定核读、具名竞品的一手边界、采纳/修正/延期表及八项测量建议。没有修改生产源码、权威计划/状态、依赖、模型/权限或线上部署；没有验证本分支可构建、现有包模型已通、任何闭源产品完整体验或任何我方优势。运行状态仍只看master-plan，原生与真实执行验收仍按现有合同推进。
