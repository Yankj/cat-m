# W30a：同任务计划修改、恢复与原生本地状态

日期：2026-10-14。候选 `AF-W30-CGUI-20261014-02`，基线 `8104cf2`，分支 `feat/s03-plan-persistence`。39项修改源码与测试逐字节hash见[RESULT](evidence/plan-recovery-20261014/RESULT.json)；实时进度仅维护[master-plan](../status/master-plan.md)。本片是离线维护源码和原生 Simulator 证据，不签收 AF-A07、CP-01 或 FINAL-G3。

## 实际行为

- 现有报告任务持久保存计划 v1，原始 turn/run/task、许可和 frozen request 不变。修改按 expected revision/hash/grant 与原 operation UUID 受理；accepted 和 applied 分开，执行中的新版在原 worker 的安全点生效。旧成果不能结束新计划，实际 model response、artifact saved 和 completion validated 回执绑定执行版本。终态/暂停工作暂不开放改稿，固定单份本地报告的结束条件不由修改扩权。
- 新计划工具 delegate_plan_v1 与独立 catpaw.task-plan.v1 读写端口接入维护 API 和同一个 scoped Store；旧 delegate_task 与冻结 HTTP v1 继续兼容。当前仅使用已提供资料做本地报告，未宣称自主搜索或网页读取。普通问答不产生任务的证据来自合成 provider。
- 新修改提交后复用现有有界原 turn worker 唤醒，同 turn 串行，权威来自原始 frozen source。实际 API 离线测试从 waiting_input 经修改到同任务 v2 成果/完成，不手动 tick。GET、相同 operation 重放、blocked_unknown 不唤醒或重发；这仍是最多六片/六十秒最佳努力工作，W50 独立调度未完成。
- 原生对话计划卡打开大 sheet；可查看当前执行步骤与实际回执、编辑目标和要求，返回/关闭保留修改草稿，聊天草稿独立。读取和提交中继续输入不被迟到响应覆盖；CAS 冲突保稿并要求重新读取/明确重基。提交前持久保存原 operation，unknown 只 GET 它，不能自动创建新提交。草稿保存失败禁止关闭，支持明确放弃；本地每项上限 8000，提交每项上限 4000。
- 本地账号空间与真实 server scope 分开验证，logout 关闭旧服务，迟到读取不能填入新账号缓存。合法长计划的 accepted/applied 双份 envelope 保持可读，原生响应仍限 512000 字节、修改请求限 48000 字节。
- GenUI 的筛选/排序、图形选择、试算原始输入和重置存入既有 Repository，身份固定 conversation/turn/block/data revision/payload hash/artifact version/schema/renderer。完整表和预览共享状态；恢复期间禁用相应输入；未知本地格式可读降级并保留原字节，明确重置才替换。本地选择不能受理任务或触发模型。
- 原生冷启动保留尚未完成的负号输入。试算精确负值即使展示舍入为 0.00，仍显示超预算提示与原值；继续保留引用草稿、流中本地编辑和阅读锚点。

## 验证与限制

| 验证 | 实际结果 | 证据边界 |
|---|---|---|
| 维护后台 | 87项离线PASS，其中14计划服务、6实际维护HTTP回归 | 实际类/事务端口＋合成TestRepository/provider，public cached-only/deny-net；无真实PG或模型 |
| 原生最终候选 | 25个XCTest，0失败、0跳过：18单元方法＋7实际UI | 11计划、4传输、3内层矩阵方法；64算法/26状态/8对话案例不是额外XCTest数 |
| 原生UI | 同任务v2、两份草稿保留、原修改unknown GET、完整表共享筛选、无效原始输入SwiftData冷启动、负值舍入提示、引用与阅读锚点PASS | iPhone17/iOS27.0 Simulator；每路径显式offline fixture，无外部网络 |
| 独立持久回归 | 21续聊、16队列、26 GenUI状态案例PASS | FileRepository/合成事件；不替代宿主或生产调度签收 |
| 构建与静态 | Release模拟器0.3.0(18)PASS；77宿主成员、3 targets、751双语资源PASS | 无手机签名包或生产配置复制；最终production source与Release输入一致 |
| 治理与敏感 | 目录、冻结来源、部署快照与AF/FINAL/CG规划、空白和候选敏感扫描PASS | 保留MIT/受控patch/历史资产与API19/tick7差异；known-pattern扫描有其范围 |

保留编译与原生失败日志、账户空间RED→GREEN、64KiB合法计划响应拒绝的修正、计划卡遗漏/子标识覆盖、表格重复标识及键盘实际阅读区域的定位轨迹。后几轮只调整测试手势，没有改动冻结的Release production source。最初两次失败后的Simulator诊断收集挂起，只停止了本任务的诊断子进程并保留测试结果；后续关闭冗长失败诊断收集，测试与附件正常保留。

最终计划v2截图按原字节保存在忽略的 `build/goal-plan-20261014/native-plan-applied-v2.png`，来源是最终XCTest附件；版本、reality与hash见RESULT。它显示accepted/applied v2、修改要求与尚无步骤完成回执，不能当成真实任务已完成。未导出私人手机或参考内容。

真实 Auth/模型/生产 SQL、多实例、实际 cloud 继续、物理 iPhone 安装与体验、独立调度、真实图片、记忆、审批 effect、日程、七天日用和具名竞品配对均未由本片验证。现有真实产品门保持 NOT_RUN。GenUI 仍是编译 receiver 和显式 DEBUG fixture；实际模型 producer/HTTP 卡片，以及同工作明确跟进尚待实施。

现有部署快照 API19/tick7、50/43 文件与 14 项共享差异保留，维护修改未部署。模型配置沿用既有 route，未切换或打开 fallback；新增计算预算为零。Release 模拟器 0.3.0(18) 不作为手机安装包；先前冻结 build16 和最多两次原路由短文本授权不被扩展。

下一片沿 W31 真实公开资料读取与有来源成果、W32 精确审批推进 CP-01，再 W33 接管/撤权/unknown；W20/W40、设计与原生 GenUI 可以按依赖独立推进。部署与后续手机候选须准备好同版源码、包和验证清单，再按具体授权执行。
