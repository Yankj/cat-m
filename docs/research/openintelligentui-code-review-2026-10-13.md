# OpenIntelligentUI 固定源码评审

2026-10-13；固定提交 [`9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b`](https://github.com/CopilotKit/OpenIntelligentUI/commit/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b)。本记录是源码研究输入；实际推进状态仅见 [master-plan](../status/master-plan.md)。它不改变 [AF-1-G3-UX1](../planning/AF-1/goal.md)、六类原生卡、现有模型路由、冻结 HTTP 合同或用户数据，也不关闭任何产品验收。

## 决策更新

**继续以 SwiftUI 实现选择、表单、计划、审批、成果、对比六类受控卡；从 OpenIntelligentUI 借鉴组件登记、输入验证、流式生命周期和回到同对话的动作处理。将任意 HTML/JS 的智能可视化单独视为成果详情实验候选，不能与操作卡混为一条接入路线。** 该仓可显著补充实现细节，但不是可直接链接进 Swift 的原生 SDK，也没有提供小咪所需的持久任务、独立调度和系统动作闭环。

| 方案 | 源码支持的能力 | 对小咪的建议 |
|---|---|---|
| `useComponent` / `useRenderTool` | 固定 React 组件＋Zod 参数；模型在登记范围内提出呈现 | 借鉴机制，移植为 Swift typed registry；不引入 React 聊天宿主 |
| A2UI catalog | 一个明确登记的 Table 组件，有限字段、边界和错误降级 | 借鉴“受控 catalog＋数据 schema＋本地 renderer”；继续现有卡协议，不立刻切换 A2UI wire |
| Open Generative UI | 模型生成 CSS/HTML/JS，经 WebSandbox 渲染与受控 host bridge | 仅可作为独立成果查看器的待评审实验；先证明体验收益和隔离边界 |
| 整套 Next/Python 应用 | CopilotKit runtime 转接 LangGraph/DeepAgents，另有 Jev 呈现路由 | 当前不整体导入：会增加执行栈、供应商、状态权威和依赖成本 |

这四项是工程建议，不是本轮已运行的互通结果。[组件登记](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/hooks/use-generative-ui-examples.tsx)、[Table catalog](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/table-catalog.tsx)、[sandbox renderer](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/renderer.tsx)支持上述能力区分。

## 阅读范围与身份

读取完整非截断目录树：190 个 blob，其中 38 个测试文件；目录树无 `.swift` 文件。实际读取并缓存 52 个源码、测试、配置和许可证文件，逐文件核对 Git blob SHA；缓存与逐文件 SHA256 在忽略的 `build/research-copilotkit-20261013/OpenIntelligentUI/SOURCE-READ.json`。研究缓存没有安装依赖、启动服务、调用模型或部署。

| 关键文件 | Git blob SHA |
|---|---|
| `LICENSE` | `b3bf13ded443fa46a3fbbf69c42d2150c21f4cda` |
| `apps/agent/main.py` | `9fec803e611220636cce4421c0ae1977395e275f` |
| `apps/agent/src/bounded_memory_saver.py` | `aed473f01de1a2a8891e6410029cb2c62dec5a85` |
| `apps/agent/src/visualization_router.py` | `928556b703411813b238117809c27b814b06d7ee` |
| `apps/app/src/app/providers.tsx` | `ecb8e8118cbfbdf178e1af23313d99631d7d0243` |
| `apps/app/src/hooks/use-generative-ui-examples.tsx` | `f5cd60cf5ac71d5ccd9015f8879f8726d7e19c9b` |
| `apps/app/src/components/generative-ui/table-catalog.tsx` | `fa34141d83cb68f06951c753396894d4e78bd574` |
| `apps/app/src/components/generative-ui/open-generative-ui/schema.ts` | `b40670184e6c6d2ffaa3111a07fd84b76cf24a52` |
| `apps/app/src/components/generative-ui/open-generative-ui/renderer.tsx` | `4fb3a407a1b8beba263f4fb0d9065c5598a1872a` |
| `apps/app/src/components/generative-ui/open-generative-ui/frame-content.ts` | `246e696d8eaef1b976ec4fbaf3ec4d9559128662` |
| `apps/app/src/lib/sandbox/prompt-bridge.tsx` | `7045e718a247fe440562a02626d47a31f225fdec` |
| `apps/app/src/lib/sandbox/sandbox-functions.ts` | `24a65ba0c8af17b50d73ba412307e19a885e64fd` |

根 [LICENSE](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/LICENSE) 为 MIT，版权归属 `Copyright (c) Atai Barkai`；允许复用和修改，复制实质代码时须随附该版权与许可通知。根许可证不替所有 npm/Python/CDN/字体依赖作许可结论；本轮未完成这些依赖的逐项许可审计。当前只写研究文档，没有导入其生产实现。

## 实际架构与运输边界

客户端 `Providers` 建立 Theme、临时 provider keys、CopilotKit provider 和 chat configuration，登记受控组件、A2UI catalog、`open-generative-ui` activity renderer 与 sandbox functions。`HomePage` 使用 `useAgent()` 的同一个 agent 实例和 `CopilotChat`，而不是为每个 widget 建立另一条会话。[providers](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/app/providers.tsx)、[page](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/app/page.tsx)。

运输链是 React → `/api/copilotkit` Next POST → 每请求新建 `CopilotRuntime` / `LangGraphHttpAgent` → Python FastAPI AG-UI endpoint → DeepAgents/LangGraph graph。Runtime 启用 A2UI tool 注入与 Open Generative UI，MCP middleware 仅在配置地址时启用。Python 的 tools 是 sample CSV、图片来源、可视化计划、todos、示例 form；graph 加入模型、CopilotKit、Jev 与 Anthropic compatibility middleware。[runtime route](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/app/api/copilotkit/route.ts)、[runtime options](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/copilotkit-runtime-options.ts)、[agent entry](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/main.py)。

SDK 的客户端运行、AG-UI reducer 和 `OpenGenerativeUIMiddleware` 实现在外部依赖中；本仓的 activity schema 注释也明确由 runtime middleware 发出。不能仅凭这个应用仓认定 SDK 具备小咪的 cursor、durable replay、approval/effect 栅栏或 Supabase 适配。应用里的 [`shared-thread.test.tsx`](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/app/__tests__/shared-thread.test.tsx) 使用真实 SDK provider/hook，但 HTTP 边界是模拟的 `RUN_STARTED` / `MESSAGES_SNAPSHOT` / `RUN_FINISHED` SSE；它不是线上模型或重启恢复证据。

## 受控登记、schema 与动作

`useGenerativeUIExamples` 分开登记 `toggleTheme` 前端 tool、`pieChart/barChart` 受控组件、`plan_visualization` 后端工具 renderer、默认工具详情和 `scheduleTime` human-in-the-loop。这个分层值得保留：**渲染、客户端交互、受理执行、等待用户决定，应有不同的接口语义。** 不能因为都有按钮，就让一个“generic UI action”直接执行所有操作。[登记代码](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/hooks/use-generative-ui-examples.tsx)。

Table catalog 最有参考价值：标题≤300字、1–12列、≤200行、单元格≤2000字，渲染时再次 `safeParse` 并检查每行列数；非法数据给 `role=alert` 降级，来源字段强制要求，不用模型内容直接生成 HTML。小咪可以将该模式应用到六类卡的数组数量、文本长度、必需字段、对象身份、动作枚举和文本降级，但具体阈值应按自己的合同确定。[Table schema/renderer](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/table-catalog.tsx)。

需要补足的差距也很具体：上游 `scheduleTime` 仅收到原因与时长，默认展示 Tomorrow/Friday/Next Monday 的样例时段，点按立即设置 React state 并向 agent 回答“Meeting scheduled”。源文件没有 EventKit、日历对象 ID、scope、revision、审批有效期或真实系统回执。因此它能参考“选择→回同对话”，不能作为 AF-A09/A14 的执行证明。上游 `generate_form` 明确是不能登录、不能保存的示例。[MeetingTimePicker](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/meeting-time-picker.tsx)、[generate_form](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/form.py)。

`plan_visualization` 返回展示策略的字符串；PlanCard 的完成勾表示这个工具展示完毕，不是可修改、可停止、可恢复的持久 Task 计划。`todos` 保存在 graph state，并整体替换列表；该代码不能替代小咪 Goal/Task/Run/Effect 的状态权威。[plan tool](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/plan.py)、[PlanCard](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/plan-card.tsx)、[todos](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/todos.py)。

建议在现有 Card envelope 内实现明确的 action reducer：本地输入 → submitting → 真实受理/拒绝/unknown → 从同 objectID/revision 读取新状态。view 不能先写“已完成”再等待服务回执；过期卡先重读。审批动作必须走原授权/幂等/effect核对路径，不能借用文本 follow-up 绕过它。这是对既有 AF-A09/10/16 与 AF-U06–08 的实现细化，不增加新的产品卡类型。

## 流式生成的可借鉴细节

Open Generative UI content 的实际字段为 `initialHeight/generating/css/cssComplete/html[]/htmlComplete/jsFunctions/jsFunctionsComplete/jsExpressions[]/jsExpressionsComplete`，没有小咪的 object revision/action receipt。Renderer 做了几个有价值的阶段控制：[schema](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/schema.ts)、[renderer](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/renderer.tsx)。

1. 默认每1000ms转发一个绘制快照，首HTML、CSS完成、HTML完成、JS到达和生成结束立即刷新。可借鉴“呈现合并、terminal立即刷新”；不能把1000ms直接套到文本首字性能目标。
2. CSS完成前只显示加载；HTML未完成使用 preview sandbox。部分HTML先剥掉末尾半标签、完整/不完整script/head/style，再做 DOM morph，减少闪烁。
3. HTML完成后销毁 preview，创建 final sandbox；函数一次注入，表达式按数组增长执行，等待 sandbox ready 时先排队。
4. iframe 高度按报告限制在50–4000px，仅接受本 iframe source 的 resize消息。unmount 销毁sandbox、清理timer与listener。
5. 完成时保持外层 ExportOverlay 的树形不变，避免切换完成标记把仍活动的iframe意外 remount。

小咪的对应设计应是可恢复的 card snapshot/revision 驱动 SwiftUI；流中不完整参数只展示无副作用的占位，不启用批准/提交；完整且验证通过后才启用动作。合并绘制不可丢状态事件。重开从持久对象恢复，不能重放渲染时副作用。这些是上游机制启发的建议，不是把其 JS 表达式执行移植到手机。

Renderer 的顺序索引、函数注入标记和队列是 component refs，销毁/新建sandbox会重置；因此其“只执行新增表达式”属于当前 widget 生命周期，不能扩展解读为跨App重启的 exactly-once。不同批次的表达式由各自 async loop 执行；尚未运行跨批次延迟执行竞争测试，不能从单批次有序推断全局执行顺序。[renderer effects](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/renderer.tsx#L241)。

## 渲染安全与 Web 实验边界

最终iframe会注入 CSP：script允许 inline/eval 和四个 CDN，connect允许自身与相同四个CDN，img有明确地图/Wikimedia来源；preview的head组装没有相同CSP meta。`processPartialHtml` 是流式片段处理，不是通用HTML消毒器：它没有过滤所有事件属性或危险URL。这里的安全边界依赖 WebSandbox 隔离、CSP和桥接能力，不能因为使用Zod或删script就把内容当可信。[frame-content](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/frame-content.ts)、[partial HTML](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/process-partial-html.ts)、[WebSandbox loader](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/websandbox-loader.ts)。

host仅暴露 `sendPrompt` 与 `openLink`。前者验证trim后1–4000字，同步claim避免重复listener重复发送，busy时拒绝；后者仅允许https，可选origin列表，无配置则允许任意https。`sendPrompt` bridge 订阅 `RUN_ERROR`，因为 `runAgent` promise resolve 仍可能对应协议失败；卸载清理pending，结果不能迟到变成功。该失败语义和重复点按防护值得应用到原生动作入口。[sandbox-functions](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/sandbox/sandbox-functions.ts)、[prompt-bridge](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/sandbox/prompt-bridge.tsx)。

但“仅在用户点击时 sendPrompt”主要写在模型提示中，host bridge没有用户手势证明、durable action ID、授权revision或账户动作权限。模型生成脚本一旦调用已有bridge，host按schema处理。`WebSandbox`本身的内部隔离实现是依赖，本轮未审计或实测；不声称该应用对任意恶意生成代码已充分隔离。[agent prompt](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/prompt.py)、[host bridge](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/sandbox/prompt-bridge.tsx)。

若以后做 TS/Web 成果实验，建议只给无凭据、无共享cookie/storage、无系统动作的独立viewer；本地排序/筛选/计算可以运行，回Agent的请求由原生显式按钮转换成同thread普通草稿/动作，并走既有许可。先固定资源、网络和消息来源，再验证iframe/WKWebView的实际边界。不得把真实审批、日历写入或记忆删除授权给生成HTML的任意JS。

`assembleStandaloneHtmlFromActivity` 能导出完整HTML，`ExportOverlay`提供下载/复制。导出脚本将sendPrompt降级成空函数，并保留普通https openLink；这不是服务端持久Artifact或完整离线资产包，HTML仍可能需要CDN资源。小咪保留成果version/hash/source、可从历史与活动两入口重开，并明确静态快照、可交互预览、可下载文件的区别。[export-utils](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/export-utils.ts)、[export-overlay](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/export-overlay.tsx)。

## 持久化、路由与依赖上的限制

graph使用 `BoundedMemorySaver(max_threads=200)`，继承内存MemorySaver并淘汰线程；其注释声明单进程async用途、非thread-safe，依赖 `MemorySaver.storage` 内部属性。源码因此固定LangGraph1.0.7。它不是跨进程、重启后可恢复的数据库checkpoint；内存thread上限也不证明所有checkpoint内存有界。`ProviderKeysProvider`是React内存状态，刷新会清掉keys，新chat通过session改变重建provider；不能据此关闭cat的历史/草稿/任务恢复验收。[memory saver](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/bounded_memory_saver.py)、[provider keys](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/chat/provider-keys.tsx)、[Python dependencies](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/pyproject.toml)。

Jev呈现路由以最新user-message ID识别新turn，同turn复用 decision；每新turn取最近4条human/AI上下文（每条最多6000字符）请求另一个API。路由结果决定text、A2UI Table或Open Generative UI，并过滤不允许的render tools；15秒请求超时，缺key/错误直接抛失败，没有这里可见的自动text fallback。因此它增加供应商、延迟和故障面，甚至普通文字问题也先经过路由。**采纳“先判断是否需要UI”的策略，当前用确定规则/现有模型受控输出实现，保持路由失败可回文本；不引入Jev、不改变既有模型供应商。** [visualization_router](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/visualization_router.py)。

凭据实现有可借鉴的具体防护：ASGI流整个生命周期用ContextVar隔离；敏感headers去除；BYOK时禁hosted tracing；内部thread ID以key命名空间HMAC处理，wire仍保留原thread；转发禁止fetchredirect，构造provider client不继承服务器proxy/org/header。它保护这个应用的BYOK请求，不替代Supabase用户身份、tenant权限、审批或长期授权。小咪不因研究新增BYOK输入或账户。[credentials](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/credentials.py)、[model](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/agent/src/model.py)、[runtime options](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/copilotkit-runtime-options.ts)。

应用固定Next16.1.6、React19、CopilotKit多个`1.55.2-next.1`包及不同版本的`@copilotkitnext/shared`，WebSandbox1.2.1，配套Python≥3.12/LangChain/LangGraph/DeepAgents；直接拿整套将增加Node和Python运行面。最新固定提交还接入默认启用的安装统计（可关闭），browser PostHog只有设build-time key时开启，session recording关闭。未来如实际导入需单独审查依赖、外发与版本兼容；本轮未运行它们。[app dependencies](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/package.json)、[launch telemetry](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/launch-telemetry.ts)、[PostHog](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/app/posthog-analytics.tsx)。

## 对现有设计与验收的具体输入

| 现有项 | 应补入实现/检查的内容 | 上游参考与边界 |
|---|---|---|
| AF-A04/05、AF-U04/12 | 合并绘制不回退，terminal立即落状态；布局增长不夺阅读锚点；重开重读同对象，无副作用重放 | renderer分阶段与清理；page只在新问题移动scroll；上游没有cat持久cursor证据 |
| AF-A09/10/16、AF-U06/07 | 参数未齐不启用提交；stale revision先重读；双击/duplicate listener/unknown不重复effect；协议error优先于promise resolve | sandbox bridge与测试可借鉴，approval/effect权威由原系统承担 |
| AF-A08/16、AF-U08 | 生成中、可预览、持久完成三个状态分清；导出/历史/活动指向同artifact version/hash；宽表只在局部横滚 | 导出ready gating与bounded table；上游下载不等于持久成果 |
| AF-A14、CP-03 | 日程选择先预览明确时区/时间/对象；真实EventKit回执到达后才显示完成 | 上游meeting picker是交互样例，不复制其立即“已安排”结果文案 |
| AF-A16/18 | 未知kind/schema/非法payload降级；来源可查；render与effect分离；Swift registry固定六类 | Table二次验证、样例声明、单source design-system机制 |
| AF-U10/11 | 统一tokens、动态字号/读屏/Reduce Motion；完成状态不remount整条消息；narrow viewport里控件能用 | 不直接复制大emoji、hover-only export、React动画或CSS字号 |

上游 `page.tsx` 设置 `autoScroll=false`，只在新用户问题出现时 `scrollIntoView`，`ReaderScrollView`让用户拥有viewport；对小咪“新增生成内容不抢滚动”有支持。它未实现我们的“靠近底部才跟随＋返回最新＋前后台阅读锚点”完整规格，因此参考原则，保留 AF-U04 的原生验收。[page scroll](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/app/page.tsx#L28)、[ReaderScrollView](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/chat/reader-scroll-view.tsx)。

## 测试证据与可复用用例

只读取测试，未执行上游CI/单测。Renderer测试覆盖CSS gate、preview→final、函数只注入一次、表达式新增、CSP拼装、外来resize消息拒绝、高度有界、unmount与完成标记不拆iframe；多数sandbox行为由stub模拟，不能证明浏览器真实隔离。Bridge测试覆盖busy、同步claim、重复listener、RUN_ERROR但promise resolve、unmount迟到、非法输入等；shared-thread测试保留真实SDK hook但模拟HTTP。[renderer tests](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/open-generative-ui/__tests__/open-generative-ui-renderer.test.tsx)、[bridge tests](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/lib/sandbox/__tests__/prompt-bridge.test.tsx)、[table tests](https://github.com/CopilotKit/OpenIntelligentUI/blob/9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b/apps/app/src/components/generative-ui/table-catalog.test.tsx)。

建议借鉴这些触发条件写入现有验收的对应步骤，优先验证：部分schema/旧revision、协议失败但transport完成、重复入口、详情关闭后迟到、渲染完成但真实effect未完成、历史重开、来源/非法数据、尺寸增长时阅读锚点。若以后试Web，另验证跨批次异步执行、重建sandbox、网络封锁、恶意消息来源、无用户点击的bridge调用，以及导出后的失效动作提示。所需证据层仍由既有18功能/12UX/3CP合同决定。

本轮没有模型、SQL多实例、系统日历、物理手机、真实WebSandbox、通知或独立主动调度实测。没有安装依赖、读取生产凭据、部署、发布或把候选Web实验计入已交付能力。
