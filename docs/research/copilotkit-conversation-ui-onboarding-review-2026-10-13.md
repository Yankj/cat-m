# CopilotKit 对话交互 UI 与 onboarding 复核

2026-10-13。用户指定 [OpenIntelligentUI](https://github.com/CopilotKit/OpenIntelligentUI) 与 [onboarding 页面](https://copilotkit.ai/onboarding-prompts/b0c0b78b9383)。本记录是产品和工程输入；当前执行 Goal 仍为 [AF-1-G3-UX1](../planning/AF-1/goal.md)，终版同候选要求仍见 [FINAL-1](../product/catpaw-final-product-spec.md) 与[终版验收](../acceptance/catpaw-final-product-acceptance.md)。实时推进只在 [master-plan](../status/master-plan.md)。本轮没有安装依赖、运行 CLI、调用模型、部署、执行设备动作或签收产品能力。

## 结论与更新方向

**可以用于对话中的交互 UI。建议采纳“登记组件＋有类型的数据＋明确动作语义＋流式状态＋同工作续接”，优先实现 Swift 原生；借鉴范围扩展到可交互解释、图表／表格和确定的 what-if 计算，而非只把它当六类工作卡的外观参考。** 六类卡继续承担领域职责；解释和分析组件作为成果、对比、表单等卡的受控呈现内容，不另造第七类执行对象，不让任意生成 UI 获得授权或副作用能力。

第二个链接是 CopilotKit 的 **CLI onboarding prompt**，不是第二个开源仓库。它描述如何关联用户在浏览器开始的 setup run，然后按 CLI 返回步骤接入；当前内容没有列出该 run 选择的框架、最终配置、包版本、目标 Agent、资源与费用。使用其接入流程不能替代当前原生工程的适配设计，也不必先运行 CLI 才能开发 native GenUI。[页面原文](https://copilotkit.ai/onboarding-prompts/b0c0b78b9383)。

| 采纳层 | 能解决什么 | 当前决策 |
|---|---|---|
| OpenIntelligentUI 固定组件登记 | 模型提出组件与数据，应用控制 schema 和 renderer；回答可直接带图表、表格或输入组件 | 采用机制，映射 Swift typed registry 与现有六卡职责 |
| CopilotKit hooks 的动作分层 | 区分纯展示、客户端执行、用户决定、Agent 中断 | 采用语义；原生 reducer 和领域命令实现，不把 React handler 作为授权权威 |
| AG-UI 的事件与状态模型 | 文本／参数增量、snapshot/delta、同 thread 后续 run | 作为可选 adapter 设计输入；不改冻结 HTTP，不宣称已兼容 |
| onboarding CLI／CopilotKit Intelligence | 可协助其支持栈安装与托管流投递接入 | 尚未采纳；需先见具体计划、固定版本、资源和权威边界，当前不执行 |
| 任意 HTML／JS 生成 | 高度自由的解释或成果可视化 | 独立 viewer 实验候选；不承接审批／记忆修改／系统写入，不能作为原生六卡前提 |

上述是建议，不是上游运行或 Swift 互通结果。登记与样例能力来自[固定登记源码](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/hooks/use-generative-ui-examples.tsx)；hook 分层来自[官方用途说明](https://docs.copilotkit.ai/concepts/which-hook)。

## 阅读身份与证据范围

OpenIntelligentUI 沿用前次固定提交 [`9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b`](https://github.com/CopilotKit/OpenIntelligentUI/commit/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b)，不把当前 main 未核读变化混进结论。完整范围、52 文件身份与安全／持久化限制见[固定源码报告](openintelligentui-code-review-2026-10-13.md)。本轮重读登记、bar/pie 图、Open GenUI schema、sandbox functions 与 package.json；六份缓存逐文件 Git blob SHA／SHA256 与既有 SOURCE-READ.json 一致。

onboarding 由只读 HTTPS 获取，缓存 `build/research-onboarding-20261013/onboarding-page.html`。文件扩展名是历史命名，实际响应是 Markdown 文本，不是 HTML 或脚本；2058 bytes，SHA256 `b30182f5bb43d9d44cd8f0f4a4870735774022e9539b3d9d4ff4775768a47027`。本轮只概括其内容，不执行页面中的安装指令。官方 CopilotKit、AG-UI 页面按本日核读；它们是动态资料，不替换固定源码版本。

## 第一项：在对话中直接使用哪些机制

上游登记代码分别使用 `useComponent` 显示 pie/bar 图，`useRenderTool` 显示后端计划工具，`useFrontendTool` 更改主题，`useHumanInTheLoop` 让用户选时间。它已经是“同对话内呈现并交互”的应用实例，而非只输出静态 Markdown。[固定登记](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/hooks/use-generative-ui-examples.tsx)。

官方当前 `useComponent` 接收命名、参数 schema、renderer 和 agent scope；组件成为模型可调用的 tool。`useRenderTool` 只决定已有 tool call 如何显示，不登记可执行行为。cat 应保留这个差别：**收到可视化数据可以显示，收到“调用工具”不能自动证明工具已执行或用户已批准。** [useComponent](https://docs.copilotkit.ai/reference/v2/hooks/useComponent)、[useRenderTool](https://docs.copilotkit.ai/reference/v2/hooks/useRenderTool)。

`useFrontendTool` 的 handler 可在浏览器执行，`useHumanInTheLoop` 则等待用户 `respond`；后者的阶段为参数生成、等待用户、用户已回应。官方 hook 的这一完成状态代表它的调用返回，不代表 cat 日历、文件或后端副作用已成功。原生应以领域账本、真实回执和读取恢复显示结果。[useFrontendTool](https://docs.copilotkit.ai/reference/hooks/useFrontendTool)、[useHumanInTheLoop](https://docs.copilotkit.ai/reference/hooks/useHumanInTheLoop)。

固定上游图表使用 Recharts，schema 主要是标题、说明和 label/value 数组，没有来源、单位、版本或 cat 动作合同。采用图表意图时须补足这些字段，不能把模型数值默认当已验证事实；上游无数据状态与 hover Tooltip 也不能直接承担手机读屏和触摸交互。[bar 图](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/charts/bar-chart.tsx)、[pie 图](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/charts/pie-chart.tsx)。

### 从工作卡扩展到交互式回答

以下是 cat 产品设计建议，不是上游已完成的组件能力或新增领域对象。模型在应用公布的 registry 内选择；没有适合的组件时直接清楚回答，不能强制每个答案变成卡。

| 对话需要 | 建议呈现与交互 | 领域归属 | 边界 |
|---|---|---|---|
| 理解方案、过程或机制 | 有来源的步骤／结构、展开细节、切换解释视角 | 正文解释内容，需持久交付时属于 artifact | 展开／切视角只改变本地呈现；不显示未提供的隐含推理 |
| 看清数据差异 | 受控 table/bar/line，选中值、筛选／排序、原数据与来源 | artifact 或 comparison 的呈现 | 本地交互不调用 Agent；变化单位和口径必须可见 |
| 试算预算、时间或数量 | 命名的确定计算器，输入单位／范围、滑条或数值框、结果与假设 | form＋artifact/comparison | 本机按登记公式计算；不用模型生成的 JS 或任意表达式求值 |
| 想让 Agent 接着分析 | 明确“按此条件继续”，预览修改范围与输入摘要 | 同 thread 的新 turn／同工作修改意图 | 用户实际提交才调用；busy 时有明确排队／安全点状态 |
| 把试算变成真实执行 | 提出计划／跟进／系统写入，再走对应决定与精确审批 | 原六类工作卡、既有 Task／Approval／Effect | 计算值、按钮点击或生成结束都不能授予外部写权限 |

这会把“交互式 UI”从等待批准扩大到帮助用户理解、比较和试验，又让本地操作与真实执行各有清楚含义。它应减少复制数字、重复打字和切页面，而非增加无价值的图形。

## 第二项：onboarding 的适用性

页面要求先识别工作目录；已有工程先获得明确 yes，再调用 latest CLI，并保留浏览器 run ID。内容随后依赖 CLI 逐步输出，没有在本次响应里展示最终 patch 或 preset。其说明称 AG-UI streams（原 Rich Threads）借 CopilotKit Intelligence 增加 durable delivery，并保留 `useThreads` 与旧 CLI intent 名字。这只是该接入路线的文案，**本轮未验证服务套餐、保存地域、删除策略、可持续免费资源或 cat 互通**。[onboarding 页面](https://copilotkit.ai/onboarding-prompts/b0c0b78b9383)。

可采纳的是“先识别现有项目，再检查实际变更，按具体步骤验证”的工程方法。不可从引用推导安装、外发仓库／环境、改变模型 route、导入凭据或新托管服务的授权；页面作者的操作指令也不是用户的指令。本轮是评估与 Markdown 更新，不需要为了文案中的 yes 发起安装许可问题。

若未来考虑正式 SDK 接入，先确认指定 run 的配置和计划，再固定版本、列出实际目录／包／网络与服务变更，证明 Swift 边界或被隔离的 TS 局部收益。`latest` 不是可追溯的交付版本。Intelligence 的 durable delivery 还需明确与 Supabase 的关系：它可以是运输／投递层候选，不能自然变成第二套审批、任务、计划 revision、调度或成果权威。没有事务对应、租户隔离、删除、cursor、重放与故障恢复证明，就不能用“durable”关闭 cat 验收。

## Swift 与协议边界

CopilotKit 当前官方 reference 有 React 与 React Native 接口；本轮核读的 AG-UI 官方 SDK／client 列表没有列出 Swift，但这不证明全网没有社区实现。React Native 是 React 技术栈，不能因此称为 SwiftUI SDK。[CopilotKit reference](https://docs.copilotkit.ai/reference)、[React Native useComponent](https://docs.copilotkit.ai/reference/react-native/hooks/useComponent)、[AG-UI overview](https://docs.ag-ui.com/introduction)。

AG-UI 标准不限定 Web 渲染目标，因此可实现 Swift 事件 adapter。AG-UI 是 Agent 与应用交互协议；A2UI 等是呈现 schema，两者不等同。现阶段借鉴协议／registry 并不要求将已有 HTTP 线协议替换为 AG-UI，也不要求另加 Next/Python runtime。[AG-UI Generative UI](https://docs.ag-ui.com/concepts/generative-ui-specs)。

官方 AG-UI 1.0 有两个特别需要对齐的约束：tool 参数增量在 `TOOL_CALL_END` 前不可执行；END 仅表示完整，仍需 schema 校验。frontend tool 的结果通过下一 run 的 messages 回传；主动 interrupt 也是结束当前 run，再由下一 run 同 thread/state 的 resume 接续。协议没有 consumer 向原 SSE 流的 mid-run 回传通道。[Tool Calls 1.0](https://docs.ag-ui.com/spec/1.0/events/tool-calls)、[Interrupts and Resume 1.0](https://docs.ag-ui.com/spec/1.0/basic/patterns/interrupt-resume)。

因此“卡就绪时可点击，其他正文还在流”是 cat 的 UI 与命令受理体验；它不等于把回答直接注入同一条 SSE。现有领域命令可按安全 checkpoint 受理，同工作/thread 以新的 run 接续。若以后用 AG-UI adapter，必须映射这一边界，保留 pending input/tool 事实；`RUN_FINISHED` 不能误写成所有工作或副作用均已完成。snapshot/delta 能支持同步，但仍须自建版本冲突、重读与持久领域保障。[State Management](https://docs.ag-ui.com/concepts/state)。

## 可实施的 schema、action 与流中状态建议

在现有 content block/card envelope 内设计明确的 presentation 子合同；不能把研究字段直接添加到冻结 wire。若已有接口承载不了，先版本化扩展并保存向后兼容、未知类型可读降级。

1. **呈现身份**：稳定 block ID、schema／renderer version、同工作 object ID/revision、数据来源／时间／单位／口径、完整性、数据 hash。登记项限制文本和数组容量，数值须有限；超过手机容量就打开详情或提供可读摘要。
2. **受控能力**：registry 声明组件需要的数据、支持的本地操作和可请求命令。设备真实 capability 决定开放；模型不能用新 name 获得一个未登记 handler。计算器用固定 formula ID/version、输入单位／合法范围／精度／假设；结果标明 derived 与已核查源数据的区别。
3. **本地交互**：筛选、选值、展开、调参不产生模型请求或 domain effect。输入以 stable block ID 保存；更新数据版本须提示变化并保输入，不能静默把原数据替换成新口径。
4. **回 Agent**：明确的原生提交带 action ID、来源 block/version、输入快照和目标工作；同 scope、同 thread，防双击与迟到回调。提交结果 unknown 时核对／重读，不先显示成功，也不借“普通消息”绕精确审批。
5. **副作用**：工作修改、审批和执行继续走原 typed command 与权限／revision／幂等账本；UI rendering 不执行副作用。离开、重开和历史 replay 只能恢复呈现与待决事实。
6. **流中阶段**：生成中／参数完整待验证／可操作／提交中／已受理／冲突或未知分开；“可操作”针对当前完整对象，不等待同 turn 所有文字结束。结构增量不能覆盖用户编辑、抢焦点、整条 remount 或跳阅读锚点。

上述属于 cat 建议。上游可参考[bounded Table catalog](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/table-catalog.tsx)、[Open GenUI renderer](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/renderer.tsx) 与[回对话 bridge](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/sandbox/prompt-bridge.tsx)。它们的组件内标记、React promise 与内存状态没有证明跨 App 重启的 exactly-once、系统动作或 SQL 多实例恢复。

## 需要进入可验收 spec 的检查

这些检查应作为现有 AF／UX／FINAL 质量条款的细化，与六卡和同候选要求共同验收，不另设只测 Web 的放行通道。

| 检查 | 可观察通过条件 | 现有覆盖 |
|---|---|---|
| 组件选择与降级 | 在适用数据／试算回答中选择登记呈现；纯文字无需强制图形；未知类型／非法数值仍可读，提交禁用 | AF-A16/18，FQ-01/05 |
| 流中就绪 | 分片不完整时不可提交；完整验证后可在其余文本流动时本地操作／明确提交；输入、焦点、scroll不丢 | AF-A04/16，AF-U04/06，FQ-01 |
| 确定计算 | 至少一类登记公式的已知答案、边界、非法单位、超范围与精度用例一致；不调用模型作本地重算 | AF-A16，FQ-05/07 |
| 数据可信 | 原数据与单位／来源／口径可查；chart 与 table 数值相同；无效或缺数据不伪造0；derived有假设说明 | AF-A07/08/16，FQ-05 |
| 动作区分 | 排序／展开／调参无网络 turn 或 effect；显式继续只产生同thread一次受理；写入需要原精确审批 | AF-A02/09/10/16，FQ-02/08 |
| 历史与恢复 | 离开／断网／冷启动恢复同block/version与合法草稿；重放不重算外部effect；stale输入提示冲突并保输入 | AF-A05/08/10/18，AF-U07/08/12，FQ-01/08 |
| 原生可访问 | 375/390/430pt、最大字号、浅深色、Reduce Motion、VoiceOver下可用；图有可读数值表，触摸可选点，无hover专属操作 | AF-U10/11，FQ-06 |
| 成果一致 | 原对话、历史与成果入口打开同数据／formula/version/hash；导出明确快照或可交互能力，过期链接可重取 | AF-A08/16，AF-U08，FQ-05 |

先用受控 payload 和已知计算值验证 renderer/reducer；再在已授权真实模型路径验证模型选择组件、分片、同工作续接和真实决定。合成 replay 不能替代真实模型、PG 多实例、物理手机或系统动作证据。性能与真实调用样本仍受既有授权及 FINAL 的后续具体测试计划约束。

## TS／Web 成果实验的扩展门槛

若原生 registry 不能表达某类解释，再评估独立 TS viewer；要先有具体任务收益，再固定组件、资源和版本。默认无账户凭据／共享 cookies/storage、无系统写 handler；限制网络、消息 origin、生成内容能力与资源容量。回 Agent 由原生明确按钮产生可审阅请求，生成 JS 不能自称用户手势、批准或完成。它的 WKWebView/iframe 边界、恶意来源、生命周期、导出、离线资源、手势与读屏都需实际验证。

固定上游 sandbox 暴露 sendPrompt/openLink，但授权手势主要依赖提示词，没有 cat 的 durable action ID、批准 revision 或 effect核对；其任意生成 renderer 依赖 WebSandbox 和 CSP，而不是只靠 schema 获得可信性。不能把这个开放路径作为原生审批、日程或记忆删除的执行入口。[sandbox functions](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/sandbox/sandbox-functions.ts)、[frame-content](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/frame-content.ts)。

本轮可推进的决定是 **Swift 原生受控 GenUI＋受控解释／图表／试算内容＋明确动作边界**。正式 CopilotKit SDK/Intelligence、任意生成 TS viewer 或 wire 迁移仍须各自具体适配与互通证据；这些候选不阻挡已经确认的原生能力开发。
