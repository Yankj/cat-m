# OpenBot 源码核验与 cat 决策输入

核验日期：2026-10-13。固定源码：[CopilotKit/OpenBot@6d86ba47369c46e1216cbf9f4ee4ce4840d4db90](https://github.com/CopilotKit/OpenBot/tree/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90)。公开源码归档 SHA-256：`db9df5f4f54f207ed0f14c1784612a46a129bf529bbe611f7e61c853ac4628e2`，仅保存在忽略的 `build/research-copilotkit-20261013/OpenBot/`。根 `LICENSE` 是 MIT、Copyright (c) 2026 CopilotKit，SHA-256：`6d35a6bb107ae508da34636387f6208e75a6938e797bc0d5bfa9489d2ca95bad`。本次阅读实现、schema 和部分测试源码；未安装依赖、运行 OpenBot、请求模型、接入账户或部署。测试文件的存在是设计证据，不能作为本次通过记录。本文提供研究建议；当前状态仅在 [master-plan](../status/master-plan.md)。

## 判断

OpenBot 最值得补入 cat 的是**完整产品控制面和异常路径的参考**：持久审批、精确动作回执、后台工作领取、持续责任、可恢复待答问题，以及有权限和能力检查的 UI 卡片。它进一步支持现有 SwiftUI＋Supabase＋受控 OpenMuse worker 的方向；本次没有理由整仓替换，或修改现有模型供应商。

关键限制是 OpenBot 的运行时**强制依赖 CopilotKit Intelligence**。`copilot.ts` 实际使用 Intelligence 存放持久线程、记忆和 learning；`config.ts` 要求 Intelligence API URL、gateway WebSocket URL 和 API key，缺项拒绝启动。仓库 MIT 许可不等于该服务随源码附赠，更不证明部署符合新增计算预算 0。[运行时](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/copilot.ts#L67)、[启动合同](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/config.ts#L936)、[LICENSE](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/LICENSE)。

下面“建议”均是根据源码作出的 cat 工程判断，不是上游保证或已实施变更。AF-R03/05/07/08/10 已覆盖其中很多原则，更新应细化验收动作，避免再建一套 task/action/store。

## 1. 实际系统边界

| 层 | 源码实际行为 | 对 cat 的含义 |
|---|---|---|
| 用户端 | Web 是 React/Vite/TanStack 与 CopilotKit React；另有 Expo/React Native mobile 和桌面目录 | 没有可直接导入的 SwiftUI 主界面；参考交互与 typed payload |
| Agent 运行 | 内置 `BuiltInAgent`；外部 `HttpAgent` / Mastra 通过 AG-UI 接入；原生工具由服务端校验和执行 | AG-UI 是互通边界，不能替代业务授权、receipt 与持久调度 |
| 对话与记忆 | Intelligence 是必需服务；本地 Postgres 另存业务、审批、事件和工作 | 保留 cat Supabase 单一权威消息/事件/业务存储，不引入双重权威 |
| 后台工作 | Postgres `work_items`＋租约队列；常驻 worker 或 sweeper 领取工作并调用服务端 runner | 借鉴 SQL 和恢复规则；常驻 Bun loop 不能原样当作 Edge 请求函数 |
| 电脑执行 | computer provider 对接 shared、Docker supervisor 或 Kubernetes Sandbox；Playwright Chromium、文件、shell 独立进程 | 资源、隔离和托管仍是单独决策；源码不会提供免费计算资源 |

依据：[app manifest](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/package.json)、[mobile manifest](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/mobile/package.json)、[server manifest](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/package.json)、[worker](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/worker/src/index.ts)、[provider](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/computer/provider.ts)。

`agents/plan-model.ts` 的“plan”指 ChatGPT/Claude 订阅模型传输选择，不是任务计划引擎。它读取桌面认证文件或 OAuth 并依赖指定 harness；不能误列为 cat 免费模型替代方案。[实现](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/agents/plan-model.ts#L30)。

## 2. 审批与副作用：借鉴完整恢复语义

OpenBot 的 `ApprovalAction` 带 actor、bot、toolRef、effect、scope、args、target、run/thread/tool-call identity 与 action digest；`ApprovalContinuation` 保存原消息、state、context、forwarded props 和 initiator。请求由 owner/run/toolCall 唯一约束，重复打开会检查 digest。审批决定和 `approval.resume` 工作项在同一数据库事务写入，客户端断开不必丢失批准意图。[类型](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/types.ts)、[schema](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/db/schema/approvals.ts)、[store](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/store.ts#L179)。

恢复时重新解析目标、检查当前权限与 digest，再从 approved 原子转 consumed；保存结果后把确定性 `approval:<id>` 工具消息继续送回原线程。consumed 但没有 result 表示动作可能已经发生：返回结果未知，避免重放。拒绝、失效授权、耗尽恢复次数都会给原对话一个明确结果，避免永远停在 approved。它实现的是有记录的受控执行与保守恢复；不能据此声称任意外部副作用获得普遍 exactly-once。[resume/abandon](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/service.ts#L502)、[executor](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/execute.ts)。

崩溃窗口要具体保留：consume 成功后、真正工具调用前崩溃，也会保守判定未知；本地状态无法证明外部动作已经发生或没有发生。result 已落盘、continue 尚未完成时，恢复可能再次调用 continuation；`approval:<id>` 只是稳定 identity，交付端仍须验证去重。工具异常被记录为 error，不能把网络错误自动解释为“外部无副作用”。通用 work queue 的 lease/attempts 也不能填补外部系统缺少幂等键或核对 API 的窗口。[consume/saveResult](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/store.ts#L192)、[执行/继续顺序](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/service.ts#L593)。

建议补细 AF-A08/09/10 与 AF-U07 的验证步骤：

1. 批准后马上离线/杀 App，再进入同一事项，仍显示同一 approval/action；不重新提交另一动作。
2. 工具执行完成、continuation 失败时只恢复消息交付；工具已开始但回执未落盘时显示“结果未知／核对执行结果”。
3. 用户拒绝后 Agent 换 toolCallID 重问等价动作，不能绕过本轮拒绝；改变目标或参数版本须重新审批。
4. 对话卡、任务页和待决列表投影同一批准记录。折叠“浏览器活动／执行步骤”时，待审批卡放在折叠区域外，保证可见。

等价动作和已拒绝检查在 [service](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/service.ts)，卡片共用审批 inbox、折叠外显示在 [inline-approval](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/src/components/approvals/inline-approval.tsx)。上游 mobile 审批页使用工具名与原始 JSON 预览；cat 继续采用人话说明＋范围＋关键参数，不能照搬该视觉布局。[mobile approvals](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/mobile/app/approvals.tsx)。

## 3. 后台工作与持续责任：明确两种重复、两种失败

`work_items` 用 `(kind,key)` 主键、runAt、claimedBy、leaseUntil、attempts、finishedAt、lastError；claim 是事务中的 `FOR UPDATE SKIP LOCKED`，租约基于数据库 `now()`。完成行保留一段时间，防止晚到 offer 把相同 due occurrence 重新创建。offer 区分 queued/already/refused；领取/续租/收尾验证持有者，重试有上限。NOTIFY 用于降低延迟，失去通知仍由 poll 恢复。[work schema](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/db/schema/work.ts)、[queue](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/work/queue.ts)。

routine 明确区分单次 firing 的恢复 attempts 与跨多次 firing 的连续失败，后者用于自动停用并说明原因；暂停跳过不计失败。loop 从上一次工作结束后调度下一轮，避免 setInterval 在长任务期间无限扩大并发。responsibility 则存 goal/successCriteria/progress/subscriptions，事件 owner/source/externalId 和责任/event 各自唯一；等待用户问题/审批后继续回到原责任，不能变成失去责任工具的普通聊天。[runner](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/routines/runner.ts)、[loop](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/work/loop.ts)、[responsibility types](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/responsibilities/types.ts)、[event constraints](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/db/schema/responsibilities.ts)、[question resume](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/approvals/question-resume.ts)。

建议把这些规则落在 cat 既有 Trigger/Task/Run 上：due occurrence 的幂等 identity 在成功后仍有效；跨次失败与单次 retry 分开记；等待用户不是失败；通知重连/丢失只重新读取持久状态。保留 cat 现有 epoch/权限/lease 提交栅栏，不能以复制较短的 OpenBot queue 代码替换它。OpenBot 恢复已 running 的 responsibility 采取保守失败而非盲重放，进一步支持结果未知的产品状态。[responsibility recovery](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/responsibilities/store.ts#L333)、[channel events/resync](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/channels/events.ts)。

proactive engine 是复用同一 headless turn runner 的只读研究，不是第二套无限 loop：限制读工具、suggestions 和候选 memories，来源工具必须在本次成功读过；建议由人选择开始任务。它针对已连接第三方账户，不能直接替代 cat CP-02 的公开网页变化游标、无变化静默和去重实现。建议借鉴来源核验与读写能力收窄，保持 cat 当前无第三方登录范围。[proactive engine](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/proactive/engine.ts)、[limits](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/proactive/types.ts)。

## 4. 智能 UI 与 iPhone 设计

OpenBot 有三条不同路径：编译的 React gallery tools、A2UI 声明式 primitives、编辑/发布的 sandbox HTML/CSS/JS。gallery 提供稳定名称、schema、preview、kind、data-function reads；模型得到的是已发布且允许的组件列表，执行时再次校验。服务端 headless 版本保存卡片调用，使后台没有客户端时仍能完成展示类工具并在下次打开时恢复；选择/批准/表单决策不伪造用户答案，改走 `ask_person` 等待。[gallery registry](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/src/lib/copilot/gallery-registry.ts)、[headless cards](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/components/headless.ts)、[A2UI](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/src/lib/copilot/a2ui.tsx)、[sandbox draft/publication](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/components/sandboxed.ts)。

**设计更新建议：**在现有六类 Swift 卡片合同上增加 capability manifest 与渲染结果语义：卡种/schema 支持、权限、对象 revision 在显示和操作时分别核验；“已保存，打开后可查看”与“已显示给用户”分别表达。后台决策卡持久化为待答记录；客户端不在线也不会让 runner 永久等一个 frontend hook。未支持、已撤权、过期版本降级为可读正文和原事项入口。这细化 AF-R10、AF-A14/17 和 AF-U06/07/08，不增加任意生成代码功能。

数字等事实应来自真实工具结果或 owner-scoped 数据接口；模型可以选择展示布局，不能凭参数生成假业务统计。OpenBot 示例 data functions 读部署级 audit trail，本身没有 cat 的 owner 参数，不能直接复用成多租户接口。[data functions](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/components/functions.ts)。

生成 HTML 的设计 prompt 明示 iframe 不能读取 App stylesheet/theme，需跟随 OS 色彩方案，可能与 App 手选主题不一致；允许 CDN，与 cat 原生主阅读体验和依赖边界不同。不要照搬其 14px 正文、32px 控件建议到 iPhone；保持当前原生字体、44pt 触达、Dynamic Type、A1 图标和已选 tokens。[generative UI prompt](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/src/lib/copilot/generative-ui.ts)。

其 mobile conversation 实际是 POST text/externalId 后 refresh history 的简单 RN 页面；该文件没有文本流消费、图片输入或 gallery/A2UI renderer。因此“有 mobile 目录”不足以把它作为当前 Codex 级 iPhone 体验替代工程。[mobile conversation](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/mobile/app/conversation.tsx)。Web composer 的 queue 是单次挂载内存队列，切会话/刷新会失去待发意图，失败时恢复文字与附件，且排队 corrections 合并为一轮；不能继承为后台送达承诺。可借鉴失败恢复测试，但保留 cat 对独立输入身份及本机持久待发状态的合同。[queue reducer](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/src/components/channels/composer/queue.ts)。

记忆 origin/reviewState/enabled 的分离也值得细化：更正内容不改写原始来源，不自动打开原已停用的记忆；采用 cat 已定义的更正/删除屏障。按条“暂停使用”可列为设计评审候选，不能未经决定扩展当前必需功能。[memory contract](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/memory/types.ts)、[mobile memory](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/mobile/app/memory.tsx)。

## 5. 电脑、文件与隔离：保留提案边界

supervisor 只暴露 botID 对应的 ensure/stop/reset/list，不给 API 任意 Docker passthrough；只有 supervisor 持有 Docker socket。每个 bot 独立 `/workspace` 和 browser profile volume；stop 保留数据，reset 才移除状态。Docker 设置 no-new-privileges、ALL cap drop、PID 上限及 shared memory；memory cap 可选且默认没有 cap，未见该 HostConfig 的 CPU 硬上限。默认普通 Docker 共享宿主内核，runsc/gVisor 为可配置 runtime，不能称默认就是微虚拟机沙箱。[supervisor verbs](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/supervisor/src/index.ts)、[Docker HostConfig](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/supervisor/src/docker.ts#L418)、[memory option](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/supervisor/src/computer-memory-bytes.ts)。

文件工具校验相对路径、词法包含和 symlink 解析并限制读写/download 大小；shell 使用有限环境、timeout 和 output budget，但任意 shell 可以访问容器允许的所有地址与文件。网络过滤代码也承认不遵循 proxy 的 raw socket 需要基础设施隔离。不能把 workspace 检查或 URL deny-list 当成完整 shell 边界。[workspace](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/agent-computer/src/workspace.ts)、[shell](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/agent-computer/src/shell.ts)、[egress](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/agent-computer/src/egress.ts#L177)。

computer gateway 把元素 ref 绑定 snapshot generation 与运行 session，再检查 policy/audit；人接管时关闭动作 admission、等待已开始动作排空，归还后强制新 snapshot。requestID 与 handoff 状态持久化。provider 不知道 session 时有兼容跳过路径；若后续抽取，cat 应先决定未知代际的拒绝/刷新语义，不能无条件沿用弱化检查。[gateway](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/computer/gateway.ts#L466)、[control](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/agent-computer/src/control.ts)、[action barrier](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/agent-computer/src/action-barrier.ts)。

建议后续电脑提案采用 provider 接口＋独立生命周期服务＋task-scoped workspace；首期公开网页/文件只开放明确允许的动作。浏览器登录、密码管理、人工远程接管、任意 shell、SPIRE、远端 agent roster 和企业账户治理属于扩展，当前不实施。Ubuntu/Chromium/Bun/Node image、Postgres、supervisor 和可选 Kubernetes 都需要可持续运行资源；scale-to-zero 只减少闲置消耗，不证明总成本为零。[computer image](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/agent-computer/Dockerfile)、[compose](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/docker-compose.yml)、[sandbox lifecycle](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/computer/sandbox.ts)。

## 6. 复用清单与兼容性门槛

| 候选 | 推荐方式 | 采纳前最小证明 |
|---|---|---|
| `approvals/types/store/service` | 映射既有 Approval/Effect 合同，移植恢复测试语义；先不搬 Node AsyncLocalStorage、Drizzle 全树 | 同一 action digest；撤权/改参数拒绝；并发一次执行；执行后未知不重放；receipt 恢复只一次 |
| `work/queue` 与 `routines/sweep` | 借 SQL 领取/DB clock/保留完成键/次数分类 | 现有 Supabase PG 同 key 多实例竞争、晚到重复、旧 worker 收尾、due+timezone 与本次允许部署边界 |
| gallery/headless manifest | 抽取 JSON schema 与能力/发布概念，用 Swift 原生六卡渲染 | 后台保存后回 App 同 cardID/revision；未支持降级；数据 owner 隔离；操作按 current authority 重新检查 |
| queue/draft 测试 | 转成 Swift composer 的场景，不复制 RN/React UI 与“一次挂载”生命周期 | 切页/失败/停止恢复文字和附件且不重复发送；排队状态诚实，不声称服务已受理 |
| watchdog 思路 | 借鉴首事件无响应、模型静默、消费背压与用户等待的分类 | 固定 cat 的 SSE/JSON Content-Type、合法 terminal event、不把背压或审批等待当模型故障 |
| computer provider/control/workspace | 托管确认之后再抽取 HTTP seam、request identity、隔离测试 | 明确零新增成本资源/区域，session代际、路径/symlink、私网与metadata、停止/恢复/receipt；无额外登录或工具 |

watchdog 监视外部 Agent HTTP 流，而 OpenBot 面向浏览器的 Intelligence 响应是 JSON＋gateway WS；不能直接复制其 transport 条件到 cat。上游注释还保留 AG-UI 0.0.57，manifest 已为 1.0.1，必须以固定依赖和互通样例核验。[stall guard](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/src/channels/stall-guard.ts)、[server manifest](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/package.json)。

可优先阅读/转用的故障用例：[approval tests](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/tests/approvals.test.ts)、[work queue PG tests](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/tests/work-queue.integration.test.ts)、[headless schema mirror tests](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/server/tests/headless-components.test.ts)、[queue tests](https://github.com/CopilotKit/OpenBot/blob/6d86ba47369c46e1216cbf9f4ee4ce4840d4db90/app/src/components/channels/composer/queue.test.ts)。这是下一步兼容性试验清单，不是新增本轮验收通过。

如实际复制实质代码，单独记录 upstream commit、路径、hash、适配补丁并保留 2026 CopilotKit MIT notice；不修改现有 OpenMuse pinned manifest 和 controlled patch。当前只记录源码研究输入，不导入任何 OpenBot production 文件、不新增依赖、不创建 Intelligence/电脑资源，不改变 AF-1 的同版验收条件。
