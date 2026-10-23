# OpenDots 代码复读与小咪决策增量

日期：2026-10-13（Asia/Shanghai）。固定来源：`CopilotKit/OpenDots@625452e06cde74cb25b0ce319e2c1be0488f5a5f`。本次直接读取既有完整 clone，`git rev-parse HEAD` 与固定版本一致，`git status --short` 为空。该版本与[前次评估](../../research/openmuse-opendots-copilotkit-assessment-2026-10-13.md)相同；下面是深入实现后的判断细化，不能表述为上游新提交或新功能。

**保留 SwiftUI＋现有 Supabase 为唯一产品和数据底座。OpenDots 对“成果持续编辑、审批回执恢复、权限变化停止执行、电脑监督”有实质参考价值；完整应用、SQLite runner 和 MCP 审批服务均不宜直接移入小咪。** 最值得新增的复用候选是版本编辑的状态机和过期响应保护；审批与调度应保留设计思路，并按小咪既有合同补齐语义。

本轮只有静态源码与测试代码阅读，没有启动模板、安装依赖、执行测试、调用模型/MCP/Intelligence、连接真实账户或部署。测试源码证明作者写过相应断言，不证明本次运行通过；任何上游 live 声明也不关闭小咪的验收。当前产品进度仍只见 [master-plan](../status/master-plan.md)。

## 读取范围与真实依赖

读取入口包括 `package.json`、`LICENSE`，server 的 `index/app/platform/store/runner/workspace/dot-agent/headless`，MCP `connections/connection-store/connection-routes/connection-tools`，Pages `pages/page-service/page-tools/page-routes`，`learning`、computer service/store/tools/routes 与部署来源，以及 client 的 `App/Chat/ChatTranscript/ConnectionActionCard/PageReviewCard/PageDocument/PageConversation/SpaceWorkspace`、autosave/snapshot/request 控制和相关测试。

OpenDots 是 React 19＋Vite＋Tiptap 的响应式 Web 应用，服务端为 Node 24＋Hono；依赖包括 CopilotKit 1.75、TanStack AI、MCP SDK 和 Playwright。业务记录用 `node:sqlite`，真实会话通过 `CopilotKitIntelligence`。`Platform` 无 Intelligence key 就不建立 runtime；`createConversation/history/turn` 均要求 readiness。固定 owner identity 和 owner token 适合个人 self-host 模板，并非 Supabase 多租户实现。[manifest](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/package.json)、[SQLite store](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts#L1)、[runtime / identity](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/platform.ts#L49)、[owner middleware](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/app.ts#L38)。

据此，本轮没有理由把 Swift 主界面换成 React，也没有理由为了使用模板新增 Intelligence 作为第二套聊天权威。这是依赖和当前预算约束下的工程判断；不代表 CopilotKit OSS 必须使用 Intelligence。

## 对前次结论的六项细化

| 前次粗粒度判断 | 本次代码事实 | 对小咪的决策更新 |
|---|---|---|
| MCP 有精确审批和一次执行 | 精确参数保存在 server；但动作唯一键为 `(threadId, toolCallId)`，`approvalId` 只是普通列，审批本身没有消费状态 | 继续借鉴精确 proposal 与回执读取；避免把上游幂等声明扩张成“同一批准永远仅一 effect”。小咪以稳定 effect/approval identity、版本与数据库约束执行 AF-A09/10 |
| 关页面后可恢复审批 | 卡片先 GET server action，完成后可只补 `respond`；但拒绝只送 HITL response，server 没有 denied 记录；进程崩溃留下 running 未见专门恢复 | 原消息/待办需要持久 decision；“已执行，待续聊”与“未决，待核查”是不同状态，不能只给一个 Retry |
| 后台 runner 可以做 schedule | 固定版本实际从 Node timer 每秒领取 SQLite task，并在原 Intelligence thread 执行；headless 没有 client HITL tool | 主动执行不能依赖客户端注册审批 UI；需要 server-owned waiting_approval＋Inbox，再由手机批准恢复同任务 |
| Pages 支持 revision | 实现同时保护保存中再编辑、远端更新冲突、页面切换迟到响应和显式删除 tombstone | 这是新增最优先参考：先用于现有 Artifact 继续修改/版本/回原对话，不引入完整 Spaces 产品 |
| Dot/global memory 可作为记忆参考 | 每 Dot 只有 allowed 开关；实际注入同一全局 `store.memories()` 文本列表。Learning container 固定到 thread 并交外部 SDK | 不能称为“分 Dot 记忆隔离／自动学习已实现”。保留小咪来源、scope、revision、删除 tombstone 与迟到 job 防复活要求 |
| OpenBot 能作为电脑执行层 | OpenDots 已固定 OpenBot revision 并作按 Dot token 的受控 patch；gateway 有权限、身份、接管、超时及审计 | 电脑监督契约可提前设计；gateway/容器托管仍是候选，不能绕过新增计算预算 0 和 provider/region 确认 |

上表具体事实与推断依据展开如下；不假定小咪当前代码已有同样缺陷。

## 审批：可借鉴的路径与不可继承的保证

1. `connectionTools` 重新解析工具权限；需要审批时仅创建 server proposal，不执行 MCP。Owner 的 POST 从存储读取连接、真实工具名、参数；客户端传入新参数被严格 schema 拒绝。工具禁用或连接删除会使旧 proposal 无法执行，TTL 为一小时。这个职责分离值得保留。[tool gate](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-tools.ts#L24)、[exact stored call](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-routes.ts#L70)、[TTL](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/shared/connection-types.ts#L37)。
2. 卡片展示 server GET 回来的精确参数，恢复时按同 toolCallId 查询回执；已完成时“Continue conversation”只补聊天结果，无需再次调用工具。它还检查回执 `approvalId` 与当前卡一致。小咪的审批详情和已完成 effect 可采用相同用户路径，以真实 server object 驱动原生 UI。[ConnectionActionCard](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/ConnectionActionCard.tsx#L45)。
3. **一次执行的边界较窄。** SQLite PK 只有 threadId＋toolCallId；`claimAction` 对该键 `INSERT OR IGNORE`，同 approval 可以从源码上提交不同 toolCallId，存储层未见 approvalId 唯一约束或 consumed 状态。路由没有查询 Intelligence 中该 toolCall 与 proposal 的固定绑定。由此推断，“一个卡片重复点击”的去重不能等价“一个批准在所有新卡和重启中只执行一次”。本次没有运行该路径，也不声称已实测重复副作用。[schema / claim](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-store.ts#L14)、[POST identity](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-routes.ts#L113)。已有测试覆盖相同 tc1 重试、额外参数拒绝，以及同 tc1 不同 approval 冲突；不将这些断言当作上述更宽保证。[tests](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/tests/connections.test.ts#L261)。
4. **批准版本与 unknown 仍需小咪自己补全。** Proposal 未保存连接的 updatedAt/权限 fingerprint/目标对象 revision；POST 仅验证工具仍启用。调用默认 60 秒时限；transport 异常统一转换 `isError:true` 并 `finishAction(...done)`，无法区分“服务端明确拒绝”与“副作用可能已发生但回执丢失”。动作表只有 running/done，无 crash reconciliation；拒绝只走 client `respond({approved:false})`。这些都不足以继承 AF-A09/10 的版本、持久拒绝和 outcome_unknown 要求。[approval fields](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-store.ts#L104)、[call error conversion](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connections.ts#L281)、[done persistence](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-routes.ts#L145)、[client decline](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/ConnectionActionCard.tsx#L99)。

因此建议复用审批 DTO、权限再解析、server 参数展示、GET 回执再续聊这些机制；小咪的 Approval/Effect/Run 继续作为唯一 authority。连接器新增是后续能力，当前本地 EventKit 等真实动作也适用同一原则。

## 调度、恢复与记忆：模板能力的实际上限

`Runner.start()` 每秒 tick，单 runner 同时只运行一个 task；一次执行最多 90 秒，SQLite claim 为三分钟 lease。过期 task 和 graceful shutdown 都变 interrupted，并要求用户检查已完成 effects 后重新 run；没有自动从 checkpoint 接续。`owns` 仅查 running 与 lease identity，没有直接校验 leaseUntil；这是不能机械翻译成小咪 PG 多实例 fencing 的另一个细节。[Runner](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/runner.ts#L55)、[claim / owns / finish](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts#L207)。

Recurring task 是成功完成后 `nextRunAt = finishAt + intervalSeconds`，最短 60 秒；失败后成为 failed，不再自动 due。它不是固定本地时区日历任务，也不是 change monitor、无变化静默或失败退避实现。实际 `index.ts` 给 runner 注入 executor，调用 `platform.turn`，最终存 `{text, sources:[], sample:false}`；上游旧 research executor 存在不能证明当前 scheduled result 保留结构化 sources。小咪 AF-A12/13/CP-02 的 due identity、时区、终止条件、baseline、变化去重、退避与真实证据继续独立实现。[repeat semantics](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts#L186)、[scheduled executor](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/index.ts#L72)。

Headless 使用 Node-compatible IntelligenceAgent，在原 thread 加带 scheduled 标记的新消息，再从当前 turn 的 newMessages 读取最终 assistant 文本；这能借鉴为“主动更新归原会话，不能拿旧回复当新成果”。但该 headless run 未注册 client review tool，`connectionTools(...approvals:false)` 遇到 gated 工具返回 unavailable，不产生可持久等待和恢复的后台审批。小咪必须把等待状态放在 server Task/Approval，而不是等待某个 React/Swift screen 被挂载。[headless](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/headless.ts#L40)、[client tools filter](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/dot-agent.ts#L277)、[no client approval behavior](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-tools.ts#L29)。

Memory 只有 id/text/createdAt，CRUD 为手动文字；全局和 Dot 的开关决定是否把同一全局文本列表注入 prompt，并不按 Dot 分区。没有来源 thread、确认 revision、提取 job、墓碑或 conflict 结构。Learning 则是 thread 创建时固定 containerId，由 Intelligence selector 和 learnedSkills SDK 读取；不能把 container 配置/UI 当作开源的完整自动记忆系统。[memory schema](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/shared/types.ts#L54)、[memory injection](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/dot-agent.ts#L303)、[manual routes](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/app.ts#L209)、[frozen thread learning](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/workspace.ts#L241)、[selector](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/learning.ts#L10)。

## 新增最优先借鉴：成果编辑与异步界面状态

OpenDots Pages 对小咪当前“成果可打开、继续改、重开一致”有比角色列表更直接的帮助：

- **版本冲突不覆盖草稿。** `expectedRevision` 是 server patch 必需字段，SQLite transaction 校验再更新 revision。`PageAutosave` 区分 saved/dirty/saving/error/conflict；保存中再次输入保留新 draft，迟到保存不会把新输入覆盖；远端更高 revision 转 conflict。小咪的 Artifact revision 和继续修改可以移植状态算法到 Swift，server 用现有 PG CAS；无需引入 Tiptap。[server revision](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/pages.ts#L202)、[autosave](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/editor/autosave.ts#L55)。
- **把异步回包绑到当前对象与 generation。** 页面聊天按 pageId＋dotId scope，切换后旧请求结果不会开错页面；snapshot merge 只接受更高 revision，显式本地 tombstone 拦住旧轮询复活已删页面。小咪 conversation/task/artifact detail 同样应有 objectId＋revision/generation 保护。该小模块是适合直接读算法、单独移植验证的候选。[PageChatRequests](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/page-chat-requests.ts)、[snapshot merge](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/page-snapshots.ts)。仅客户端 tombstone 不能证明跨设备删除一致性，小咪仍需 server deletion identity。
- **保存后续聊与已删成果是显式状态。** Reviewed-page 的内容快照和 receipt 在同 transaction 持久化；内容变更要求新 review；删除 page 后保留 receipt，避免重试批准重建成果。卡片恢复时区分“已保存”“已保存后删除”“稿件变化”“待核对”，且可续聊。[review transaction](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/pages.ts#L156)、[retain deleted receipt](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/pages.ts#L302)、[restore route](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/page-routes.ts#L8)。这个内部数据库原子写入模式比远端 MCP 调用有更强可核对性，不能混为同一种 exactly-once 保证。
- **成果与原对话双向可达。** Page 存 sourceThreadId，详情有 Open source conversation；按 page＋Dot 复用持久 thread；启动 page chat 前 flush 保存或解决冲突，模型工具修改前要 read 当前 revision。iPhone 应体现为成果详情→继续修改→带当前成果版本的同任务对话，而非复制桌面编辑器＋聊天双栏。[PageDocument](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/PageDocument.tsx#L98)、[PageConversation](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/PageConversation.tsx#L52)、[persistent page thread](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/page-service.ts#L46)、[read/edit tools](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/page-tools.ts#L70)。

这些改善细化已有 AF-A08/09/10/16、AF-U06/07/08/12 与 CP-01，不新增“完整知识空间／多 Specialist 编辑器”的强制范围。

## iPhone 信息组织与交互：借鉴职责，不照搬页面

`App.tsx` 为 chat/tasks/memories/space 四类工作区，侧栏展示 Dots、Spaces、Threads、Scheduled & activity、Memories、Settings，桌面另有 icon rail 与 computer result pane；移动 Web 把导航改为 drawer/scrim。这个代码说明不同职责和入口确实独立，支持小咪的 conversation-first＋侧栏／原生详情路线；不意味着首屏需要展示所有技术入口，也不证明原生交互已验。[navigation](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/App.tsx#L306)、[work areas](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/App.tsx#L474)。

`Chat.tsx` 的 send 在 running 时直接拒绝，不是后台队列；draft 是组件 useState，未見逐 thread 本地持久草稿；`scrollIntoView` 在消息数或 running 变化时无条件执行，未见 bottom-anchor 检查。因此这些 Web 行为不应替代当前 UX-1 的轻量队列、保留草稿、阅读不跳要求。浏览器 IME Enter guard 可作语义参考，Swift marked text 必须原生验证。[send / scroll](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/Chat.tsx#L135)、[IME helper](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/chat-composer.ts)。

工具卡采用受控 registry 与 HITL schema；普通聊天保留正文，调度消息另标 Scheduled，内部 voice receipt 标记只控制渲染、不给权限。MCP `normalizeResult` 把非文本 content 转 omitted，既没有真实图片输入能力也没有富结果 schema 保真保证。小咪六类 SwiftUI 卡仍绑定版本化真实对象，对未知 kind 文字降级；图片、来源和 artifact 元数据不能依赖这个归一化函数自动补齐。[registered cards](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/Chat.tsx#L177)、[timeline rendering](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/ChatTranscript.tsx#L9)、[MCP normalization](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connections.ts#L96)。

## 电脑接入：边界先行，托管仍为候选

OpenDots 的电脑是既有 OpenBot service/supervisor 的 gateway，不是新造的一套电脑。部署文档固定 `OpenBot@b6932d31a8d6e7896c15139dfc27a6c6911deb27`，保留 MIT，并受控修改 supervisor 的子进程环境：每 Dot 使用 HMAC 派生 token，主 computer/supervisor token 和模型 key 不进电脑。源码按 Dot/container/network identity 核对 endpoint；工具输入限制相对 workspace 路径，browser click/type 需 fresh ref＋snapshotId。[pinned dependency / patch](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/deployment/computers/README.md)、[gateway identity](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/computer-service.ts#L144)、[typed inputs](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/shared/computer-types.ts#L33)。

`human_*` 从模型工具注册中排除；take/release 是 owner 路由，handoff 状态含 holder/requested/transitioning/resumeSnapshotRequired；执行中每 50ms 检查权限并取消，审计记录 pending/succeeded/failed。可借鉴“App 监督入口≠task worker≠sandbox”、权限分 browser/files/shell、交回后刷新快照、动作审计的接口和体验。[tool registry](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/computer-tools.ts#L10)、[owner controls / revoke](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/computer-service.ts#L260)、[audit](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/computer-store.ts#L27)。

但 gateway audit 未绑定小咪 task/run/effect/args hash，没有 outcome_unknown 或持久成果版本；远端取消/超时后审计失败也不能证明副作用未发生。这里只给 AF-C01–03 的后续 adapter 候选和验收输入，不证明云电脑恢复、成本、空闲释放、多实例隔离或托管通过。新增计算预算 0、既有 Supabase 优先、公开网页＋文件且无第三方登录的已确认范围不变。

## 建议交给当前方案的具体增量

| 优先级 / 现有切片 | 可采用的设计或代码候选 | 采用前最小核验 |
|---|---|---|
| S03＋D30 | Approval 卡先读权威 proposal/receipt，已执行后只补续聊；server 等待审批，不依赖客户端 HITL | 同 approval 新 toolCallId、拒绝后重开、改连接/对象 revision、请求超时、server 崩溃、手机离线等待；AF-A09/10＋U07 |
| S03/S07＋D30 | `PageAutosave`、`PageChatRequests`、`mergePageSnapshot` 算法移植为 Swift 状态控制；Artifact PG expectedRevision | 改稿期间旧回包、跨页切换、远端更高 revision、删除后的旧 poll；AF-A08/16＋U08/12＋CP-01 |
| S05＋D40 | scheduled source 标记、原 thread 的主动结果和当前 turn 文本校验 | 手机/Mac 离线、同 due 去重、pending approval 回原任务；继续用小咪 monitor，不复制 interval runner 当 AF-A12/13 实现 |
| S04＋D40 | 将全局 memory 与 external learning 清晰区分在产品设置与能力状态 | 来源/scope/版本、确认、更正/忘记、迟到 job；AF-A11＋U09；不新增 Intelligence 学习依赖 |
| S08 提案 | OpenBot typed gateway、按对象权限、fresh snapshot、接管和审计 | 资源/provider/region确认后才实施，补 task/effect/unknown/成果和成本/空闲释放；AF-C01–03 |

没有导入上游实质代码。若将来复制这些候选，应为对应版本建立单独 manifest/受控差异，并保留原 copyright＋MIT；现有 frozen OpenMuse manifest/patch 不变。[OpenDots LICENSE](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/LICENSE)。本轮不改变当前模型路由、不追加真实设备/模型试验、不创建新服务或新产品范围。
