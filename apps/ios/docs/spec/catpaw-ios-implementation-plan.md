# cat iOS 工程实施规格

版本：0.1 待本机环境与31图证据矩阵校准  
日期：2026-10-10  
目标：先冻结产品、设计、验收与本规格，再持续实现独立可运行的 iOS Agent App。交付不能停留在 HTML 原型或只有可点击入口的壳。本文是实施计划与契约，不代表工程已经构建或后端已经接通。

## 1 执行决定与边界

**默认原生 SwiftUI，独立 iOS 工程，优先 iOS 17+。** SwiftData 做本地持久化，Observation 管理界面可观察状态，系统 AVSpeechSynthesizer 做先行朗读；原生 ASR 只做 on-device 能力探测与用户主动启用路径。前期零第三方运行时依赖，不以安装 GPU 模型、接云账号或拿到原 CatDesk 代码作为基础复刻前提。

最低系统和语言模式以本机实际 Xcode/SDK、目标设备与用户要求校准；不能在尚未检查时声称支持某个 Xcode、已通过模拟器或已安装到手机。若证据要求低于 iOS 17，保留领域/provider接口，用 ObservableObject + Core Data/SQLite 调整基础设施；不要同时维持两条实现分支，先记录一个明确 ADR。

实施顺序：证据与验收 → B0 原生基础真实本地功能 → 同一工程内新增长期助理与语音 → R1 真实后端有限闭环。D0是参考交互，不是交付终点；D1原宿主适配是以后可选路径，不能阻塞独立工程。

真实与模拟必须分开：

- 本地会话、消息、项目、专家/技能配置、任务记录、定时规则、文档和权限偏好是真实数据。
- FixtureProvider 能演示模型回复、进度、审批与结果，均明确标模拟。
- 未连接真实Agent后端时不能称“AI已经完成研究/电脑执行/云定时”。
- 系统TTS有真机/模拟器实际证据才称朗读可用；动画不是声音证据。
- ASR、麦克风权限、云传输互相独立；启动App、打开语音界面或朗读都不自动弹麦克风/识别权限。

## 2 交付清单与环境入场记录

实施者首先记录：macOS版本、`xcodebuild -version`、Developer目录、可用iOS SDK、已安装Simulator runtime与device ID、Swift编译器、目标设备/签名可用性、实际工作目录、工程是否存在。检查是只读；缺失SDK/额外安装、Apple账号登录、签名/部署能力不能悄悄假定。

应交付：

1. 可打开的原生Xcode工程及共享scheme，源码、资源、测试、运行说明完整。
2. 覆盖31图的功能/设计/证据矩阵，标 confirmed / inferred / unverified。
3. 所有已证实基础模块的适用本地主路径，新增助理和语音复用同一数据层。
4. 版本化fixtures与至少成功/失败/取消/过期/离线情节；重置fixtures不删用户数据。
5. 可重复构建与测试记录、模拟器截图/录屏、未测真机项清单。
6. 后端未连的能力清单和provider接入口，不用“TODO页面”冒充完整功能。

如果Xcode不可用，仍编写工程结构、Swift源文件和测试契约；如能进行独立静态检查则执行，但明确构建/运行未验证。不能把浏览器截图当iOS运行证据。若有Xcode，则计划评审后进入实际编码、构建与迭代，不停在本计划。

## 3 工程结构与职责

建议单App target + 一个纯Swift核心模块 + Unit/UI Tests，前期不拆过多独立package：

- App：CatpawApp、AppContainer、AppCoordinator、启动/错误恢复、scenePhase响应。
- DesignSystem：颜色/字体/间距/图标与可复用组件；以31图为依据，支持Dynamic Type、深浅色可读性与减弱动态效果。
- Domain：值类型、状态机、命令、校验器、日期/时区与证据映射，不依赖SwiftUI/SwiftData/AVFoundation。
- Persistence：SwiftData schema、migrations、repository actor、blob store、seed/migration元数据。
- Providers：LocalProvider、FixtureProvider、UnavailableRemoteProvider、将来Host/RemoteAdapter。
- Features：Conversations、Projects、Experts、Skills、Tasks、Schedules、Documents、Environments、Permissions、AssistantBrief、Voice。
- Voice：PermissionBroker、AudioSessionCoordinator、NativeTTSAdapter、OnDeviceASRAdapter、VoiceCoordinator。
- Tests：Domain状态/策略、repository持久化/迁移、provider合约、voice控制、SwiftUI流程。

AppContainer只做依赖注入，不承载全部业务。View调用FeatureModel/command，不能直接在按钮里写数据库、创建网络请求、改权限或控制全局TTS。每个FeatureModel位于MainActor；跨actor返回Codable & Sendable的值类型，不把SwiftData @Model对象跨线程传递。

## 4 Swift 类型和存储策略

### 4.1 两层模型

`Domain DTO` 是可测试的 struct/enum（Codable、Sendable）；`SwiftData Record` 是具体 @Model 类。二者通过明确mapper转换，不把API schema直接硬绑SwiftData实体。

每个本地Record共同字段：UUID id、profileID、workspaceID、Int revision、Date createdAt/updatedAt、Date? deletedAt、String originRaw、String? providerID/providerObjectID、Data evidenceRefsJSON。不要依赖持久化类继承表达公共封套；可在mapper中复用转换。ID用随机UUID；fixtures使用稳定固定UUID供测试，演示和用户分区不同。

复杂、版本化配置（ScheduleSpec、ExpertConfig、SkillDefinition、content blocks）可先以受校验的Codable Data保存；需要查询的字段独立列出，不能把所有数据变成一个无法索引/关联的JSON blob。关系前期可用UUID引用以明确删除语义，repository验证同profile/workspace与关联存在；若用SwiftData关系，必须写清inverse和delete rule并测试，避免误级联删除。

JSON契约的snake_case、RFC3339日期、业务枚举rawValue要显式映射。不要依赖Swift关联值enum的默认编码碰巧等于既有JSON Schema。

### 4.2 基础实体到Swift模型

| 实体 | Domain DTO / SwiftData Record | 最小实现字段 |
|---|---|---|
| 会话 | Conversation / ConversationRecord | title、projectID?、expertID?、environmentID、archivedAt?、draftText |
| 消息 | ChatMessage / MessageRecord | conversationID、role、contentBlocks、clientMessageID、replyToID?、state、executionReality、sequence |
| 项目 | Project / ProjectRecord | name、summary?、documentIDs、defaultExpertID?、skillIDs |
| 专家 | Expert / ExpertRecord | name、summary、configuration、kind、configRevision |
| 技能 | Skill / SkillRecord | name、summary、definition、version、enabledScopes |
| 任务 | WorkTask / TaskRecord | title、conversationID、environmentID、state、steps、resultDocumentRefs、operationID、executionReality |
| 定时 | ScheduledTask / ScheduleRecord | title、scheduleSpec、timezoneID、enabled、nextDueAt、executionMode、taskTemplate |
| 文档 | Document / DocumentRecord + DocumentVersionRecord | title、mimeType、version、blobRef、hash、ownerRefs、sourceKind |
| 环境 | ExecutionEnvironment / EnvironmentRecord | name、kind、connectionState、capabilities、verifiedAt? |
| 权限偏好 | PermissionPreference / PermissionPreferenceRecord | scope、decision、authority、expiresAt?、revision |
| 助理委托 | Delegation / DelegationRecord | goal、scope、trigger、stopConditions、state、revision、health |
| 助理运行 | AssistantRun / RunRecord | delegationRevision、trigger、phase、contextManifest、artifacts、reality |
| 授权/回执 | Action/Approval/Receipt DTO与对应记录 | digest、具体目标/正文版本、授权版本、结果证据；B0真实外部执行关闭 |
| 记忆 | MemoryItem / MemoryRecord + SuppressionRecord | scope、来源、有效期、supersedes、deletionEpoch、防重建元数据 |

存储中的MessageRole仅用于展示；导入或fixture的system角色不能升级为真实模型高优先级指令，所有上下文装配仍经过来源/权限边界。

字段证据标注：名称/布局等以图为据；技术ID、版本、分区等为工程新增。图未见的“自定义专家创建”“技能安装”“文档协作”不可冒称原功能，先按矩阵确认适用范围。基础模块必须有主路径，不因部分远端能力未证实而整页禁用。

### 4.3 本地持久化配置

iOS17+推荐SwiftData ModelContainer + VersionedSchema + SchemaMigrationPlan，显式指定私有应用目录和 `cloudKitDatabase: .none`，不添加iCloud自动同步能力。Apple文档说明容器负责存储和迁移，复杂演进需迁移计划；CloudKit自动发现可显式关闭。[ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)、[关闭自动CloudKit同步](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)

关键用户写入显式save/transaction，成功后才显示已保存。不要依赖autosave在未来某个时刻发生；保存失败保留未保存UI与可恢复内容。Apple ModelContext文档明确未保存修改仍在内存中。[ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)

Repository使用专用context并显式autosaveEnabled=false，UI不得直接改mainContext或持久模型；UI草稿是独立值状态。Repository以专用actor/ModelActor串行化写操作；实现者按目标SDK核验可用API。事务内检查expectedRevision与clientOperationID，写实体及change record；并发编辑返回conflict，不静默覆盖。不要在存储事务里await网络或语音调用。commit失败必须rollback并重置/刷新受影响context状态，不发LocalCommit、不发布changeSequence；否则脏insert/update可能被后续save意外持久化。操作幂等记录和change record与实体同事务，重启时先按operationID核对是否已提交，不能盲目重做。

文档blob保存在应用私有目录，记录固定版本与hash；使用临时文件写入、校验后移动、再提交元数据的可恢复流程。此流程不是跨文件/数据库原子事务，启动时做staged/orphan reconciliation。文本/Markdown先支持真实编辑，PDF用系统阅读器/PDFKit只读，其他格式按已实现能力打开/解释，不冒称全部可编辑。

导入使用系统fileImporter/document picker和实际安全作用域访问规则，只处理用户选择的文件；需要长期保存时复制到App私有目录。资源URL、文件名与Markdown内容均不当可执行指令，禁止路径穿越和活动HTML。

## 5 里程碑与模块实施工作包

与产品统一的里程碑：

| 里程碑 | 目标 | 细分工作包 |
|---|---|---|
| M0 | 证据与Spec冻结到足以开工 | 环境只读核验、31图矩阵与关键契约；未知不拖住可逆编码 |
| M1 | 原生外壳与本地数据 | WP0工程、repository、导航与首个可运行会话 |
| M2 | 基础功能复刻 | WP1–WP4全模块适用主路径与真实本地持久化 |
| M3 | 助理融合与真实本地执行 | WP5；本地改稿/状态变化真实，远端fixtures仍标模拟 |
| M4 | 原生语音融合 | WP6；真实TTS/ASR能力与权限分别验收 |
| M5 | 真实Agent/provider接通 | 经授权的实际服务请求与回执；fixture不能代替，持续云R1另验 |
| M6 | 回归与交付 | WP7、完整运行证据与剩余真实服务边界 |

WP编号是技术细分，不另定义一套产品里程碑。M0达到开工条件便进入编码，不等待所有未知后台答案。

## 5A 模块实施工作包

### WP0 原生工程与证据基线

建工程、bundle identifier占位、共享scheme、依赖容器、设计token、profile分区、导航骨架、fixtures资源与测试target。先跑空工程build/test。读取31图建立截图ID→route/component→字段→主路径→验收映射，尚未证实的字段标明，不凭想象填齐。尚未取得矩阵时先实现不依赖视觉精确参数的核心契约与存储。

### WP1 会话 消息与环境上下文

会话列表/空态/创建/重命名/打开，输入草稿恢复，本地发送消息、fixture流式回复、取消与重试，文件/任务内容块渲染。消息与会话更新同事务。云端/电脑切换影响新会话/新任务的选择上下文，既有任务环境固定。后台取消fixture流后回前台不重复续播。

验收：发送的本地消息真实持久化；fixture回复始终带模拟来源；双击发送只一个clientMessageID；重启顺序和草稿正确；无后端也能完成本地主路径。

### WP2 项目 专家与技能

实现已证实的列表、详情、选择及配置流程；项目关联会话/文件，专家/技能选择反映到相应Conversation/Task配置。允许的本地编辑按证据矩阵决定，fixture资源与用户自建数据分开。真实安装、模型/工具能力和账号权限不是改开关就生效。

验收：不是入口空壳；选择/编辑后跨页和重启一致；撤销关联不恢复；切换profile不串数据。

### WP3 任务 定时任务与权限

任务详情/步骤/状态/结果、应用活跃时的本地fixture运行、取消/重试；定时规则创建/编辑/暂停/恢复和nextDueAt计算；权限列表/范围/具体模拟审批及撤销。显式展示local_session_only、simulated或真实provider状态。

本地计时器只推进应用活跃且获得执行机会的模拟任务，不用BGTaskScheduler保证云定时。关闭App期间不得编造历史。未有真实provider时，“在云端执行”“电脑已在线”“权限已授予外部服务”等不能显示成功。

### WP4 文档与统一阅读器

任务结果、消息附件、项目文件引用同一Document/Version。阅读器支持截图已见布局与返回，文本/Markdown可编辑保存新版本，PDF只读，版本冲突可见。首版先采用内置/用户选定本地文件；真实云文件读写留给provider能力。

验收：固定版本读回hash一致；从不同入口看到同一内容；编辑后不覆盖旧版；中途关闭/重启、缺文件和无支持格式有明确行为。

### WP5 长期助理在基础上复用

工作简报一个已准备成果+轻量跟进；创建/修改/暂停委托、来源/记忆、成果版本、待确认动作。Delegation active、Run succeeded、Artifact ready、view receipt独立。B0使用fixture事件/来源与本地成果，所有内容标清；真实研究R1接后端后另验。基础Task/Document与助理Run/Artifact通过稳定ID映射，避免两套历史。

### WP6 原生朗读与口述输入

先实现NativeTTSAdapter、权限只读探测、可编辑模拟ASR与VoiceCoordinator，再按用户主动操作启用真正可用的on-device ASR。连续对话先轮替/按住说话，不把全双工AEC列为必达。详细见第9节。

### WP7 回归与封板

每个工作包随代码提交附测试结果；完成端到端从新会话→选项目/专家/技能/环境→建任务→看结果文档→本地定时规则→委托跟进→朗读/口述改稿。再做数据迁移、重启、profile隔离、取消/迟到、无权限与存储失败。若后端未接，封板名称是“原生iOS本地基础版+明确模拟远端”，不能叫真实全功能Agent。

## 6 Provider接口与状态契约

### 6.1 协议分层

- LocalRepository：本地权威持久状态，不接网络。
- AgentProvider：conversation reply、task execute、operation observe/cancel；返回ProviderEvent。
- ScheduleProvider：真实持久schedule能力；默认Unavailable，B0本地规则由LocalScheduler处理。
- DocumentProvider：固定版本读取/写入，私有本地实现先行。
- EnvironmentProvider：能力与实际连接状态；未验证时unverified。
- AuthorizationGateway：真实外发许可、ActionEnvelope、dispatch_commit与回执，B0无真实写适配器。
- TTSProvider/ASRProvider/VoiceSessionAdapter：沿语音契约，原生实现见第9节。

FixtureProvider遵守相同协议但由registry强制executionReality=simulated，情节由固定seed/clock可重复控制；即便fixture负例含remote_verified也须拒绝或降为模拟。UnavailableRemoteProvider返回明确capabilityUnavailable，不用假成功。模型文本不能改provider mode、创建连接或扩大权限。

所有远端功能在capability、用户数据传输范围、认证和后台回执都满足前禁止实际调用。将来配置真实provider是独立授权的接入工作，不能因用户同意“开发App”就自动开账号、填密钥或部署服务。

### 6.2 Swift接口交付

配套 `catpaw-ios-contracts.swift` 是基础Domain/provider/语音接口，`catpaw-ios-agent-contracts.swift`是委托/运行/成果/记忆/审批/回执类型；两者共同作为实施参考，带显式public初始化入口；当前编写环境没有Swift编译器，尚未typecheck，更不是已编译iOS工程。需实现者在实际Xcode工具链首先编译校准。字段与状态来自主技术规格及两份JSON Schema；实际代码落地时可按Swift风格命名，但rawValue/wire mapping必须一致。测试不能只验证能decode，还需验证版本、权限、scope和状态迁移。

默认流返回 `AsyncThrowingStream<ProviderEvent, Error>`；事件含operationID、sequence、executionReality、run/turn/epoch。调用端持有Task句柄并取消，适配器清理生产端；迟到事件由状态机拒绝。取消Swift Task不等于真实外部动作被取消，真实回执仍按unknown/核对处理。

消息流必须有显式 `messageCompleted(finalTextHash, finishReason)`，任务成功必须有独立 `taskCompleted(receiptReference)`；`verified`是观察证据，不暗自终止流。每个operation/attempt最多一个被接纳的终态。自然EOF、网络断开或producer意外消失，没有预期成功终态时不得设completed/succeeded，应进入interrupted/failed或对真实副作用保留unknown，并保留已流出的partial文本。finalTextHash校验按约定的UTF-8最终文字；不匹配不能成功。finishReason=length需显示截断，tool_work_continues不表示业务任务完成。FixtureProvider也遵守相同结束协议，不能靠sleep后stream结束冒充成功。终态后的重复、迟到或冲突回包被拒绝/记录，不改变最终结果。

### 6.3 必须保留的状态区别

- Message：draft/local_saved/waiting_provider/streaming/completed/failed/cancelled；completed再看executionReality，不能混同真实发出。
- Task/Run：queued/preparing/running/verifying/succeeded/waiting_approval/waiting_dependency/retry_scheduled/cancel_requested/cancelled/failed/outcome_unknown。
- Delegation：draft/active/paused/completed/cancelled/expired；归档是终态可见性字段。
- Artifact：draft/ready/stale/superseded/withdrawn；阅读回执独立。
- Provider：local_available/fixture_available/remote_verified/unavailable/unverified。
- PermissionPreference：只表示local_preference或fixture，不能冒充provider_verified真实授权。
- External receipt：reserved只是预约；dispatch_commit是保证撤销的分界；accepted≠verified，unknown不自动换ID重发。

状态机纯函数接收state+event+context产生newState+effects，effects由执行器处理。可测时钟和UUID生成器注入，不在测试里靠sleep猜时序。非法迁移明确返回错误，不让View直接任意赋status。

### 6.4 JSON Schema 到 Swift 实体的映射

| 已定版JSON Schema | Swift Domain类型 | 存储/执行说明 |
|---|---|---|
| Delegation | Entity<Delegation> | 本机header与真实服务tenant/owner分开映射；active不因run结束改变 |
| Run | Entity<AssistantRun> + WorkTask引用 | 任务UI与助理run关联，context epochs保留 |
| ArtifactVersion | ArtifactReference + DocumentReference | 固定成果版本绑定固定文档版本与hash |
| ArtifactView | Entity<ArtifactView> | 按用户/版本，不等于审批 |
| MemoryItem / ForgetSuppression | Entity<MemoryItem> / Entity<ForgetSuppression> | 删除屏蔽、来源抑制和派生epoch真实实现 |
| ActionEnvelope | FrozenActionEnvelope | let字段，不能批准后改写；digest服务端/可信gateway重算 |
| Approval | Entity<ActionApproval> | 真实审批不能由本地偏好或fixture升级 |
| ExecutionReceipt | Entity<ExecutionReceipt> | accepted/verified/unknown保留，具体证据由适配器校验 |
| VoiceSession / VoiceTurn | VoiceCoordinator的值状态 + FrozenTranscriptSubmission | 原始音频/partial不入长期store；正式提交正文冻结 |
| ReadoutRequest / VoiceControl | ReadoutRequest + 控制器命令 | 核对相关epochs，不把stopPlayback误作取消业务 |

接口Swift文件是本机所需字段子集和命名映射，不声称生成了完整服务端DTO。实现RemoteAdapter时必须按原JSON Schema补齐并验证所有required字段（如授权来源、policy版本、expires_at、provider回执证据）；不能把这里省略字段的本地DTO直接编码发给服务端。基础LocalRepository可先实现基础实体，M3再增加助理记录类型与对应迁移，不能另造与Task/Document不相通的状态源。

## 7 导航与iOS交互

使用NavigationStack和类型化Route，统一sheet/fullScreenCover呈现。Route携带资源ID、profile、版本和返回来源；主页面、半屏表单、文件阅读器共享AppCoordinator。

深链仅解析受控route/resource标识，不带token、私人正文或任意文件路径。无资源/已删除/跨profile/未知文档版本显示安全回退。外部URL用白名单scheme与系统安全打开，不能把导入链接当运行命令。

从侧栏/项目/简报进入同一资源，导航返回源页面并保留选中项/滚动；关闭sheet不新建重复会话。Scene恢复只恢复路由和未提交草稿，不自动重放发送、审批或运行。Dynamic Type、VoiceOver标签、触摸目标、键盘遮挡、长中文标题和减少动画均纳入测试。

## 8 数据迁移 删除与本机隔离

SchemaVersion、FixtureSeedVersion、ExportFormatVersion分开维护。首次seed只写演示profile；升级fixtures不覆盖用户记录。迁移先校验旧版本与关系，失败保留数据、提供只读/导出，不默认删库重建。

重启需核对staged文档、在途fixture任务和未完成写入；重试沿同clientOperationID，不能产生重复结果。使用repository revisions处理多scene并发，不让MainActor成为“必定无冲突”的错误保证。

清理会话、文档、记忆与彻底删除账户是不同操作。记忆删除必须同步tombstone、suppression、epoch，清理摘要/索引/待发布模型上下文；原对话保留也不能自动重新抽取同一记忆。B0即使用fixtures也要真实实现这些本地语义，不等后端才补。

导出不含密钥/授权token，导入先预览并验证大小/类型/引用；导入权限永不生效为真实grant。profile切换清内存、取消旧订阅与语音、重新校验路由。Web原型中的localStorage数据不自动导入或上传iOS，迁移须明确选择。

## 9 原生语音实施细则

### 9.1 NativeTTSAdapter

使用长期持有的AVSpeechSynthesizer、AVSpeechUtterance和系统可用voice，按固定成果版本/段落分段；delegate实际回调映射为started/progress/finished/cancelled；适配器failed只能来自预检、明确本机错误或有界超时检测，AVSpeechSynthesizerDelegate没有通用didFail回调，不能虚构系统错误事件。Apple说明synthesizer持有播放队列但系统不会替应用保留实例，需显式持有至结束。[AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/)

“停读”调用stopSpeaking(.immediate)并增加playbackEpoch，清空自有待播段；pause/continue与stop是不同语义。停止返回值或delegate事件不能当用户已听完；实际开始、结束、用户停止单列。[stopSpeaking](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/stopspeaking%28at%3A%29)

不申请Personal Voice权限、不做声音克隆，不接Qwen云端作为B0默认。具体中文voice、离线表现与输出路由需实测，未验证只用公开演示文字。私人正文不因“系统TTS”几个字就自动获得向未知语音提供方传输的许可。

### 9.2 OnDeviceASRAdapter和PermissionBroker

PermissionBroker的`inspect`只能读取麦克风/识别权限状态和能力；不弹权限。`requestFromExplicitUserAction`为独立入口，仅响应用户点击“启用语音/开始说话”且说明用途。Info.plist配置NSMicrophoneUsageDescription与采用Speech路径所需的NSSpeechRecognitionUsageDescription；文案对应真实用途，不宣称未验证离线。

使用目标SDK支持的Speech API，例如SFSpeechRecognizer。只有当前语言支持supportsOnDeviceRecognition且用户已授所需权限，才创建requiresOnDeviceRecognition=true的识别请求。不可用返回onDeviceUnavailable，回退文字/明确模拟，不能偷偷创建网络识别请求。Apple文档明确该本地要求依赖supportsOnDeviceRecognition。[Apple On-device Recognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)

AVAudioEngine采集与识别缓冲格式按实际节点协商，内存限长；finishInput请求本句final，abort取消当前capture并使迟到final失效。每句完成/取消清原音。代码不得在启动、scene变active、进入Voice面板或TTS朗读时自动调用requestAuthorization/requestRecordPermission。

模拟器没有所需麦克风/语言资源或受环境限制时如实标blocked/unverified，不能修改结果假称真ASR通过。真实麦克风/识别权限提示需用户实际选择，自动化不得代替用户无意接受。

### 9.3 AudioSessionCoordinator与控制矩阵

唯一音频owner协调播放、录音、音频焦点/路由。先实现轮替/按住说话，按目标SDK选恰当AVAudioSession category/mode；不得靠后台音频能力保活长期Agent。

- stopPlayback：只增playbackEpoch，停止TTS/播放器；合法文字回答、已提交输入继续。
- abortCapture：增captureEpoch，停止采集/上传/ASR；当前未提交本句final丢弃。
- interruptTurn：增generationEpoch与playbackEpoch，结束当前回答输出；不撤销已提交业务。
- endSession：失效语音session/capture/generation/playback，释放资源；后台委托按原授权继续。
- 来电、锁屏、后台、焦点丢失：对未提交句abort，不用finishInput；autoSubmitSuspended=true，迟到final不得后台发送；回前台需用户明确恢复。

ASR核对session/capture/consent epoch，文字核对session/turn/generation，TTS再核对playback/成果版本/删除epoch；不能停读时顺带把合法文字误杀。ASR raw revision与editRevision分开，用户改字后迟到识别不覆盖；提交正文ref/hash/revision冻结。

## 10 测试矩阵与构建验收

测试分层，报告分别列通过/失败/未运行/阻塞，不以单项通过代表整体完成。

| ID | 层级 | 必测内容 | 门槛 |
|---|---|---|---|
| IOS01 | 工程 | 清洁checkout打开共享scheme、无隐藏本机路径依赖 | 可重复构建 |
| IOS02 | 领域 | 全部合法/非法状态迁移，完成/已读/委托持续分离 | 非法迁移拒绝 |
| IOS03 | repository | 同事务、保存失败rollback、随后成功commit与磁盘重开 | 失败脏数据不泄入后续save，无LocalCommit伪成功 |
| IOS04 | 持久化 | 终止并重启；用户记录、草稿、文档版本保留 | 数据一致 |
| IOS05 | 迁移 | 前一版样本升级、失败、fixture升级 | 不丢用户数据 |
| IOS06 | 隔离 | 两profile、深链旧ID、导入权限 | 不串数据/不生效外部权限 |
| IOS07 | 导航 | 每模块适用主路径、返回/关闭/刷新/重复点击 | 无空壳/死路/重复对象 |
| IOS08 | provider | 显式成功终态/无终态EOF/失败/取消/迟到/unknown | EOF不冒充完成；模拟标记贯穿 |
| IOS09 | 定时 | 时区/DST/暂停/应用关闭恢复 | 真实本地规则，无伪后台历史 |
| IOS10 | 文档 | 固定版本读回、并发编辑、缺blob | hash/版本/冲突正确 |
| IOS11 | 助理 | 委托→事件→run→成果→继续/停止 | 本地fixture全链路可重复 |
| IOS12 | 安全 | 旧审批、目标/版本改变、撤销边界 | 未授权真实工具调用0次 |
| IOS13 | 删除 | suppression/epoch、在飞返回、缓存/旧源重抽取 | 删除不复活 |
| IOS14 | TTS | 中文开始/结束/停读、版本切换、耳机/中断 | 实际音频与状态一致 |
| IOS15 | 权限 | 启动/打开语音/朗读，权限请求计数 | 自动请求0次 |
| IOS16 | ASR | 本地能力不可用、拒绝、partial/final/edit/abort | 不自动云fallback，不覆盖改字 |
| IOS17 | 语音竞态 | 后台迟到final、旧音频、停播后文字 | 不误发/复活/误取消 |
| IOS18 | 无障碍 | Dynamic Type/VoiceOver/键盘/中文长文本 | 无关键遮挡、可操作 |
| IOS19 | 真实性 | 本地/模拟/真实来源在列表、详情、导出一致 | 不虚报云端成功 |
| IOS20 | 成本/隐私 | 原音/正文不进日志，未连provider无网络请求 | 0次未授权传输 |

单元测试用XCTest或与已安装工具链相容的Swift Testing；UI测试用XCUITest，固定fixture profile/clock，不依赖真实网络或系统已授麦克风权限。持久化测试至少包含disk-backed临时store重新打开，不能只用in-memory store声称重启通过。迁移样本文件与expected数据进入测试资源。

模拟器构建推荐命令模板（由实现者先替换实际project/scheme/UDID）：

```text
xcodebuild -list -project CatpawM.xcodeproj
xcodebuild -showdestinations -scheme CatpawM -project CatpawM.xcodeproj
xcodebuild -project CatpawM.xcodeproj -scheme CatpawM -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project CatpawM.xcodeproj -scheme CatpawM -destination 'platform=iOS Simulator,id=<verified-UDID>' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults.xcresult test
```

这些是计划中的命令模板，不是已运行结果。实际工程名、scheme和SDK由项目确认；不得猜UDID。真机签名/安装、TestFlight/App Store发布、账号登录与付费开发者资格另有授权和环境要求，不属于模拟器构建通过的含义。

## 11 发布门槛与不阻塞的工作

B0原生基础版的完成门槛：全部已证实模块主路径有实际代码；数据重启保留；fixtures/真实边界清楚；IOS01–13、15、19、20适用部分通过；主要iPhone尺寸运行截图和路径记录；语音真设备未测项单列。

M4 / WP6语音完成分开报告：原生TTS已实现/构建/实际输出；ASR capability检测；真实on-device识别是否跑通；无权限路径；是否明确模拟。不能因为系统有Speech框架就打勾“真实语音对话”。

R1完成还要求实际后端连接与认证、持久调度、真实来源、成果证据、停止/删除/权限/回执端到端通过。后台缺少时继续把B0与原生能力完成，报告真实Agent部分的具体依赖，不停所有开发，也不谎称真实Agent完成。

基础复刻与iOS方向已由用户确定，不再列为待决定。待校准而不阻塞的输入：本机Xcode/Simulator、31图矩阵、最低iOS目标、bundle/scheme实际名、真实provider可用接口。没有用户必须当场决定的低价值问题；先按本文默认实现可逆部分，必要权限/账号/部署再向用户明确提出。

## 12 实施者交接

开始编码前读最新产品/主技术规格、图证据矩阵与本计划，并记录一次简短plan：工作包顺序、首个可运行里程碑、测试命令、未验证假设。随后实际创建/编辑原生工程，按M0–M6里程碑及WP0–WP7工作包迭代，每完成一组运行构建/测试。

反馈要包含：实际改动文件与模块、已跑命令和结果、运行截图/设备、下一步、真实后台或权限阻塞。计划、代码、构建、运行、真机音频与真实后端分别记账；不能只交设计文档，也不能以没有宿主源码为理由只保留占位入口。

