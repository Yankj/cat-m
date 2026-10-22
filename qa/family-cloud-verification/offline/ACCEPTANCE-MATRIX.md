# 家庭改造离线验收矩阵 · lane A

被测产品基线 `789ad4feceb0680b8e2e5913083c5b834dc63db1`；方案/执行合同 `2419db9b98e2e3bc0e8c850da62418d216fd3bb8`。这是 M0/M1 和相邻记忆风险的独立离线验收补充，不复制本机实施主线、不签收里程碑。用户已确认本机此前Goal已执行，当前本机代码状态未知；本表仅描述此云lane及固定基线，不要求本机停工或等待摘要。owner 为 Cloud QA lane A；集成/最终复核为 Root。每项运行输入、期待值和 actual 见 [EVIDENCE.json](EVIDENCE.json) 对应 ID，脚本没有复制业务实现。

`probes` 固定当前行为，18/18 通过；下表状态按目标行为判定，为 **6 PASS / 12 FAIL**。12 项缺陷探针的绿色结果仅表示缺陷复现。所有家庭文本、账号、模型、数据库和设备参数均为虚构 fixture。

| ID / 阶段 | 输入及前置 | 期待结果 | 实际 | 层级 / 状态 | 证据 / 限制 |
|---|---|---|---|---|---|
| M0-MODEL | 本云lane精确请求 gpt-6.1-sol + ultra | 本云run权威 effective 回读 | 仅请求接受；effective=null；另有一孙级未显式请求且已停止 | cloud能力 / BLOCKED | [配置审计](AGENT-CONFIGURATION.json)；不能称云全体配置满足，不裁定本机配置 |
| M0-GOAL | 当前云任务为普通离线任务 | 云编排关联Goal的只读证明 | 本云任务无创建/状态入口；用户已确认本机此前Goal已执行，未取得其ID | cloud能力 / BLOCKED | 此云ledger的goal_id=null；不创建/恢复/替换或要求暂停本机Goal |
| M0-SOURCE | 分配独立 branch/worktree、固定基线 | 产品输入可核对、写入边界唯一 | 产品 functions/migrations 与基线无差异；只写本目录 | source / PASS | runner 校验产品输入，不要求整个 HEAD 等于 base |
| M0-CONTRACT | 方案 M0 冻结要求 | 权限、wire版本、性能/重试/周期门冻结 | 只有现有 v1 与提案；CAS扩展、退避/lease周期待决 | M0 / BLOCKED | 不把本表的可执行目标当新协议权威 |
| M0-RELEASE | 统一 App/后端/迁移/部署/config manifest | 同版 manifest 读回 | 当前仅源码 SHA；无线上/本机授权与读回 | M0 / BLOCKED | release_manifest=null |
| BOOT-01 / M1 | 同一个真实 handler，100 并发健康请求 | 全部200，仅1次初始化、保留/释放平衡 | 100个200；构造/角色查询/保留/释放各1 | offline / PASS | bootstrap.test.mjs:20；SQL驱动stub，不验证JSON wire |
| BOOT-02 / M1 | 1次角色探针失败503，依赖恢复后同handler再100并发重试 | 100个200；只1次恢复初始化，无泄漏 | 100个503；角色查询仍1、构造仍1 | offline / FAIL | bootstrap.test.mjs:29；共101请求；当前目标为立即重试，退避时长待M0 |
| BOOT-03 / M1 | 空合成配置 | 503 configuration_missing；不构造DB驱动 | 符合 | offline / PASS | bootstrap.test.mjs:40附近；不读宿主凭据 |
| REM-01 / M1 | 真实store领取1条后丢弃worker，新worker共用store | 2个合成周期内1条持久结果、不重复 | 后续2 tick均claim0；due悬挂、event0 | offline / FAIL | reminder.test.mjs:18；不是OS进程kill/持久PG重启 |
| REM-02 / M1 | 100条due，先领取前50后中断 | 2周期内完成100条且不饿死后50 | 后续claim0、event0、fire_count完成0 | offline / FAIL | reminder.test.mjs:29；周期=合成60秒；SQL仅静态对应 |
| REM-03 / M1 | 100独立实例；model等待、owner读前/后、event写前各25交错 | cancel提交早于event时0新event/dispatch；取消状态保留 | 100新event+100模拟dispatch；100仍cancelled/next=null | offline / FAIL | reminder.test.mjs:39；100分母；APNs是无网络函数 |
| REM-04 / M1 | reminder insertEvent写前失败1次，后续重试 | event1、fire_count1、下一due=13:00Z | event0、fire_count1、next=null | offline / FAIL | reminder.test.mjs:68；store端口故障，不是DB COMMIT故障 |
| REM-05 / M1 | finishOccurrence写前失败1次 | 不丢后续周期：event1、count1、next=13:00Z | event1、count1、next=null | offline / FAIL | reminder.test.mjs:78 |
| REM-06 / M1 | 正常finish和catch内finish均失败；之后存储恢复 | 下一due恢复，已有event不重复 | event1、count0、next仍12:00Z；claim卡住 | offline / FAIL | reminder.test.mjs:87；2周期恢复观测 |
| REM-07 / M1 | claimDue mutation前失败；随后恢复 | due保留、后续event1/count1/next正确 | 符合，无重复 | offline / PASS | reminder.test.mjs:96；不覆盖claim提交后unknown |
| REM-08 / M1 | finish真实写入后丢失ack | 持久事实/下一due正确，无重复 | event1/count1/next正确 | offline / PASS | reminder.test.mjs:107；首tick仍报fire_failed，不能称接口成功 |
| REM-09 / M1 | task创建已存、task_created event失败；同op重试 | task1且event补齐1 | task1、created event0 | offline / FAIL | reminder.test.mjs:117；原operation identity保留 |
| MEM-01 / M1→M3 | 旧HTTP编辑在embedding await暂停；新更正200后放行旧写 | 旧写409，保留新更正 | 旧写200并覆盖新更正 | offline / FAIL | memory.test.mjs:18；现v1无content-CAS参数，409 wire需M0冻结 |
| MEM-02 / M3预验 | 更新await时DELETE成功，再放行更新/下轮recall | 行和召回0，sync墓碑1 | 符合；迟到HTTP另报500 internal_error | offline / PASS | memory.test.mjs:29；只通过“不复活”，不代签错误响应/原生缓存 |
| MEM-03 / M3预验 | journal已取fragments并等待summary；clear成功后放行 | 清除后row0、recall0 | 新journal1且下轮recall1 | offline / FAIL | memory.test.mjs:42；无真实模型/索引/原生cache |
| MEM-04 / M3预验 | 已保存行被DELETE；重放原memory_save operation_id | 原op不能重新创建已删内容 | 新row1、下轮recall1 | offline / FAIL | memory.test.mjs:56；无新的allow_relearn/同意 |
| MEM-05 / M3预验 | takeFragments之后journal insert失败，再tick | fragment可恢复，journal1 | fragment0、journal0、retry written0 | offline / FAIL | memory.test.mjs:65；真实PG多用户失败未运行 |
| SAFE-01 / M0 | 禁网guard的6个主动自检 | fetch/socket/TLS/HTTP/HTTPS/DNS均传输前拒绝 | 6/6拒绝；其他case attempted network=0 | offline / PASS | network-guard.test.mjs:10；此项为harness安全，不是产品功能 |
| M1-LOG | 合成敏感标记运行日志 | 运行日志内容泄漏0 | 本lane未验；仓库静态敏感扫描无命中 | M1 / NOT_RUN | 静态扫描不能替代内容日志门；其他lane结果不在此代签 |
| M1-TRACE | 30条合成跨层trace | 全部拼接完整时序 | 未实现/未运行此分母 | M1 / NOT_RUN | 当前脚本仅有用例诊断，不能冒充产品trace |
| M1-PG | 多实例、lease、SQL约束/事务与RLS | 隔离PG并发/回滚/重启实证 | 未运行 | isolated PG / NOT_RUN | 无Deno/PG服务/新依赖/真实Supabase访问 |
| M1-NATIVE | 必需原生全套、历史失败逐项归因 | 同候选原生必需故障无未归因项 | 未运行 | device/native / NOT_RUN | Node v24.19.0；本环境无Swift执行证据 |

未运行、BLOCKED 和 FAIL 均不折算通过。本云lane不能签署M0/M1，不对本机主Goal当前阶段/代码状态下结论；记忆检查是获授权的相邻风险预验证，不能替代M2/M3。此云lane没有执行真实模型、Auth、线上 Supabase、生产迁移、通知、真机、部署、签名和付费操作。
