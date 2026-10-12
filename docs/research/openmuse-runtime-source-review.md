# OpenMuse 源码核验：Catpaw-m 可复用的运行时与边界

核验日期：2026-10-12。实际读取公开仓库源码，固定版本：[1ac68f3909f2478ab6280883f1ab5ea65eb5719d](https://github.com/CopilotKit/openmuse/tree/1ac68f3909f2478ab6280883f1ab5ea65eb5719d)。本文是静态源码核验，未在本次研究中运行其测试或接入真实模型、Google、Intelligence 账户。

## 结论

可以且值得复用 OpenMuse；它提供了真实的后台任务实现，而不只是聊天 UI。但对于 SwiftUI + Supabase + OpenRouter 的 Catpaw-m，最合适的是复用后台任务状态机、工具执行与审批模式，以及客户端协议设计；不是把 `apps/mobile` 整体嵌入 SwiftUI，也不是误以为 CopilotKit 一项依赖已经包含完整持久运行系统。

OpenMuse 实际分成三个层次：CopilotKit/AG-UI 聊天运行时；OpenMuse 自己实现的 SQL 持久任务 worker；独立配置的 CopilotKit Intelligence 对话存储服务。后两者不是同一套持久化。

## 1. 实际依赖与客户端

`apps/mobile` 使用 Expo 54、React 19.1、React Native 0.81.5、`@copilotkit/react-native` 1.70.1。`App.tsx` 导入 `@copilotkit/react-native/headless` 的 `CopilotKitProvider`，UI 是 React Native 组件，同时导出 web/iOS/Android bundle。它不是 SwiftUI SDK。

服务器主要依赖 Hono、`@copilotkit/runtime` 1.70.1、AG-UI 0.0.59、TanStack AI 及 OpenAI/Anthropic/Gemini 适配器、PGlite、`pg`、Zod、RxJS。根目录还依赖 MCP SDK、可选 E2B Desktop 和 TypeSafe SDK。不能只复制一个 React hook 就获得服务器能力。

源码：[mobile package.json](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/package.json)、[App.tsx](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/App.tsx)、[根 package.json](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/package.json)。

## 2. 两种运行，而非一个无限 agent loop

### 前台对话

`agent.ts` 建立 `CopilotRuntime` 与 Hono `/api/copilotkit` handler；可以使用内置 `ConversationAgent`，也可以通过 `HttpAgent` 转发到外部 AG-UI endpoint。

`conversation.ts` 给模型提供 `delegate_task`、`agent_status`、`remember_fact`、读邮件/日历、浏览等工具。模型通过 `delegate_task` 将长任务写入后台。普通对话默认最多 6 个模型工具迭代；E2B Desktop 场景为 16。停止对话会取消该前台 run，但已委派任务是另一条服务端执行路径。

真正的模型/工具循环使用 `tanstack-agent.ts`：CopilotKit `BuiltInAgent({type:'tanstack'})` 包装 TanStack `chat()`；Zod/schema 工具被转换为 server tools；`maxIterations` 控制步数，AG-UI 传输文字、工具调用、工具结果和状态事件。

源码：[agent.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/agent.ts)、[conversation.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/conversation.ts)、[tanstack-agent.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/tanstack-agent.ts)。

### 后台任务

`TaskWorker` 是 OpenMuse 自己写的 TypeScript worker，默认每秒 poll 一次；读取 queued、到期 scheduled、lease 过期 running、已可继续的 waiting_approval 任务。每个 worker 最多同时处理 3 个任务。

它通过 SQL compare-and-swap 领取任务：写 `leaseId`、默认 60 秒 `leaseUntil`、增加 attempts；约每 20 秒续租。工具执行前的 guard 检查任务仍 running 且 lease 仍属于自己；checkpoint 用同样条件写入状态；暂停、取消、其他 worker 接管会中断旧执行者。运行和进度另存为 runs/run-events。

默认 worker 跟 API 同进程。独立 `worker-entry.ts` 明确要求 `DATABASE_URL`，因为 PGlite 不能供两个进程共同打开。移动 App 关闭后，任务可以继续，前提是后端 worker 仍然运行。

源码：[worker.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/worker.ts)、[worker-entry.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/worker-entry.ts)、[db.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/db.ts)。

## 3. 恢复到哪里：状态恢复，不是模型执行栈恢复

`executeModelTask()` 从已存 task.state.operations、evidence、artifactIds 等构建恢复上下文，重新创建模型 run；messages 主要重新放入原任务 prompt 和用户补充回答。它不从持久化的完整模型执行栈/逐 token 中断点继续。

部分操作按工具名 + 参数的 SHA-256 缓存结果，模型工具通过串行队列保护 checkpoint 顺序。任务还保存 plan、browserId、actionId、approvalResult 等。开放式任务单次最多 16 步，5 分钟 timeout。没有显式完成或等待结果时，进入 waiting_input，请用户继续；它不是无上限自行运行的 agent。

缓存也不是所有工具和所有副作用的 exactly-once 保证；例如 computer tools 走自己的命令与 receipt 路径。Catpaw-m 应保留“结果未知”的状态，而不是把过期 lease 等同于可安全重复外部操作。

邮件/日历工具只 prepare，单独审批后执行。服务器重启时，原处于 executing 的 action 被改为 outcome_unknown，要求核实第三方结果，不会静默重发。

源码：[model.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/model.ts)、[actions.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/actions.ts)、[db.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/db.ts)、[index.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/index.ts)。

## 4. 记忆、消息、任务三个存储边界

- **记忆**：owner 下的 memories 记录，主要是 text/source/createdAt。前台有 `remember_fact`，API 有编辑/忘记入口。后台模型把所有这些 facts 作为数据注入 prompt。这里没有看到专门的向量检索、记忆压缩/反思或分层记忆引擎。
- **任务与业务数据**：PGlite 或普通 PostgreSQL 的 records 表，用 owner/kind/id 和 JSONB data 保存任务、run、事件、操作、产物、通知等。
- **对话线程**：CopilotKit Intelligence 单独持久化和 replay。当前启动配置要求 `CPK_INTELLIGENCE_API_KEY`，不是仅可选的云增强。其服务没有包含在 OpenMuse 仓库 MIT 授权中。

SwiftUI 可以自行读取任务/审批 API，自己实现消息和工具卡片；若保留 CopilotKit threads，就需要适配相应客户端协议和服务。如果 Catpaw-m 要把所有对话放进 Supabase，则需要替换当前 Intelligence 集成，而不只是修改数据库连接串。

源码：[memory API](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/routes.ts)、[model context](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/model.ts)、[Rich Threads 文档](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/docs/RICH-THREADS.md)、[config.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/config.ts)。

## 5. 手机“后台恢复”的真实含义

任务执行发生在服务器。客户端 `AgentWorkspaceProvider` 在可见时每 3 秒读 `/api/agent`，回到前台时立即刷新；后台和不可见页面停止 poll。BackgroundUpdates 展示持久化的未读通知。

对话 composer 的 follow-up queue 则只在打开的 App 中存在，官方文档明确说它不是 durable server inbox。不能把“有排队消息 UI”理解为杀 App 后每条排队输入也必定继续提交。当前文档列 device push 为未来能力。

源码：[agent-workspace.tsx](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/agent-workspace.tsx)、[background-updates.tsx](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/background-updates.tsx)、[Rich Threads 队列说明](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/docs/RICH-THREADS.md)。

## 6. 对 Catpaw-m 的复用建议（工程判断）

1. 保留 SwiftUI 客户端；参考 `packages/domain` 的任务、审批、通知、产物模型，重写对应 Swift Codable 和 UI，而不引入 RN 全套 UI。
2. 优先抽取/改造 `engine/worker.ts`、任务状态机、checkpoint、lease fencing、action review 与 outcome_unknown 处理。配合现有自建 JS worker，而非再次从零设计。
3. PostgreSQL 层可对接 Supabase Postgres，但 auth.ts 当前是共享 access key + 固定 local-user 的单用户身份，不能直接当作多租户系统；替换成经验证的 Supabase 用户身份并落实租户隔离。records JSONB 存储可作为原型，也可以映射到 Catpaw 的规范表。
4. OpenRouter 不是这里命名的一等 provider；代码支持 OpenAI-compatible base URL 和 Chat Completions 开关。可基于该适配点接入，但应对具体模型的工具调用、streaming、错误和取消做测试，不宣称已验证直连成功。
5. 长任务使用长期运行的 Node worker；OpenMuse 自身是 Node/Hono、定时 poll/heartbeat、文件系统及独立 browser worker 架构。把整套原样塞入 Supabase Edge Functions 不是无改造迁移。Edge Functions 可以保留为鉴权/API/短操作入口，这是架构建议，而非本次核验过的部署结果。
6. 明确选择对话持久化：接入 Intelligence，或保留 Supabase 消息/event store 并实现 replay/reconnect。不要同时以两套数据都作为无约束的权威来源。

源码：[domain model](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/packages/domain/src/agent.ts)、[auth.ts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/auth.ts)、[provider adapter](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/tanstack-agent.ts)。

## 7. 许可与验证边界

仓库是 MIT：可复制、修改、商用，复制实质部分时保留版权与许可声明。独立服务和第三方依赖要分别核验；不能把 Intelligence 或 E2B 服务理解为 MIT 随仓库附赠。

项目自述仍是 alpha，验证文档包含真实 PGlite 重启、worker 竞争、lease 恢复、取消/暂停等测试描述；模型/Google/Intelligence 的真实账户验收有明确未完成边界。这些是项目已有的验证声明，不是本次运行结果。

注意源码与历史文档有版本差异：本次固定 commit 已包含 `computer-e2b-desktop.ts`、`COMPUTER_PROVIDER=e2b-desktop` 和相关 smoke test；旧 README/roadmap 仍有“graphical desktops future”的句子。因此不应绝对声称当前源码没有 desktop provider，也不能仅凭存在代码声称其已完成真实环境验收。

源码：[LICENSE](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/LICENSE)、[VERIFICATION.md](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/docs/VERIFICATION.md)、[E2B provider](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/computer-e2b-desktop.ts)。
