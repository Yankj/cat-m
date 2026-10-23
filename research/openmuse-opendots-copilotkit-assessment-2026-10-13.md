# OpenMuse、CopilotKit OpenDots 与 Swift 主动 Agent App 选型核验

核验日期：2026-10-13（Asia/Shanghai）。范围：官方源码、官方文档的静态核验；本次未启动这些参考项目，未运行其测试，未连接真实模型、Google、Slack、Intelligence 或语音账户。上游的验证声明与本次核验结果分开记录。

## 结论与适用方式

**建议以 OpenMuse 补全个人 Agent 的需求和运行机制，以 CopilotKit/OpenDots 补全 Specialist、Spaces、MCP 审批及语音交互；继续用 SwiftUI 实现原生客户端。当前没有证据支持把任意一个仓库直接当成 Swift 原生 App 的底座。** 这是工程判断，依据下面的真实技术栈、执行位置与服务依赖。

三个项目的分工不同：OpenMuse 是个人 Agent 应用模板；OpenDots 是多个 Specialist 与文档空间的应用模板；CopilotKit 是连接 Agent 与前端的 SDK/运行时。它们适合组合成需求检查表和有限模块复用，不能把三个应用/框架全量拼装就当作一个完整产品。

本次已获知 cat 当前采用 SwiftUI、Supabase 与 OpenRouter，并已受控抽取 OpenMuse worker，外围使用自研 chat/auth/store/model 与最多约 30 秒的 Edge tick。这是当前主审计提供的上下文，**本研究不再把 cat 描述为“从未使用 OpenMuse”**，也没有独立核验上述现状。完整上游与受控抽取版的差距应逐项验收：存储、恢复、任务执行器、工具卡片、审批、监控和模型适配是否被完整接上；仅移植 worker 类不会自动带来这些能力。

旧文件 `旧本地主仓/docs/research/opendot-runtime-assessment.md` 暂定评估的是 `composio-community/open-dot`，并明确身份未确认。**它不是本次用户明确指定的 `CopilotKit/OpenDots`**。旧文件里有关 Electron、Composio、OpenRouter、许可证未核实的结论不能迁移到本项目。本次 OpenMuse 固定版本与旧 `openmuse-runtime-source-review.md` 一致，主要补充 OpenDots 比较、立项细节与三者接入成本。

## 证据固定版本

| 项目 | 本次读取的 main HEAD | 检查方式 |
| --- | --- | --- |
| OpenMuse | `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`，2026-10-06 | 完整 shallow clone；读取 mobile、domain、server worker/service/model/actions/config、线程与验证材料 |
| CopilotKit/OpenDots | `625452e06cde74cb25b0ce319e2c1be0488f5a5f`，2026-10-06 | 完整 shallow clone；读取 client、store/runner/platform、connections、voice、learning、channel、部署文档 |
| CopilotKit SDK | `7e97c05d5eef004c92f75c39be06690f8a9d3899`，2026-10-12 | Git tree 全量清单；按固定 SHA 下载并读取 core、runtime、RN manifest、HITL/render hooks，未把 examples 全量执行 |

以下链接固定至这些提交，避免后续 main 变化影响复盘。官方文档链接为核验当天的版本，可能继续变化。

工具边界：CopilotKit monorepo 的完整工作目录检出遭遇上游网络中断；Git HEAD 与完整 tree 清单已取得，关键文件按该 SHA 从官方 raw 地址单独下载成功。未用未读文件推断已实现功能，也未运行它的完整构建。

## 技术栈与运行边界

| 维度 | OpenMuse | CopilotKit/OpenDots | 对 Swift 路线的含义 |
| --- | --- | --- | --- |
| 客户端 | Expo 54、React Native 0.81.5、React 19.1、CopilotKit RN 1.70.1 | React 19、Vite、React CopilotKit 1.75、Tiptap；响应式 Web | 前者能运行于 iOS，但不是 SwiftUI；后者没有独立原生移动工程。直接 fork 客户端意味着改走 RN/Web 路线 |
| API / Agent | Node + Hono + TanStack AI + CopilotRuntime | Node 24 + Hono + TanStack AI + CopilotRuntime | 可以保留服务端模块，Swift 另实现 API、事件与卡片；移入 Edge 需要适配运行期限、Node API 和进程生命周期 |
| 业务持久化 | PGlite / PostgreSQL，owner/kind/id + JSONB records；独立 task worker 使用 PostgreSQL | Node `node:sqlite`，tasks/runs/events、pages/Spaces/Dots、线程绑定等 | 两者都没有“换连接串即可成为 Supabase 多租户服务”的依据 |
| 对话持久化 | 启动配置强制 Intelligence project key | 页面/配置可先用；聊天需要 Intelligence + 模型配置 | 此依赖是模板具体选择；CopilotKit OSS 本身可以走 SSE，无需强制购买/使用 Intelligence |
| 执行环境 | 独立 Chromium worker；可选 Docker Linux 或 E2B desktop provider | OpenBot supervisor/computer service；另有只读 public-page browser | 手机是交互与监督入口；持久任务、浏览器及电脑执行发生在后端 |

来源：[OpenMuse mobile manifest](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/package.json)、[根 manifest](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/package.json)、[db.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/db.ts)、[config.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/config.ts)、[worker-entry.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/worker-entry.ts)；[OpenDots manifest](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/package.json)、[store.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts)、[platform.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/platform.ts)、[computer-service.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/computer-service.ts)。

## 功能细节矩阵：用于重新立项与验收

“实现”表示存在实际执行代码，**不等于当前 cat 已有、不等于上游真实账户全面验收通过**。

| 功能 | OpenMuse 事实 / 边界 | OpenDots 事实 / 边界 | cat 应明确的验收细节与源码 |
| --- | --- | --- | --- |
| 流式聊天 | AG-UI 文本、工具、状态；server-owned delegate_task | AG-UI + TanStack；同一 Dot thread 有聊天、后台 turn | 首 token、工具参数增量、工具执行结果、RUN_ERROR、取消、最终持久化分别有状态；[Muse tanstack-agent](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/tanstack-agent.ts)、[Dots dot-agent](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/dot-agent.ts) |
| 连续输入 / 队列 | 回复中可输入，后续消息可移除，Stop / 失败暂停队列；队列在 App 内存 | composer 保留草稿并约束当前 run | 已发送、排队、草稿必须可区分；关 App 后是否提交需要独立服务端 inbox；[Muse queue](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/conversation-queue.ts)、[run error 处理](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/conversation-run.ts)、[Dots composer](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/chat-composer.ts) |
| 消息附件 | composer 选择已有 document IDs，PDF 可导入；不能据此宣称支持任意图片模型输入 | 文件上传未包含；MCP 结果归一化会把非文本块转成 omitted 标记 | 相册 / 相机 / 剪贴板、上传、缩略图、重试与 model content parts 单独验收；[Muse chat](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/chat.tsx)、[screens](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/screens.tsx)、[Dots normalizeResult](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connections.ts) |
| 长任务 | tasks/runs/run-events、SQL CAS lease、heartbeat、checkpoint；同时最多 3 个任务 | SQLite leases；90 秒单次 runner；掉线/lease 过期标 Interrupted | App 退出、worker 重启、超时、租约丢失后结果可回查；分片恢复有明确语义；[Muse worker](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/worker.ts)、[Dots runner](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/runner.ts)、[Dots claim](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts#L207) |
| 任务生命周期 | queued/running/waiting_input/waiting_approval/scheduled/paused/completed/failed/cancelled | queued/running/completed/failed/interrupted/paused/cancelled | 每个状态须有可操作入口与下一步解释，不能只显示 spinner；[Muse domain](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/packages/domain/src/agent.ts)、[Dots shared types](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/shared/types.ts) |
| Plan and Execute | 模型可 save_plan、ask_user、finish_task；持久计划、evidence 与 artifacts | prompt 可执行工具，但无同等完整个人 Goal 规划结构 | 任务目标、完成条件、计划、当前步骤、证据、等待输入、产物要相互可追踪；[Muse model](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/model.ts) |
| 主动建议 | refreshIdeas 基于邮件/PDF/关键词规则，有证据、接受/修改/忽略，排除已完成/已发送 | 工作空间与 schedule 为主，未看到同等 Ideas | 建议依据、与任务去重、用户采纳、退订和无变化静默；不能把规则建议称为通用自主洞察；[Muse service](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/service.ts#L554) |
| 主动监控 | 公开页 change/contains/USD price 条件；去重、相对时间过滤、失败退避、5 次失败暂停 | 成功后按 interval 再运行原 thread；不是通用 event-trigger system | 定时、条件、外部事件三类触发分开；同一变化只提醒一次，失败可见；[Muse runMonitor](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/service.ts#L1064)、[Dots schedule](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts#L186) |
| Goals / 长期责任 | Goals 与 milestones 存在；自适应长期计划仍 roadmap | 没有完整 Goal/责任生命周期 | 目标和一次 run 不是同一实体；进度、预算、暂停、终止、长期评估需单独设计；[Muse domain](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/packages/domain/src/agent.ts)、[roadmap](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/ROADMAP.md) |
| 记忆 | editable owner facts；remember_fact；作为未可信数据注入 prompt | SQLite preferences；Dot / 全局 memory 权限；另配置学习容器 | 查看/修改/忘记、来源、适用范围明确；向量检索/自动反思/记忆冲突不能默认已实现；[Muse model context](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/model.ts#L322)、[Dots dot-agent](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/dot-agent.ts#L303) |
| 审批 / 恢复 | 服务器 action proposal 绑定内容 hash、账号/连接、目标版本；30 分钟到期；unknown outcome | 存储 MCP 精确连接/工具/参数；owner-only 路由执行；聊天审批卡和已存 receipt | 必须可从消息/任务重新打开；批准前展示服务器存储数据，重启后能查结果；[Muse actions](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/actions.ts)、[Dots card](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/ConnectionActionCard.tsx)、[store](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-store.ts) |
| 连接器 | Google OAuth Gmail/Calendar，读写分权；fixture 覆盖，真实账户验收仍需做 | Streamable HTTP MCP + 可选 bearer token；每 Dot / 每工具权限，readOnlyHint 影响默认审批；OAuth-only 尚不支持 | 连接成功、读取成功、写权限、断连/换账号失效各自证据；MCP 服务器列表不等于可用连接器；[Muse google](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/packages/integrations/src/google.ts)、[Dots connections](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connections.ts) |
| 产物 / 生成 UI | 原生自定义 email/browser/PDF/plan/finance/choice/task 卡片 | 自定义 computer/action/page cards，页面编辑器 | 先定义有限卡片 schema、loading/error/completed 和点击动作；不是模型随意输出 Swift 代码；[Muse render registry](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/chat.tsx#L57)、[Dots Chat](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/Chat.tsx) |
| 多 Specialist / Spaces | 以一个个人 Agent + Goals/Activity 为中心 | Dots 有角色指令、工具与多 Space 授权；page 与 specialist 配对 thread；revision 防覆盖 | 何时多 Agent、谁负责、如何共享证据先明确；不能把角色列表当自动协作；[Dots workspace](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/workspace.ts)、[page service](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/page-service.ts) |
| 语音 | roadmap；非当前完整支持 | Browser WebRTC speech + ask_compute；mute/minimize/end/receipt；speech 端点固定 OpenAI | 原生需麦克风/音频路由/WebRTC 生命周期适配；compute base URL 不会切换 speech provider；[Dots voice.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/voice.ts)、[useVoice](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/client/useVoice.ts) |
| 通知 / App 回前台 | durable in-app inbox；可见时 3 秒 poll，回前台立即刷新；device push 未实现 | 页面轮询/线程时间线与 call receipt；不是原生推送系统 | APNs、通知去重、静默条件、深链回原任务另列验收；[Muse workspace refresh](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/agent-workspace.tsx)、[background updates](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/background-updates.tsx) |
| Slack / 外部渠道 | 非当前主流程 | Channels SDK mention + follow-thread；workspace/user allowlist；fixture 验证，真实连接待验收 | Slack/scheduled turn 遇需审批动作引导回 Web；不能默认可在所有渠道完成审批；[Dots slack](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/slack-channel.ts)、[connection-tools](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/connection-tools.ts) |
| Automatic Learning | 未在本次关键路径发现与 OpenDots 等同接线 | 每 Dot learning container、thread evidence 路由、已发布技能投递；依赖 Intelligence | 学习产生的技能需审查发布；现有 conversation 不自动回填；不是已有长期记忆替代品；[Dots learning](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/learning.ts)、[dot-agent](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/dot-agent.ts#L324) |

## 持久执行需要保留的关键语义

**OpenMuse 的恢复是以已存业务状态重新启动模型任务，不是恢复模型内部执行栈。** `engine/model.ts` 读取 operations、evidence、artifact IDs 等，部分工具按工具/参数 hash 缓存；模型重新运行。单次任务有步数与 5 分钟超时限制。`TaskWorker` 默认 60 秒 lease、定期续租和 guard/checkpoint；lease 丢失会中断旧执行者。外部写入由单独 action 审批执行；不确定 provider 结果必须保留 `outcome_unknown`，不能因为没有最终消息就重发。 [model.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/model.ts)、[worker.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/worker.ts)、[actions.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/actions.ts)。

**OpenDots 的重复任务更简单。** `Store.claim()` 把过期 running 标成 Interrupted，只领取 queued 或到期 completed；`Runner` 每秒取任务，单次 90 秒，在 `index.ts` 中把 turn 发回原 Intelligence thread。成功后计算下次 interval；崩溃/未知副作用等待人工 review/retry。它不是完整长期目标或事件驱动系统。 [store.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/store.ts#L207)、[runner.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/runner.ts)、[index.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/index.ts#L68)、[headless.ts](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/headless.ts)。

**对当前 Edge tick 的推断：** 有界 tick 本身可以作为执行分片入口，不能只凭 30 秒上限判它无效；关键是超时前有没有可恢复 checkpoint、下一片由谁重新调度、是否有稳定 run/thread/message IDs、模型 stream 是否被持久化、审批后如何重新入队、已执行 effect 如何防重。若这些机制不完整，延长 timeout 也不会解决持久执行。若要接入 OpenMuse 原样长 run、浏览器、电脑或文件系统，常驻 Node worker 更贴近上游边界；这要以实际需求和本机审计决定，不能先换栈。

## CopilotKit 能帮到 Swift 的具体程度

1. **可借鉴/接服务端：** AG-UI 的运行、文字、工具、状态事件；模型运行时与 provider adapter；前端工具、HITL 和 tool-card 的状态设计。`runtime/core/runtime.ts` 明确区分 SSE 模式（默认 `InMemoryAgentRunner`，可自配 runner）与 Intelligence 模式（durable threads/realtime，其 runner 由服务自动装配）。因此“CopilotKit 必须依赖 Intelligence”不适用于框架整体，却适用于上面两个模板的当前聊天接线。 [runtime.ts](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/runtime/src/v2/runtime/core/runtime.ts#L269)、[SSE runner](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/runtime/src/v2/runtime/core/runtime.ts#L521)。
2. **不能直接拿来做 Swift UI：** core 是 TypeScript；RN SDK 的 peers 是 React/React Native；`useRenderTool` / `useHumanInTheLoop` 依赖 React hooks 和 React renderer。HITL hook 在当前会话内等待 promise / respond；完整跨重启审批依赖额外服务器记录，OpenDots 的 action store/card 正是该层。 [core manifest](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/core/package.json)、[RN manifest](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/react-native/package.json)、[useRenderTool](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/react-core/src/v2/hooks/use-render-tool.tsx)、[HITL hook](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/react-core/src/v2/hooks/use-human-in-the-loop.tsx)。
3. **Swift SDK 待验证：** 当前 CopilotKit 源码树没有独立 Swift SDK；唯一匹配的 Swift 文件是 RN example 的 AppDelegate。AG-UI 官方 SDK 清单未列 Swift，[Swift SDK issue #494](https://github.com/ag-ui-protocol/ag-ui/issues/494) 仍开放；官方另有 Kotlin Multiplatform 进入 iOS/SwiftUI 的路径，但不是 Swift 原生 SDK 本身。若采用 KMP 桥接，需要独立 spike 验证包集成、取消/reconnect、线程恢复和审批，不依据宣传直接推定可用。 [AG-UI 官方 SDK 清单](https://github.com/ag-ui-protocol/ag-ui#sdks)、[官方 KMP 说明](https://www.copilotkit.ai/blog/ag-ui-goes-mobile-the-kotlin-sdk-unlocks-full-agent-connectivity-across-android-ios-and-jvm)。
4. **原生生成 UI 可先做有限 registry：** 使用 Codable schema 表达 card kind、toolCallId、status、payload、actions，由 SwiftUI 映射固定组件；这借鉴受控生成 UI。A2UI 可以后续扩展声明式 catalog；MCP Apps 的官方实现是 sandboxed iframe，原生需要 WebView/宿主通信适配，不能自动变成 SwiftUI。 [官方生成 UI 分层](https://docs.copilotkit.ai/concepts/generative-ui-overview)。
5. **版本必须固定：** OpenMuse 使用 AG-UI `0.0.59` / CopilotKit `1.70.1`；OpenDots 使用 `0.0.59` / `1.75`；当前 SDK `1.78` 的 manifest 使用 AG-UI `1.0.2`。新的 event/schema、hook 参数和 transports 不应靠一次全量升级解决。每条接入路线都要固定服务端与客户端契约并测试重放。 [Muse manifest](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/package.json)、[Dots manifest](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/package.json)、[Core manifest](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/packages/core/package.json)。

## 复用成本与方案选择（推断）

| 方案 | 可以得到什么 | 新增复杂度 | 当前建议 |
| --- | --- | --- | --- |
| 完整 fork OpenMuse，改为 RN App | 最快继承 mobile UI、个人任务与产物流程 | 放弃 SwiftUI；Hono/任务/浏览器/电脑/Intelligence 多服务；迁移身份、数据与真模型验收 | 仅当用户愿意改技术路线并接受服务依赖时考虑 |
| SwiftUI + 完整 OpenMuse 后端 | 复用较完整任务/工具/审批 | Swift AG-UI/Intelligence 协议实现；账号/租户改造；两个数据权威；Node/file/browser 部署 | 适合后端需求真的覆盖这些模块，不能直接作为当前小修 |
| SwiftUI + 现有受控 worker 抽取，补齐契约 | 延续已有投入，针对卡住路径修复，保持当前数据权威 | 要逐项补齐 task/model/store/action/renderer/recovery，不靠模板替代验收 | **当前优先候选**，以本机审计、真模型闭环决定保留与替换范围 |
| SwiftUI + OpenDots 全量后端 | Specialist、Spaces、MCP、call/Slack patterns | Intelligence、SQLite、OpenBot、channels/voice 的新边界；单 owner 身份；Web 编辑器重写 | 先参考模块与需求，整套迁移优先级低 |
| 只引 CopilotKit | 标准化事件、tool UI、shared state/HITL primitives | Swift 不能直接调用 React SDK；框架不会补好外部任务、认证、推送、连接器和 release provenance | 可作为服务端 adapter / 协议选项，不能当作“只换流式组件就有主动 Agent” |

建议可搬迁范围是：OpenMuse 的任务/domain、worker CAS/lease/checkpoint、action proposal/hash/receipt、monitor 去重/退避、产物和客户端状态语义；OpenDots 的 per-Dot/tool 权限、服务器审批记录及可重开卡片、page revision、voice compute 分离模式。每个模块保持一个负责的身份/数据库/执行器，避免并存两套未经协调的 chat 与 task authority。

## 已确认方向下的最小底座（规划建议）

用户本轮已确认：先做通用 Agent 底座，原生体验优先、Swift 优先，局部可用 TypeScript 或其他技术。依此收敛，建议不是“重新 fork 一整套 App”，而是保留原生交互，把真正必须驻后端的执行能力做小且可验收。

| 模块 | 最小职责 | 复用边界 |
| --- | --- | --- |
| Swift 事件 reducer 与 native chat | 将 run/message/tool/state/error 事件归并成稳定消息与工具卡；支持 Stop、重进、恢复审批 | 借鉴 AG-UI 语义、Muse queue/run-error；用 Swift 实现，不嵌入 React SDK |
| TypeScript provider adapter | 一个实际选定的 provider/model；streaming、tool calls、取消、错误、有限模型步数 | 保留现有 OpenRouter adapter，先验证；参考 Muse TanStack 适配，确认收益再替换 |
| 共享 run/task/event 契约 | owner、threadId、runId、messageId、taskId、sequence/cursor、状态、时间、error、receipt | 抽取 Muse domain；转换为 Swift Codable 与服务器 schema；现有数据库为唯一权威 |
| Tool registry 与 executor | schema、read/write 意义、所需权限、执行 handler、timeout、receipt；不能由模型自行批准 | 参考 Muse server tools + Dots per-tool permissions；第一阶段仅两三个内部工具 |
| Approval service | 存精确 tool/args/hash/connection、pending/approved/denied/expired/executing/succeeded/failed/outcome_unknown | 抽取 Muse actions 与 Dots approval card 语义；审批入口存在于原消息、任务详情和待办 |
| Worker / scheduler | transactional enqueue、claim lease、fencing、checkpoint、下一片调度、暂停/取消、恢复 | 校对已有 vendored Muse worker 与有界 Edge tick；常驻 worker 和分片路线用证据选定 |
| Artifact / activity | 结果、来源、工具回执、步骤进度与原消息互相引用；重启后可查看 | 参考 Muse artifacts/runs/events；先采用固定 SwiftUI 卡片 |

不在最小底座首轮引入 Intelligence、OpenBot、Spaces 编辑器、自动学习、通用 MCP OAuth、语音、动态 A2UI 和多 Agent 协作；它们按具体用户场景和收益再接入。此范围是本研究的建议，需要与主规划的最终范围对应。

### 五个可以判定成功/失败的工程验证

1. **真实文字模型闭环：** 用手机当前可追踪 build 与唯一 commit，调用实际选定模型，发送一个带随机 nonce 的简单请求；记录 provider、model、runId、first-token/final/error 时刻和服务器结果。UI 必须出现真实增量回答，服务器必须保存 final；强制退出再进入仍能看到同一条消息。`/health` 成功和 API key 非空不作为通过条件。
2. **真实工具闭环：** 让同一真实模型调用内部只读工具，例如读取当前 owner 的一条已存 note 或返回后端当前时间。必须通过 registry 真正 dispatch，产生 toolCallId、结构化结果和回执，随后模型依据结果回答；不接受只渲染工具卡或模型口述“已调用”。验收包含一次工具失败与一次取消。
3. **审批闭环：** 准备一个内部副作用工具（如保存一个草稿 artifact），先创建精确 proposal，等待时强制退出 App，再从原消息/任务重新打开审批。Decline 产生零写入；Approve 写入一次、返回 receipt 并续跑；重复点击/网络重试仍只写一次。修改参数后原批准失效。故意断开回执链验证 `outcome_unknown` 可见且不自动重复。
4. **worker 恢复闭环：** 委派包含两步的小任务；第一步保存 checkpoint 后停止当前 worker/让 tick 到期，再由下一 worker/tick 继续。第二步完成，同一 task 的 plan、events、artifacts 连贯，第一步 effect 不重复。另验收 pause、cancel、lease 被接管时旧执行者不能提交 checkpoint。
5. **最小主动闭环：** 在本地受控 public-page fixture 上创建条件 watch，建立 baseline；相同内容不提醒，改变内容只产生一个持久通知，重复 tick 不重复提醒；连续失败进入明确退避/暂停状态。通知能回到原 thread/task。做到这些后，才接真实外部来源或 APNs。

每个验证都输出同一份构建信息、数据库/事件证据和手机可见结果。若前一步失败，优先修复该层，不用新 UI、更多 connector 或重新选框架遮盖故障。上述是 cat 的提议验收，并非本次已完成或上游保证。

## 许可证、部署和数据边界

- 三个核验仓库根许可证均为 MIT；复制实质代码应保留版权和许可文本。[Muse LICENSE](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/LICENSE)、[OpenDots LICENSE](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/LICENSE)、[CopilotKit LICENSE](https://github.com/CopilotKit/CopilotKit/blob/7e97c05d5eef004c92f75c39be06690f8a9d3899/LICENSE)。独立云服务与依赖仍有各自条款，本核验不是许可法律意见。
- Intelligence 不包含在模板 MIT 代码中；官方提供 hosted、licensed self-host 和 macOS Docker 本地 evaluation。当前本地 evaluation 要 CopilotKit 账号、有效 evaluation license 和显著 Docker 资源；并非随源码附带的无限生产服务。[OpenMuse Rich Threads](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/docs/RICH-THREADS.md)、[OpenDots setup](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/docs/SETUP.md)、[官方 local evaluation](https://docs.copilotkit.ai/intelligence/self-hosting-local)。
- OpenDots 的 SQLite 存页面/metadata，Intelligence 存聊天；复制 SQLite 不是完整会话备份。MCP bearer tokens 在服务器 SQLite 内，新增 OAuth-only 支持另需开发。[setup](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/docs/SETUP.md)、[Connections](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/docs/CONNECTIONS.md)。
- OpenMuse / OpenDots 都是单 owner 起点；“有授权路由”不等于完成多用户隔离和生产运维。浏览器、模型、Google/MCP、语音和 Parallel 搜索各自有网络和数据边界，必须以我们实际启用的模块记录。[Muse auth](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/auth.ts)、[Dots platform identity](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/platform.ts#L81)、[Muse search](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/search.ts)、[Dots parallel](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/src/server/parallel.ts)。

## 尚未证实与下一个工程门槛

1. **当前用户模型是否真正可用仍未证实。** 参考模板、配置字段、/health、HTTP 通达或模型列表都不能替代一个真实流式回答及一个真实工具调用。应先在 cat 的同一构建上完成：文字输入 → provider first token → final → 持久化 → 重新进入可读；再做工具与审批闭环。
2. 上游 OpenMuse 验证材料明确区分 fixture、真实 Chromium/Docker 和待做的 Google / Intelligence / live model；OpenDots 官方 README 记录部分 2026-09-29/30 live 检查，但 Slack、spoken compute 与学习云调度仍留有验收边界。本次没有重复这些 live 验证，不能继承成我们的验收证据。[Muse verification](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/docs/VERIFICATION.md)、[Dots demo evidence](https://github.com/CopilotKit/OpenDots/blob/625452e06cde74cb25b0ce319e2c1be0488f5a5f/docs/demos/README.md)。
3. OpenMuse 当前源码已含 E2B desktop provider，但旧 README/roadmap 的 graphical desktop 文字有滞后；应按 provider 文件和具体环境验收判断，不能绝对说“没有桌面代码”，也不能把存在 adapter 当做全路径可用。[E2B provider](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/computer-e2b-desktop.ts)。
4. 重新立项应把“对标 Dot/Muse”拆成用户场景和验收能力，而不是先写更多页面：先完成可靠的对话/审批/任务闭环，然后选择一个可证实的主动场景（如公开页变化或授权邮件待办建议），最后扩展 Specialist、文档、语音与电脑。这个顺序是基于上述依赖图的工程建议，并非上游承诺或已经批准的 cat 范围。
