# ADR-005：运行时复用与 worker 运行方式

状态：**Proposed**，2026-10-12。框架迁移和worker运行方式尚未Accepted；本ADR只记录现状、既有约束和待评审选项，不实施架构变更。固定目录来源HEAD为 `52ee35267fddfcb4ca4108a7a37893e860598d97`。

## 已有事实与约束

当前是 **vendored OpenMuse TaskWorker＋自研chat/auth/store/model适配**。`core/src/runtime.mjs` 引用受控 `vendor/openmuse/runtime/engine/worker.mjs`；Edge适配位于 `integration/edge-adapter/`。不是纯自研，也不等于已接入CopilotKit完整SDK或Intelligence服务。[ADR-002](adr-002-upstream-pinning.md)的固定上游、MIT归属和受控patch约束继续有效。

保留SwiftUI客户端和Supabase Auth/Postgres数据层。任务lease/checkpoint、审批和结果未知语义仍需明确权威；expired lease或网络中断不构成安全重放外部写操作的证据。研究建议不自动改变现有HTTP合同、数据权威或模型配置。

## 待评审选项

| 选项 | 评审内容 | 当前决议 |
|---|---|---|
| 常驻worker | 原状态机/heartbeat的适配程度、部署运维、授权续期、故障恢复及成本 | Proposed，未选定或部署 |
| Edge有界分步 | 每次调用预算、checkpoint栅栏、独立调度调用方、恢复/撤权、事务与effects核验 | Proposed，现有适配和离线测试不足以放行长期执行 |
| 其他durable框架迁移 | 与现有worker/state/store的收益和风险、迁移边界及许可 | Proposed，未Accepted；本批不迁移 |

[OpenMuse研究](../research/openmuse-runtime-source-review.md)提出长任务常驻worker等工程建议；它不是cat已接受的部署决定。早期[OpenDot评估](../research/opendot-runtime-assessment.md)描述未确认的composio同名候选；用户现已明确指定 **CopilotKit/OpenDots**，当前依据切换到[该仓固定源码核读](../research/opendots-code-review-2026-10-13.md)。历史候选未采纳，不混用其身份和许可。

评审应比较同一任务在中断/接管/等待审批/撤权/unknown等路径的正确性与成本，形成明确方案和验收门槛后再改变ADR状态。版本来源、部署、用户可用性分别签收，不能用测试数量或安装成功替代产品验收。[现状快照](runtime-state-2026-10-12.md)不宣称性能、图片、侧栏或后端P0已放行。

## 2026-10-13 四仓核读后的选择细化

[固定源码决策报告](../research/copilotkit-four-repo-decision-update-2026-10-13.md)及[来源 manifest](../research/copilotkit-four-repo-source-manifest-2026-10-13.json)是本次选择输入，不修改既有受控上游身份。保留 SwiftUI、Supabase 和现有 worker；按模块移植最小算法/合同/故障用例，不整体融合四个应用。

| 模块 | 设计方向 | 实施限制 |
|---|---|---|
| 计划、执行与有限 monitor | OpenMuse 参考；逐步 evidence 与完成资格分别核验 | 完成不批量标全部步骤成功；保持既有 frozen patch |
| 成果编辑与恢复 | OpenDots expectedRevision、generation、autosave/tombstone 算法候选 | 适配现有 Artifact/PG/Swift，不搬 SQLite/Tiptap |
| 审批与后台工作 | OpenBot consume/result/continuation、PG due 领取和失败分类参考 | 保留 cat Approval/Effect；unknown 先核对，完整 Bun/Intelligence runtime 不接入 |
| 智能 UI | 编译受控 Swift 六卡 registry，完整参数后操作，后台保存/等待 | A2UI wire 先互通证明；任意 HTML/JS viewer 单独提案 |
| 电脑运行 | Dots/Bot provider seam 可参考 | 仍 Proposed；新增计算预算0，可持续资源/provider/region确认后实施 |

OpenBot 强制 Intelligence；OpenIntelligentUI 是 Next＋Python graph，含额外 Jev 路由和内存 checkpoint。上述依赖和不同 CopilotKit/AG-UI 版本没有证明整体替换收益。常驻与Edge分步的部署选择仍 Proposed，不能从模板代码存在推定云运行可用、无需资源或已获部署授权。

## 2026-10-13 对话GenUI与onboarding决策

设计采纳[CGUI-1](../design/conversation-generative-ui-spec.md)：已编译SwiftUI registry承载table/chart/calculator，既有会话和成果投影传完整、有限、版本化数据；本地reducer与确定内核处理无请求交互，显式跟进以新turn/run或安全checkpoint接同工作，真实写继续由领域决定／effect控制。这是实施设计，部署与[CG验收](../acceptance/conversation-generative-ui-acceptance.md)尚须实际证据。

[第二链接核读](../research/copilotkit-conversation-ui-onboarding-review-2026-10-13.md)是CLI onboarding提示，并非第二个源码基座；未执行CLI，未见完整run配置／资源价格。SDK、AG-UI adapter、Intelligence与任意HTML/JS viewer仍Proposed，各按兼容／收益／来源与资源门评估。原生GenUI无需这些候选先成立，不改原route、零新增计算预算或冻结HTTP。
