# OpenMuse 二次源码核读与小咪缺口

2026-10-13，静态源码研究。固定 `CopilotKit/openmuse@1ac68f3909f2478ab6280883f1ab5ea65eb5719d`，与此前研究相同；本次新增结论来自更细的代码核对，不是上游版本更新。公开缓存 HEAD 与工作区干净状态核实，未运行上游代码、模型、账户或部署。实时产品进展只见[主计划](../status/master-plan.md)。

## 实际读到的机制

| 源码事实 | 对小咪的设计含义（判断） |
|---|---|
| `model.ts` 的工具名是 **set_plan**，另有 ask_user/save_artifact/finish_task。工具执行串行 checkpoint，operations 按工具名＋序列化参数 hash 缓存结果；上限16步、5分钟 | 先补计划与真实工具的执行连接。operations 缓存不是外部写的原子提交或 exactly-once 保证 |
| `service.finish()` 将所有 plan 项一起标 succeeded；模型 finish_task 保存总结成果再结束 | 不继承“结束时全计划变绿”。已完成步骤必须有独立记录；任务完成另核约定、成果和必需回执 |
| `thread-artifacts.tsx` 的历史卡按 task ID 重新读取任务/成果/文件，signed URL 不存消息；失败有 Reload task results | 消息保存对象引用，卡恢复时读取真实版本与当前访问能力；读取失败只重读，不再次执行原动作 |
| `agent-workspace.tsx` 用 requestVersion 防旧读取覆盖，只前台轮询；动作已经成功、随后 refresh 失败仍保留动作成功 | 区分“操作回执成功”和“列表刷新失败”，避免刷新错误诱导重复写；轮询不是后台任务机制 |
| `conversation-queue.ts` 只存内存，失败暂停，未隐式重发已出队请求 | 借鉴队列交互，不降低小咪已有持久本地意图；服务端受理不明时核对原请求 |
| `page-diff.ts` 归一化文字、过滤相对时间；monitor 对变化去重、错误退避；属于有限条件监控 | AF-A13 的无变化/重复/错误/停止应独立验证，不把定时重问模型当条件监控 |
| Markdown 禁用 HTML，外链只允许 http(s)，代码和长表格各自有容器 | 借鉴稳定阅读与安全渲染边界；实际字号、可访问性按小咪 UX-1，不继承 RN 样式 |

固定源码：[model](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/model.ts)、[service.finish](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/service.ts#L892)、[thread-artifacts](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/thread-artifacts.tsx)、[workspace](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/agent-workspace.tsx)、[queue](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/conversation-queue.ts)、[page-diff](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/server/src/engine/page-diff.ts)、[assistant-response](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/assistant-response.tsx)、[assistant-markdown](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/src/assistant-markdown.ts)。

此前[三仓研究](../../research/openmuse-opendots-copilotkit-assessment-2026-10-13.md)中 save_plan 的称呼以本次实际 `set_plan` 为准；该旧报告保持原文作为日期证据。

## 对照现有工程

现有 [runtime.mjs](../../services/edge/supabase/functions/_shared/core/src/runtime.mjs) 已导入受控 OpenMuse TaskWorker；没有理由为了获得同一个 worker 重做全后端。[tools.mjs](../../services/edge/supabase/functions/_shared/core/src/tools.mjs) 实际只登记 delegate_task/agent_status 与 save_artifact/finish_task/ask_user，限制为冻结对话的本地可逆报告；不能把 spec 的公开 URL、记忆、日程和 monitor 当现有工具能力。

[report-completion.mjs](../../services/edge/supabase/functions/_shared/core/src/report-completion.mjs) 和 [worker-output-contract.mjs](../../services/edge/supabase/functions/_shared/core/src/worker-output-contract.mjs) 已区分 saved=true 与服务端完成资格，绑定 scope/turn/operation/hash。保留这层完成权威，再扩展通用计划和成果合同；现有特定报告的章节/长度校验不是研究准确性或通用任务完成验收。

工程映射：W30 建持久计划及逐步证据；W31 登记真实公开读取并提交可追溯成果；W32/W33 校对精确审批、effect 核对及租约栅栏；W50/W51 借鉴 monitor 的游标/去重/退避；D30/W70 将同对象恢复、版本和刷新错误放进六类原生卡。模型路径仍先按 W10–12 验收，不增加模型供应商。

## 复用决定与限制

保留既有 vendored worker、MIT notice、pin manifest 和精确 patch。其余模块目前是迁移候选：先移植 schema/纯函数/验收思路，再按小咪 Postgres 权威与 Edge 有界执行改造。复制实质源码时单独 pin、保留许可、记录受控差异；本次未复制业务模块。

客户端是 Expo/React Native，后端是 Node/Hono/TanStack；根依赖包含 CopilotKit runtime、AG-UI、PGlite/pg、浏览器/电脑适配，不能整包直接当 SwiftUI 或 Deno 模块。[mobile manifest](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/apps/mobile/package.json)、[根 manifest](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/package.json)。根 [LICENSE](https://github.com/CopilotKit/openmuse/blob/1ac68f3909f2478ab6280883f1ab5ea65eb5719d/LICENSE) 为 MIT，版权 OpenMuse contributors；服务条款和依赖许可另核。完整模板的 Intelligence 配置约束见既有研究，本次没有验证该服务可用性或费用。

研究可支持修改规格；不能继承为真实模型、PG 多实例、云调度或真机 PASS。
