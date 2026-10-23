# 小咪家庭陪伴改造 · 执行 Goal

适用说明（2026-10-24）：本文保留 2026-10-22 的规划快照，不再作为当前阶段编号、默认导航或启动状态的权威。当前按[用户确认的 M1–M6 Roadmap](../../product/mimi-roadmap.md)执行，进度只见[主计划](../../status/master-plan.md)；以下既有权限、证据与隔离约束按复用范围继续有效。旧 Goal 不因新路线自动完成。

版本：评审 v0.1 · 2026-10-22 · 状态：**PLAN_READY / NOT_STARTED**。

本文件把[技术方案](../../architecture/family-companion-technical-plan.md)转为可执行里程碑，不替代既有规格与验收。用户要求延后启动，具体启动时间/触发条件尚未确认，目标 Mac 尚未授权；本轮只提交计划，没有创建或恢复实施 Goal、启动实现 agent、改应用代码、部署或付费。旧 AF/FINAL Goal 不因本文自动恢复、替换或签收。实时项目交付状态仍只在[主计划](../../status/master-plan.md)维护。

## 1. 总目标与完成定义

从宝妈带孩子的高频场景出发，让家长用文字、口述或图片交代安排和观察，小咪能澄清、确认、持久保存、跨会话记住、在有意义变化时主动跟进，并可纠正、暂停和删除。首期主要成人账号；多人共享、年龄范围和自动保存范围在 M0 冻结，不由实现 agent 自行扩大。

保留 conversation-first、侧栏、原生返回及现有设计 token；今天 / 聊聊 / 我们家是内容分区，成长计划归我们家一级内容。家庭、成员、目标、计划、事项、观察、记忆分开建模。权限、真实回执与删除范围不能被温馨文案或猫表情替代。

完成条件：M0-M5 的必需验收在同一 release manifest 下闭合，三条旅程“口述调课”“图片通知→确认安排”“成长观察→跨会话召回→纠正/删除”具备可复查证据；没有未归因的必需失败或假成功。性能指标是待 M0 确认的目标，历史 874/2 或 528/27/4 只代表原审计输入，不能算新候选验收。内测发布/生产变更仍受单独授权边界约束。

## 2. 模型与原生 Goal：请求、支持、实际执行分开

| 项目 | 本轮核验事实 | 后续硬门槛 |
|---|---|---|
| 用户要求 | 本地、云端与实现/验证 agent 均优先固定 `gpt-6.1-sol` + `ultra` | 不用别名“GPT-6.1”代替精确 ID；不静默降到 max/xhigh 或其他模型 |
| 当前主机支持目录 | CLI 0.163.0 的 models cache 列出该模型和 low/medium/high/xhigh/max/ultra；任务工具声明一致 | 缓存不是实时账号授权，目标主机/云环境分别重新读取支持项 |
| 本轮规划探针 | 一次仅规划审阅子代理的创建请求接受该参数组合并完成审阅 | “创建成功/参数被接受”不等于底层实际执行模型得到权威回读 |
| 本轮实际模型 | 当前任务 ID 在本机线程元数据无匹配行；没有实际模型/effort 权威回执 | 记录 `effective_model=null`、`effective_effort=null`、`UNVERIFIED`；不能靠自述补齐 |
| 本机原生 Goal | `codex features list` 显示 `goals stable true` | 只证明本机功能开关；当前任务无可调用 Goal 创建/状态工具，未创建 Goal |
| 目标 Mac / 云 | 目标主机未授权，云端精确模型和 Goal 入口未验 | M0 读取实际客户端/账号能力；不把当前 Mac 的结论迁移过去 |

官方 [Models](https://developers.openai.com/codex/models) 说明 GPT-6.1 Sol 的 reasoning effort 可到 Ultra，具体可见性依赖配置与账号；[Codex changelog](https://developers.openai.com/codex/changelog) 记录原生 Goal 在 App/IDE/CLI 的功能发布。这些产品说明不证明目标账号已授权或任务已启动。`ultra` 是本次要求的最高推理/多代理模式，不等于另行开启 Ultrafast、购买额度或新增付费模型路由。

正式启动时每个 agent 记录 requested/accepted/effective model 和 effort、证据时间及返回来源；实际回读缺失或不符则停在 M0，由总指挥报告缺口，不偷换模型。若客户端只能显示已保存配置，明确标为 configured；需要能证明该配置适用于本次 run 的平台记录，才可写 verified。保存配置本身不等于已执行。

原生 Goal 必须通过受支持 App/CLI 或正式工具操作，创建后读回 `goal_id、objective_version、host/thread_id、status`。不得用 Markdown 标题、普通长对话、heartbeat/cron 自动化冒充原生 Goal；无法读回则不宣告启动。云端若不能独立使用原生 Goal，可由已验证本地原生 Goal 编排云任务，但须先确认用户接受该拓扑。

## 3. 启动与暂停合同

状态转换：`PLAN_READY → WAITING_FOR_START → M0 → M1…M5 → REVIEW_READY`；阶段内使用 `RUNNING / BLOCKED / PAUSED / FAILED / PASSED`。当前是 PLAN_READY，没有活动 run 或 goal_id。

启动需同时满足：用户明确给出启动指令或已确认的触发条件；目标主机授权在线且准确项目目录存在；选定原生 Goal 拓扑与唯一总指挥；模型实际配置可验证；最新 main/工作树/部署 manifest 已核对；M0 合同和允许操作范围冻结。不能把“延后”解释成今晚、定时自动开始或机器一上线就开始；本轮不创建定时器。

暂停条件：用户暂停、权限/凭证不足、模型不符或降级、预算耗尽、跨家庭泄漏/敏感日志、无法证明写操作结果、必需测试失败、协议分叉、未知来源代码或共享文件写入冲突。暂停受影响 lane；不依赖它的已授权离线工作可继续。拒绝后不换通道绕过；结果不确定先读回，只有获得新的相关证据且已确认未执行时才按约束重试。

## 4. 里程碑与阶段门

每阶段先固定用例、样本、输入版本和分母，再运行；下列数字是提议验收门，M0 由产品/工程确认后冻结。安全门为硬约束，性能门可经明确决策调整，不能事后删失败样本。

| 阶段 | 进入条件 | 可测验收 / 交付物 | 停止条件 |
|---|---|---|---|
| **M0 环境与合同** | 启动条件和目标机授权明确；既有 Goal 已只读清点、无重复活动总目标 | 本地/云/每 agent 模型与 effort 回读；原生 goal_id/status 可核对；统一 main SHA、部署/迁移/配置 manifest；仓库干净或 WIP 逐项归属；3 旅程、权限/保留范围、API/事件/卡片/迁移版本及性能目标冻结；分支、worktree、角色、额度上限与 Ledger 建立 | 目标机/云无授权，model/effort 未验，不存在原生入口，旧 Goal 状态冲突，生产与本地源无法对账，范围未定 |
| **M1 稳定底座** | M0 通过；缺陷探针与现有失败基线已固定；允许安全离线测试 | 初始化先失败后恢复，同实例恢复、100 并发 single-flight；claim 后中断在 2 个调度周期内恢复且每 occurrence 1 个持久结果；100 次取消交错在取消先于提交时 0 新事件/dispatch；写点失败注入不丢 due、不重复事实；日志合成敏感标记 0；30 条合成 trace 可拼完整时序；必需原生失败逐项归因，不能用定向通过关闭全套故障 | 敏感日志/越权、重复副作用、丢 due、取消围栏失败、恢复结果未知、必需故障未复现/未归因 |
| **M2 家庭记录闭环** | M1 核心可靠性门通过；权限和 command/receipt 合同冻结 | 家庭/成员/事项/观察及计划关联持久化；今天/聊天/我们家读同一权威事实；3 旅程的手动结构化路径正常、缺字段、修改、取消、重复点击、断网/冷启全覆盖；同 key 同 hash 返回同结果、异 hash/旧 revision 409 且保草稿；至少 20 组两家庭/私有/撤权用例 0 越权；unknown 查原 receipt，不盲重发 | 跨家庭读取/写入、个人聊天被默认共享、对象重复、迟到结果串账号、界面显示已完成却无回执 |
| **M3 多模态与记忆** | M2 同一事实/权限面成立；输入 consent、记忆来源/时效/更正协议冻结 | 口述转文字可编辑，图片缺项/模糊字段需确认；单次例外与整系列调课可区分；100 个虚构中文跨会话案例，约束 recall@6 建议 ≥90%，错误主体/撤回记录注入 0，更正后下轮旧事实使用 0；CAS 冲突 409 不覆盖；删除后缓存、索引、摘要与迟到 job 不复活；journal 中断不丢 fragments；原媒体 TTL 清扫与用户选择有证据 | 识别结果直接变共享事实、敏感推断伪装事实、删除复活、记忆第二权威漂移、实际模型质量门无获准样本 |
| **M4 主动跟进** | M1 durable lease/fencing 与 M2-M3 数据、权限、预算成立；分析/通知授权已获准 | outbox/job/occurrence 唯一性、claim 重启/重复 tick/写失败可恢复；无变化 0 建议/推送，1 个有效变化最多 1 个有效建议；静默、每日 cap、暂停/撤销、过期权限全部按冻结策略；100 次取消交错；Inbox/APNs/用户阅读分开记录；每条建议 why-now 可追溯，无通知回执不宣告已送达/已接手 | 重复触达、撤销后新 dispatch、无变化反复模型调用、预算超限、不能解释 why-now、APNs unknown 被盲重发 |
| **M5 同版真机内测** | M1-M4 必需门通过；真机/签名/通知/TestFlight 等精确操作获授权；release manifest 冻结 | 同一 App SHA/包 hash、后端包、迁移/配置/协议版本验证 3 旅程；听写/图片/通知/EventKit 真实回执；断网/后台/杀 App/换账号恢复；最大字号/VoiceOver/Reduce Motion/低内存矩阵；必需全套连续 3 轮 0 未归因失败；获准真实链路量测延迟/成功率，失败入分母；8-12 个自愿家庭、14 自然日日用作为方向性观察；删除/导出/恢复/回滚演练；发布评审材料齐备 | 未获设备/生产操作授权，候选版本不一致，隐私/数据丢失/重复效果，必需失败，缺实链证据，日用尚未满期 |

M5 的 8-12 家庭和 14 天是建议研究设计，不是已招募/已授权处理真实儿童数据，也不支持统计显著或竞品优势宣称。正式内测前单独确认参与者同意、最小数据与退出/删除流程。

依赖链为 M0 → M1 → M2 → M3 → M4 → M5。阶段内可并行开发和独立预验证，但阶段签收依赖不能跳过；例如 M1 期间可做已冻结的家庭 UI fixture，不能因此标 M2 已验收。

性能目标沿技术方案作为 M0 待确认项：缓存首屏 p95≤500ms、无媒体无工具受理 p95≤2s、首正文 p50≤3s/p95≤8s、delta 到可见 p95≤150ms；指定机型、网络、地区、路由、上下文长度和样本量，不将各段 p95 相加。资源不足时报告承诺差距，不隐式购买或切付费后备。

## 5. 总指挥与并行分工

总指挥负责拆片、依赖、权限/预算、模型证明、证据和阻塞处理；**唯一集成人**负责集成分支、协议基线、候选冻结和 release manifest。可由同一名本地 lead 承担；云 agent 不直接改主机共享工作树或合 main。QA/安全审阅与实现分开，同一作者不能凭自述关闭自己的关键安全门。

| Lane | 执行环境与主要职责 | 写入边界 / 交付 |
|---|---|---|
| Local Lead / Integration | 已授权目标 Mac：原生 Goal 总入口、集成、Xcode/真机、最终同版证据 | 专用集成分支与独立 worktree；保留原安装与所有 WIP；按显式路径集整合 |
| Local iOS | 导航内容分区、现有 token/组件、确认卡、草稿/缓存、语音/图片、账号 epoch | `apps/ios-conversation` 及明确分配的本地包；不修改云 schema/共享协议权威 |
| Cloud Backend | API/鉴权/命令/receipt、家庭存储与迁移、初始化/调度可靠性 | 后端专用分支；测试数据虚构，迁移只在获准隔离环境，不碰生产 |
| Cloud Memory | 唯一记忆面、提取/检索/CAS/删除/摘要恢复 | 独立分支及约定目录；与 Backend 共享文件由一个 owner 串行处理，不双写 |
| Cloud QA / Security | 故障注入、PG 并发、合同兼容、越权/注入/删除、固定质量集 | 独立测试分支；独立复核候选，标清 mock、离线、真实 PG 和模型层 |

建议总指挥 + 3-4 个实际工作 agent 起步，并发上限以客户端/账号支持和预算为准；数量不是目标。串行依赖或热点文件不为“并行”强行拆。可共享只读快照，不能共享可写 checkout/数据库 fixture；每 lane 使用唯一测试 namespace、可重建虚构数据和清扫责任人。

每个 agent 都要显式固定 `gpt-6.1-sol` + `ultra` 并记回执；子代理也不能只继承含糊默认值。目标云平台若不能固定/回读该配置，暂停该 lane 并报告；不能改用当前可用低档模型顶上。

## 6. 分支、协议与集成纪律

实施不在 `docs/family-product-plan` 中进行。M0 从最新已确认的 main 建短分支，每个 agent 独立 git worktree：例如 `fix/family-runtime-recovery`、`feat/family-records-api`、`feat/family-records-ios`、`feat/family-memory`、`test/family-reliability`。名称为示例，启动时查重，不覆盖现有分支。分支/云任务均记录 base SHA，保留 legacy-local 与旧品牌 worktree，不 force push、不 reset 他人改动。

唯一集成人维护一份共享协议基线，冻结 command/receipt、revision/409、家庭权限、事件 envelope、卡片 schema、capabilities 与迁移顺序。字段和错误语义变更先提交协议增量、影响矩阵和新版本，由各 lane 确认后切换；旧客户端 fallback 必须存在。协议/迁移文件同一时刻一个 writer；不以聊天消息替代版本化合同。

工作 agent 交付审阅分支/PR、变更路径、测试证据与未验项；集成人在自己的 worktree 整合，保持候选可重建。进入 M5 冻结同一 manifest，后续任何影响行为的变更使相关证据失效并重验，不跨包拼凑通过。main 合并、生产部署和分发单独获批准后才执行。

## 7. Run Ledger 与证据矩阵

启动后建议在 `docs/acceptance/family-companion/` 维护已脱敏 ledger/矩阵；原始运行日志、媒体和设备标识留在受控/忽略目录。规划阶段不创建虚假的运行记录。每个 run 至少记录：

`run_id / parent_goal_id / objective_version / milestone / lane / thread_id / host_alias / branch / worktree_alias / base_sha / candidate_sha / requested_model / requested_effort / accepted_model / effective_model / effective_effort / model_evidence / protocol_version / test_data_version / release_manifest / authorization_ref / started_at / ended_at / status / evidence_refs / blocker / next_action`。

模型字段不存在则 null + 原因；host/worktree 用非个人别名，避免用户名、绝对私人路径、儿童身份和凭证进入仓库。`authorization_ref` 引用可信用户决定，不复制敏感对话全文。每个副作用保留原操作 identity，不因重试另造 run 冒充首次执行。

| 证据层 | 能证明什么 | 不能代替什么 |
|---|---|---|
| source / static | 实现存在、合同/目录/敏感规则 | 运行、模型质量或设备效果 |
| offline / fixture | 固定输入的确定性行为和故障探针 | 真实 PG 并发、真实识别与通知 |
| isolated PG / concurrency | 事务、RLS、lease、重试和撤权 | 托管部署/真实模型/系统权限 |
| hosted model | 固定路由/提示版本的实际结果、首字和终态 | 端上可见、推送、系统写入 |
| device / end-to-end | 同版从输入到持久回执/系统对象的闭环 | 未跑的设备矩阵和长期日用 |
| daily-use / recovery | 明确期间内的使用、遗漏/纠错和恢复表现 | 所有用户场景、统计显著或全面生产成熟 |

每项验收一行：`criterion_id、milestone、输入/前置、期待结果、层级、actual、status、candidate/manifest、证据定位、owner/reviewer、未验限制`。状态只用 `NOT_RUN / RUNNING / PASS / FAIL / BLOCKED / SKIP`，SKIP/BLOCKED/未授权不能折算 PASS。失败、取消、超时全部保留分母与原因；M0 约定日志保留期和清扫负责人。

## 8. 审批边界与本轮交付

本轮授权：能力只读核验、方案/执行文档、已有 docs 分支提交推送。仅启动了一次有界的规划审阅子代理；它不执行产品改造，不代表实施 Goal 已运行。

未来明确启动且 M0 合同成立后，可在分配工作树内做已授权实现和安全离线验证。以下仍需精确授权/条件满足：目标 Mac 接入/迁移、恢复或替换旧 Goal、真实 Auth/模型/第三方请求、生产 DB/迁移、部署、真机安装/权限、APNs/外部发送、TestFlight/App Store、main 合并、账号/权限/密钥与任何付费。实现 agent 无权自行扩大这些范围；现有“零新增计算预算”不因多 agent 或最高模式自动取消。

下一步只需确认三个启动决定：**何时启动或什么条件触发；目标主机授权；本地原生 Goal 编排云子任务的拓扑是否接受**。其余可验证的配置和环境检查由 M0 完成，不要求用户反复确认常规技术选择。
