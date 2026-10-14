# W31：选定报告的自然语言修改与原请求恢复

日期：2026-10-14。候选 `AF-W31-CONTINUE-20261014-05`，基线 `d02f1e7a37de75ccaf1292440698e3781afc5abf` 的准确 SHA 以 [RESULT](evidence/report-continuation-20261014/RESULT.json) 为准，分支 `feat/s03-report-continuations`，原生版本 `0.3.0(21)`。本记录固定维护源码与离线验证；当前进度仅维护 [master-plan](../status/master-plan.md)。本片不签收真实 W31、CP-01、AF-G5 或 FINAL-G3。

## 用户行为与实现

用户从正在阅读的不可变版本选择“请 Agent 修改这版”或“针对这版追问”，返回同一个对话输入器。模式与选定版本可见；修改、追问和普通聊天分别保留本地原文。退出仅保留草稿并恢复普通输入；不会取消已受理工作。组合输入期间不能切换或退出模式。新模式收起图片入口，保留原普通输入的本次 App 会话图片状态；没有扩展图片冷启动持久化。

兼容扩展 `catpaw.task-revision.v1` 在新 turn 上绑定原 run/task、exact artifact/version/hash、许可 epoch 和计划 revision/hash。普通 `/chat/v1` 请求结构与原绑定保持；只读追问的模型 tools 为空，语言中的“修改”不能产生写入。修改只允许 `revise_current_report_v1`，完整模型 round 验证后才写操作、计划与续接关系；新委派、未结束或混合非法 round、单纯正文都不能冒充同工作修改。

服务端分别冻结新原文、选定 body、原受理来源和新会话来源。沿用现有模型路由与原 scope，重开同一个 Task，保留原 frozen request、旧版本、旧步骤回执与 checkpoint。新计划使用独立 compose/save/verify、每个发布版本及结果回执；有原来源目录的报告重新读取同一目录。模型纠正中间稿可产生多版，不能用旧 save/finish 回执宣布新修改完成。实际 worker 结算和结果验证分开；GET 与原 turn 重放不调用模型或唤醒 worker。执行中的冻结修改不能被普通计划修改替换。

原生适配器从可信账号组合取得 subject，读取原委派绑定与 exact 选定版本；调用者不能用 target 字段替代账号权威。请求保留原 UTF-8 字节，受理回执校验跨 Node/Swift 的 canonical hash、原文 hash 和稳定 operation ID。网络丢失、格式不明的拒绝及 EOF 都保持待核对；只有正确版本的明确 JSON 拒绝证明未受理。恢复只 GET 原 turn/operation。当前工作已在其他客户端推进到更高计划或成果版本时，读取原 operation 指定的历史结果，再保留当前投影；不偷偷改用最新版本或绑定新 Task。

## 审查与保留的失败

根任务审查发现原生原文/op ID 错用 JSON 字符串 hash；修为原始 UTF-8 hash，并以 Node 生成的回执对照。后台旧 local_model 状态、旧步骤和结果结算边界由实际两种 worker 回归覆盖；修复在实际 Task succeeded 前不能将结果标成 completed。另补同 operation 中间纠正版本的发布证明，以及下一次修改期间前次完成仍可查。

原生首轮 10 项有一个测试会话响应漏了 state/policy；随后保留私有错误类型引用编译失败，以及 URLProtocol 请求体经 stream 传递导致夹具崩溃的失败日志。修复夹具后 17 项单元通过。最大字号早期导航手势命中浮层，已按真实可见区定位。初次 UI PASS 后截图发现标题挤掉版本号、编辑空间不足，保留该视觉失败；改用中间省略保留 v2，并缩短最大字号状态和限制该模式输入高度。最终截图可见版本、末行与光标；编辑器和 44pt 发送按钮完整位于预测输入栏上方。

两次整合轮次在发现布局与跨版本恢复问题后主动中断，保留日志和各自输入 manifest，均不计整轮 PASS。实际维护运行时通过两次同 Task 执行生成的离线 JSON 进入原生 URLSession，用来验证当前 v3 下找回原操作 v2，全部 GET、零 POST；该 fixture 的模型、Store 和 reader 都为显式离线注入，不是云端回执。历史测试附件名称保留原 v20 标签；本轮包读回为 21，仅归档六张本片 v21 合成截图。

## 固定验证与限制

最终统一 **81/81 原生 PASS（65 单元、16 实际 Simulator UI，0 失败/跳过）**；**206/206 后台离线 PASS**；37 续聊、86 本机 HTTP/SSE、16 队列回归通过。Release Simulator `0.3.0(21)`、93 宿主 source memberships、910 双语、187 固定 SDK 输入、41 改动 source/test/config、六张合成截图及日志/包 hash 见 RESULT。目录、冻结来源/MIT/精确 patch、部署快照、AF/FINAL/CG 合同、敏感与空白检查通过。不同证据层不相加；没有将组件或 Simulator 通过改写成产品通过。

新来源会话撤权后，dispatch/publication 已被阻止，旧完成也不能复用；pending Task 仍可能留在 scheduled，清楚的可恢复阻断状态继续由 W33 交付。真实 Supabase SQL/多实例、模型和公开来源请求、独立调度、EventKit 效果、真机连续手势/性能/可访问性、七天日用及具名竞品比较仍未验证。本片新手机包、安装、部署、推送、依赖/凭据和计算支出均为零。现有 build16 两次短文本授权仍未使用；16:54–55只读镜像显示 iPhone 使用中、镜像已结束，需锁定 iPhone 后连接，未进入 App 或点击连接。旧 Mac 认证锁定保留为早前日期事实。

下一片按 W33 接管/撤权/unknown 与原生 GenUI producer 继续；同版手机/API/tick候选及具体清单齐备后，再处理必要安装和真实验收批准。长期 FINAL-G3 保持 ACTIVE。
