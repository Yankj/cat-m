# 育儿核心本地候选交接 · 2026-10-23

本记录说明如何接续本地候选；实时状态在 [master-plan](../../status/master-plan.md)，定位、交互、价值评审及阶段路线见 [规格](../../design/family-companion/parenting-core.md)，逐项验证见 [独立审查](parenting-core-review.md)。

## 位置与来源

- 工作树：`/workspace/mimi-parenting`；本地分支：`feat/parenting-core`。
- 基线：main `4ec8118b796f7c983ae4436268441c3c9d3d33db`，含已合并 PR #122 / `ba560b9686e5b2dd8642dd75d351e72418659ecb`。最终本地提交和逐文件 SHA-256 由交付清单记录；没有推送、PR、合并、部署或发版。
- 原 `/workspace/mimi` 的 `work` 分支和文件未改；旧 `/workspace/cat-m` 及其他工作未改。内部 Bundle ID、URL Scheme、旧存储键和既有协议身份保留。
- PR #120 只读来源为 `origin/pr-120-audit` / `e2703e5c28f9c27ca9dd729b2d632acda12c5d48`。没有 checkout、导入或合并；未来需逐文件解决 App/项目/品牌契约冲突。
- 本地交付包：`/workspace/mimi-parenting-delivery.tar.gz`，同目录 `mimi-parenting.patch`、`mimi-parenting-manifest.json`。包只含本轮明确路径、补丁、清单与合成验证证据，不包含 `.git`、凭据、生产配置或真实家庭数据。补丁相对上述基线。

## 代码入口

以下原生路径相对 `apps/ios-conversation/`。

| 文件 | 负责内容 |
|---|---|
| `Sources/App/catApp.swift` | 实际认证入口接育儿首页，保留账号隔离与退出接线 |
| `Sources/App/NativeAuthApplicationModel.swift` | 三处真实认证配置注入惰性提取 service factory |
| `Sources/Features/Parenting/ParentingHomeView.swift` | 今天、孩子与成长、记录；真实空态、确认/调整/取消/完成、更正删除与原位 AI 状态 |
| `Sources/Domain/ParentingWorkspace.swift` | 目标/安排/家长记录独立模型、引用校验、原子完成 |
| `Sources/Persistence/ParentingWorkspaceStore.swift` | 账号分区、加密、持久化、revision CAS、重复操作及 epoch 围栏 |
| `Sources/Features/Parenting/ParentingWorkspaceModel.swift` | 保存成功后才发布，失败保留原快照 |
| `Sources/Domain/ParentingIntakeDraft.swift` | 本次请求/回复绑定、严格 JSON、时间来源校验 |
| `Sources/Domain/ParentingInlineIntake.swift` | 只整理、恢复及删除 typed 合同 |
| `Sources/Features/Parenting/ParentingInlineIntakeModel.swift` | 原位请求、许可、重试/只读核对、取消、候选采用、恢复和删除状态 |
| `Sources/Persistence/ParentingIntakePersistence.swift` | 隔离加密 journal/recovery、无原文清理队列、账号与路径代次围栏 |
| `Sources/Providers/NativeParentingIntakeComposition.swift` | 复用现有模型 transport，隔离 conversation、禁自动重连及 outbox |
| `Sources/Providers/NativeChatHTTPBackend.swift` | 专用版本路径、purpose 校验、受限响应事件与删除回执身份校验 |
| `Tests/ParentingWorkspaceTests.swift` | 合成领域/磁盘/控制器/恢复/清理 XCTest；全部尚未运行 |

旧 `ParentingAIIntake.swift` 聊天往返桥及工程引用已移除。项目静态核对为 238 个 App source memberships、4 个 targets。UIStrings 有 2075 个双语资源，嵌套育儿文件及动态错误键纳入审计；这不等于原生编译通过。

后端实际入口为 `services/edge/supabase/functions/_shared/api.mjs`、`core/src/chat-service.mjs` 和新增 `parenting-intake*.mjs`。`services/edge/test/parenting-intake-http.test.mjs` 运行真实 API/ChatService，边界用 mock provider/repository；不调用生产服务。

## 已实现的纵向切片

家长建立孩子及轻目标，在“交代一件事”输入原话、选择关联目标；显式“让小咪整理”复用既有认证、路由与许可，仅发送显示的原话及时间/时区。原位等待、错误、重试、取消和恢复均有明确状态。严格完成回复只生成可编辑候选；采用、保存待确认、确认安排分开。今天可调整/取消，家长完成后生成独立记录，回顾沿用 childID/goalID，无需重选关联或重抄标题。观察有原话、录入/更正时间并可改删，不把模型推测写成事实或教育医疗建议。

服务端限定由代码断言执行：无工具、记忆提取/召回、主动动作、GenUI 或设备能力；拒绝额外上下文及附件。专用请求不可经普通聊天路径读取/变更。未知结果仅查询原请求，不能开始新请求或自动补发。旧部署返回明确不支持，不回退聊天。

## 原话和临时记录的保存边界

| 位置 | 内容与保留 | 删除与限制 |
|---|---|---|
| 本机隔离 `journal.sealed` / `recovery.sealed` | 加密原话、候选/事件及恢复身份；最多 24 小时可恢复，无 auth token | 采用/取消/显式删除清除；过期下次打开/操作清理，无后台准时物理擦除承诺 |
| 本机 `cleanup.sealed` | 仅账号分区、conversation ID 和 pending；无原文、prompt、candidate、token | 清理失败可重试并阻止新整理；成功删除条目 |
| 服务端持久层 | 标识、哈希、许可引用及脱敏元数据；无原话、prompt、回复或推理正文副本 | DELETE 撤销/fence 后清理，保留防重放墓碑；现有存储的元数据保留时限未另行改写 |
| 服务端进程缓存 | 临时原话、回复及推理，可读取最多 15 分钟 | 定时/访问过期、DELETE 清理并中止 provider；进程重建后不可恢复正文，不再自动生成 |

加密不能代替最小化。删除临时整理记录不删除表单原话或已保存账本来源；这些内容由家长在表单/记录中另行改删。第三方模型供应商的保留或删除效果未验证，不能承诺同步擦除。取消/删除失败显示待清理，不能报删除成功；路径 generation、账号 epoch 和弱引用缓存阻止晚到首写恢复文件。

## 验证与未完成边界

- 最终 Node 离线回归 **70/70 PASS**（其中新原位提取 13 项），含真实产品逻辑加 mock、canary 最小化、越权、普通路径绕过、重复、取消/删除竞态、冷进程/超时失效、既有许可/租约/内存回归。原 23 项的静态/纯函数/产品加 mock 性质单列在审查，不能当作原生功能测试。
- Linux 没有 Swift/Xcode/iOS SDK/模拟器，54 项新增 XCTest 全部 **NOT RUN**（21 账本、8 解析、25 原位控制器/恢复/清理），无原生编译、UI 运行截图、真实 Keychain/AES-GCM/文件并发或真实模型验证。静态 OpenStep reader 只补缺失 plutil，不替代 SDK。
- 专用后端未部署；当前 App 配旧后端会提示不支持。未经原生编译与同候选服务验证不能声称线上闭环可用，也不能据此发版。
- 本机账本无家庭云同步、系统日历/提醒、多人共享、周期安排、目标生命周期；普通未保存表单不恢复。自然语言临时调整和自动回顾分析未实现，当前从既有安排编辑、按目标关联回顾。图片/语音未新增育儿提取链。
- 原始官网迁出布局、历史冻结源/Goal pin 和旧本地化后半断言仍有基线失败，详见审查；未放宽扫描规则或扩大维修范围。
- 请求子代理模型为 `gpt-6.1-sol / ultra`，无法独立核验 effective runtime；Root 实际模型亦无法核实。

## 在现有 Mac 环境接续

核对清单与哈希，保留原有工作树，使用现成 SDK/依赖运行 `Scripts/validate-project.py`、`Scripts/check-localization.py`、`Scripts/check-source.sh` 及定向 XCTest。先在同候选 mock 服务下验证真实 UI：首次空态、原位等待/许可、缺时间补齐、失败/未知、取消/删除、重复、跨账号、重进恢复及完成回顾；只用合成家庭。核验截图来源和编译产物版本后，再评估既有授权范围内的后端接续，不能复制生产配置、新建凭据或调用生产服务补验收。

推送与草稿 PR 仍由父任务另行等待明确批准。本交接不授予外部发布权限；当前禁止 push/PR/merge/deploy/release。
