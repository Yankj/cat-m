# 有限工作执行与原生日程服务接线片

2026-10-15。候选 `AF-W50-W60-INTEGRATION-20261015-02`，基于本地 `bfaea758502c27e1e0948d260cc3c088f2a70aaf`、远端功能分支 `a7ad5d78a9557e66904c72555a824f00d7e904cb`。固定输入及验证边界见 [RESULT.json](evidence/bounded-work-integration-20261015/RESULT.json)。这是实际维护服务的离线接线验证，W50/W60、CP 和总产品验收仍未关闭。

新的 versioned work-intent 入口把用户原文、当前模型路由、明确期限和调用预算绑定到原请求，同事务形成 run、可修改计划、有限 grant 及受理回执。原 v1 发送和 model consent 不自动产生这种授权。实际有界 worker 在 claim/dispatch 前消费原预算，成功或确定失败回执必须来自原操作；unknown 不退款、不补发。持久 received 结果允许有界本地保存、核验与原 attempt 终态结算，不再误用前一次网络窗口。有限 whole 执行明确不支持，普通旧路径保持严格原来源检查。

用户可通过既有控制合同查看、暂停、恢复或撤权同一有限工作。恢复须同时满足原 grant 和原 due 中较早的截止时间，最后一次等待跨截止也回滚；closed/unknown 原 due 不能因旧 paused 投影而重开。查看和新控制需要当前身份，已受理执行检查原有限授权及当前撤权事实，两者没有通过布尔选项互相放宽。logout、同对话 consent 撤销与有限 grant 撤销在原事务中组合；共享来源与 grant 锁前序覆盖计划、审批和成果服务。清理只提供精确记录屏障，缺真实物理删除能力时继续拒绝。

原生 v2 设备效果应用服务复用现有 `NativeChatHTTPBackend` 的身份、URLSession 和 scoped Repository。UUID 与冻结请求先落盘，再 POST；丢失响应后重新创建 Repository 也只 GET 原操作。缓存回执不能还原 dispatch permit，只有首次有效响应的进程内 permit 可以预约消费。GET 404 保持原 unknown；POST 404/401 或响应丢失不被当成可安全重发。系统动作和 App producer 默认仍未配置，未新增 EventKit/通知执行能力。

| 验证 | 最终结果及范围 |
|---|---|
| 完整维护后台 | 338/338 PASS；已有公共依赖缓存、禁网络、忽略环境变量，合成 Repository/provider/reader |
| 实际 Cloud HTTP 受理及 worker 组合 | 12/12，计入 338；包括原 session 到期后按原有限预算完成同一报告、没有 session 续期，以及原工具回放零域写入 |
| 实际 bounded 执行 | 11/11，计入 338；模型/来源 dispatch、确定失败 ledger、收到后本地收尾、原 ACK、撤权/接管/预算边界 |
| 原控制与生命周期 | 16/16，计入 338；邻接 24/24 包括 7 个既有来源及 1 个 logout 用例，不重复相加 |
| 原生持久服务、HTTP 与纯合同 | 10＋7＋8 组 PASS；真实 FilePersistence/Repository/URLSession 执行，URLProtocol 拦截 `.invalid` 合成服务器，41 个编译输入冻结 |
| 原生宿主源检查 | non-DEBUG iOS Simulator SDK typecheck、102 App 成员、3 targets、969 双语条目 PASS；2 个生产文件与 3 个测试文件已登记，没有 App 链接/XCTest/新包安装声明 |
| 仓库治理 | 布局、冻结来源、部署快照、AF/FINAL/CG 规划、共享语义字体、敏感扫描与空白检查 PASS |

独立反例在实际旧维护执行器复现 5 FAIL；原 due 提前到期、最终等待跨截止、原工具回放剩余窗口减少分别保留 RED 并用同一反例验证 GREEN。首轮 Root 8/10 保留：运行时 lease housekeeping 不等于重复域受理，错误 expected_revision 先挡住 expiry；修正测试路径后固定源码再运行。Swift 首次测试辅助函数及语法失败也保留。敏感扫描只更新四条已复核负向 fixture/记录名的精确 hash 与行号，没有放宽检测规则；说明文字自身误命中已修正。

readiness 的 `accepted_work.enabled` 来自实际维护执行器组合，限定 `bounded_single_step_v1`、单 run、显式预算；`native_producer:false`、`independent_scheduler:false`、`live_verification:not_verified`。它不是模型、后台托管或设备验收。真实 PostgreSQL 多执行者、外部 Auth 撤销信号、真实模型/来源、App 有限意图输入、离开 App 后执行、独立调度、可信设备 target/receipt 和真实 OS 日程仍未验证。原模型路线与 build16 第一条失败保留，第二额度未用；没有部署、依赖或凭据安装、付费计算、provider/fallback 更改。

当前可点测版本仍是已固定 build23。本片没有新 App 包或手机安装。下一片把明确范围、期限和预算的受理入口接入原生对话与可找回确认，固定同版 Simulator 用户路径；日程 API 信任链与系统效果按依赖并行。当前进度只维护 [master-plan](../status/master-plan.md)，本文件保留日期事实。
