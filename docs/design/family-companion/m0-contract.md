# 家庭成长助理 M0 执行契约

版本 `family-m0.v1`，2026-10-23。本文是本次 Goal 的工程契约增量；实时进度只在[主计划](../../status/master-plan.md)。[2026-10-22 执行稿](execution-goal.md)保留为当时的准备记录。本文不将计划、测试数据或本地子代理计为产品实现或云端启动。

## 范围与权威

沿用一个原生宿主、现有视觉与 A1 图标、一个 Supabase 后端及现有模型路由；首轮单成人管理自己的家庭背景、孩子日常与成长。文字、图片、口述转文字进入同一确认、持久事实与回执链。多人共享、实时语音通话、自动报名缴费不进入首轮。家庭隔离与撤权测试仍然必需，不能因为单成人首发而省略。

三个既定旅程是口述调课、通知图片确认安排、成长观察跨会话召回及更正/删除。[技术方案](../../architecture/family-companion-technical-plan.md)定义领域和复用方向；[AF 底座](../../product/agent-foundation-spec.md)继续裁决权限、持久性与执行权。家庭 M0–M5 不替换 AF-A01–18、AF-U01–12 和 CP-01–03 的同版要求。旧 FINAL/FQ/CG/BP 合同保留，不因本轮准备签收或悄悄删减；本线程的家庭目标也不等于恢复另一个线程的暂停 Goal。

本轮只准备执行契约、固定测试输入、复现缺陷及核验运行端。应用/后端实现、迁移和外部操作尚未开始。后续只在已分配工作树实施已确认切片；新增费用、权限、生产变更和发布仍到具体节点决定。

## 基线与集成

- 产品源码基线：`789ad4feceb0680b8e2e5913083c5b834dc63db1`，远端 `Yankj/mimi` 的 `main`，本轮 fetch 与 ls-remote 一致。
- 规划输入：`2419db9b98e2e3bc0e8c850da62418d216fd3bb8`，`docs/family-product-plan`；相对产品基线没有 native/functions 源码差异。
- 本地总协调/唯一集成人使用 `docs/family-m0`，QA 使用 `test/family-m0`，用例编制使用 `test/family-memory-cases`，另设 `docs/family-source-audit` 只读来源审计；共四份独立 managed worktree。主目录、旧工作树、已安装 App 与用户数据保留。
- 新实现从当时重新核对的 `origin/main` 建短分支，登记 base SHA 和明确路径。不能将旧 local history 合入或推送；只接纳审阅的字节及 provenance。生产变更、推送、PR、合并或分发不能由本文件自动授权。
- 回退准备：本轮纯文档可撤销独立提交；实现片以新分支保留原基线，回退走审阅的 revert。迁移必须先证明旧客户端兼容、备份/恢复与 tombstone 保留；未知外部效果只核对原回执，不以代码回退重新执行。当前不存在可宣称已验证的家庭生产回滚包。

## 角色与文件所有权

| Lane | 专属写入边界 | 共享接口规则 |
|---|---|---|
| Local Integration | master-plan、验收矩阵、候选 manifest、App 组合/Xcode 登记 | 唯一集成人；逐路径审阅，不覆盖主目录 WIP |
| Local iOS | `apps/ios-conversation` 内 Domain / Features / Providers / Persistence 的家庭增量 | Views 只调用应用服务；不在 UI 建家庭权限或执行权威 |
| Cloud Backend | functions 内 `family`、`bootstrap.ts`、`api.mjs`、proactive、core 共用事务与权限适配 | 所有共享 API、bootstrap、core、迁移接口只由此 owner 串行修改 |
| Cloud Memory | functions 内既有 `agent-memory` 模块及约定测试 | 不另建第三套存储；共享 bootstrap/core/API 以补丁交 Backend owner 接入 |
| Independent QA | 独立测试分支、固定输入、故障注入与验收证据 | 不以开发者自测关闭安全门；区分本地、真实 PG、模型、设备 |

迁移/CI/组件包等超出当前 native/functions 写入范围的改动，须先形成精确路径与补丁供决定；本轮不修改这些路径。云任务必须有可读取的真实任务句柄、环境、base SHA、model/effort 及能力回执才能计作启动。本地代理不是云端替代者。

## 接口对齐决策

协议增量候选为 `catpaw.family.v1`，前缀 `/catpaw/family/v1`；仅 capability 明确支持时启用。未部署或旧客户端不支持时保留可读说明并禁用未知动作，不能由本地 fixture 宣告 capability 已开放。既有 `/catpaw/...`、SSE、存储和安装身份保持。

| 对象 | 必须固定的语义 |
|---|---|
| command | `command_id`、`type`、`household_id`、`target_id`、`expected_revision`、`proposal_id`、typed `payload`、精确确认版本/动作集合。actor 从可信会话解析，不能接受请求体指定。新增对象仍有稳定 command ID |
| receipt | `command_id`、请求 hash、`processing/applied/rejected`、对象 ID/revision、错误分类及可恢复方式。`outcome_unknown` 是客户端观察状态；HTTP 202 仅受理，applied 需持久回执 |
| confirmation | 确认绑定 proposal revision、原对象 revision、家庭/成员、日期/时区、一次/整系列范围、受影响提醒、授权期限。任一影响行为的字段变化必须重新审阅 |
| idempotency | actor + household + command ID 唯一；同 hash 返回原回执，异 hash 409。每次查回执/重试先验当前身份与权限，不能借旧回执泄露已撤权内容 |
| revision | 服务端单调递增。所有更正/删除/确认使用 expected revision；冲突 409，保留草稿、最小授权差异和重新审阅入口。旧响应不得覆盖本地已知新版本 |
| atomicity | 领域对象、revision、receipt、outbox 同事务；外部模型、通知、设备动作在事务外。提交及 dispatch 重验权限/generation，过期 lease 不得写终态 |
| unknown | 先 GET 原 command/operation；网络失败或查不到当前可见对象不等于已证不存在。只在同合同明确允许且原 ID 确认可重放时重试同 ID，不生成新 ID 掩盖不确定结果 |
| projection | 今天、对话、我们家读取同一权威对象/revision。离线草稿标待同步；SSE 结束、模型说完成和卡片点击不能显示 applied |
| event | 稳定 event ID、schema version、aggregate ID/revision、causation ID、发生时间和最小 payload refs；按 ID 去重、按 revision 拒绝旧事件，缺号回读快照 |
| isolation | household + parent 复合关联；个人聊天默认私有。当前 membership、visibility、账号/家庭 epoch 共同围栏；无权对象不返回标题、冲突差异或来源 |
| memory | 统一既有记忆面；保存 subject/source/revision/validity/kind。事实、观察、推断分开；更正 CAS、删除 tombstone；检索、缓存、摘要、迟到 job 都受更正/删除与撤权围栏 |

具体 JSON schema、canonical request-hash 算法、迁移字段和旧客户端适配必须在第一个实现片由 Backend owner 提交，并经 iOS/Memory/QA 对齐后冻结；本文件不伪称这些接口已存在。第一片初始化恢复不依赖新增 family API，可在 M0 实施门成立后单独推进。

## 质量与样本

100 条跨会话记忆固定输入见验收目录的 `memory-cases-v1.json`；评分定义见 `memory-evaluation-v1.md`。用例必须包含输入、对象/来源、版本、操作顺序、期望召回与禁止行为，不能只给一句自然语言题目。

M0 冻结供 M3 使用的质量门：有正确目标的查询 `macro recall@6 ≥ 0.90`；错误家庭/主体信息、越权注入、删除复活和更正后旧事实使用均为 **0**；CAS、来源、澄清、删除与权限等确定性必需断言全部通过。负例不进入 recall 分母，未运行/超时/失败不能从各自分母删除。M0 不要求调用真实模型或先达到该质量分数；结构检查不产生召回质量分数。M3 实际模型评测需固定获准路由、提示、输入 hash 和完整结果。首次冻结须完成独立审阅，之后调整样本或阈值必须升版本并保留原失败结果。

延迟严格先测再定：先固定设备、系统、网络、地区、已有路由、上下文/媒体/工具类型，记录发送→鉴权→记忆→排队/DB→模型首帧→首正文→端上首显→终态。至少 30 条合成 trace 只验证串联和日志隐私；真实 baseline 另取获准样本，失败/超时进入分母，取消单列。方案里的 500ms/2s/3s/8s 是未冻结建议，不能充作基线或通过门，也不能相加各段 p95。基线不足时报告未验，不自动换模型或购买资源。

首轮受控日用先由一名成人跑完三旅程，记录遗漏、重复背景交代、催办、纠错与实际完成；具体期间与获准数据在 M5 冻结。8–12 家庭/14 天为后续研究建议，不能在单成人验收前自动招募、扩大真实儿童数据或宣布长期价值达标。既有 AF/FINAL 日用门仍保留。

可靠性输入、失败位置、阈值与证据层见[M1 故障矩阵](../../acceptance/family-companion/reliability-matrix-v1.json)。初始化失败后恢复/100 并发、claim 两周期恢复、100 次取消交错零新结果、每个写点不丢 due、不重复事实、内容标记零日志均为必需门；纯合成反例不代替真实 PG 多实例或设备验收。

以下产品策略尚未冻结，不宣称 M0 已过：年龄范围、普通观察的自动保存触发、媒体/日志保留期和清扫负责人。可审阅的首轮建议为不按年龄推断发展结论；仅显式确认后长期保存；原图/音频不进长期记忆，临时媒体最迟 24 小时清扫；用户删除覆盖来源引用、检索索引、摘要、缓存与未完成派生工作，未知外部效果另行核对；运行日志只保留去内容指标。具体保留期限、备份删除语义与责任人在真实数据处理前逐项定案，未选择不构成保存授权。当前测试全部虚构，原始本机执行材料只在 ignored build 中，公开证据只收敛为无内容摘要。

## M0 进入实现的门

1. 本地目录/主干/规划输入/WIP 归属可核对；已有 Goal 通过工具读回，不重复创建。
2. 各实际执行端的 requested/configured/run model 与 effort 分开记录；不符由用户决定，不静默换档。只有目录支持信息不能算运行证明。
3. dot 协作入口、云后端/记忆/QA 句柄和唯一集成人可识别；未连接 lane 标明缺口。
4. 100 条质量输入与评分规则独立审阅并固定 hash；安全故障矩阵、原生失败基线与回滚方案可审阅。
5. 生产源、迁移/配置、已部署包的 manifest 完成对账；旧审计版本不能冒充今天读回。
6. 第一实施片的明确路径、兼容边界和离线测试入口已就绪，且用户的实施授权/模型约束已满足。

门未齐时继续互不依赖的准备和离线复现；不签收 M0、不启动未核验的云 lane。具体核验结果、阻塞与下一步见主计划和本轮日期证据。
