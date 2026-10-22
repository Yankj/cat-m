# 云端独立验证交接 · 2026-10-22

给本机团队的入口。这里只交付固定版本的失败复现、隔离测试和验收证据；未改产品、共享协议、迁移或主计划，未合并 main，也不代表 M0/M1 或产品集成完成。

## 认领与版本

- 交付分支：`test/family-cloud-verification`，仓库 `Yankj/cat-m`（ID `1413057312`）。最终交付 commit 以父任务回执和分支 tip 为准。
- 被测源：`789ad4feceb0680b8e2e5913083c5b834dc63db1`；契约/技术方案/设计索引：`2419db9b98e2e3bc0e8c850da62418d216fd3bb8`。方案分支没有合入本分支；14 项资产字节/hash 全部与 manifest 一致，见 [BASELINE.json](BASELINE.json)。
- A：`test/family-offline-regression` / cloud-offline，仅写 `offline/`；B：`test/family-security-review` / cloud-security，仅写 `security/`。root 在自己的 worktree 明确路径汇集两者产物。详细边界见 [OWNERSHIP.md](OWNERSHIP.md)。
- 实际修改文件逐项列于 [FILES.json](FILES.json)，均为本目录新增测试/fixture/证据。未认领任何客户端/后端实现或共享协议文件，后续修复 owner 由本机 lead / 父总指挥明确。
- **本机承担主 Goal 实现，用户已确认正在执行；代码状态未知。云端是独立验收补充，不再等待本机摘要。** 父会话读取本机线程曾因 placement format 版本不支持、发送因 NotFound 未成功，因此没有直接对接或本机接受云端安排的证据。没有访问目标 Mac 或其会话存储。

## 已执行与证据层

| 入口 | 本轮结果 | 能证明的范围 |
|---|---|---|
| `node qa/family-cloud-verification/run-existing-offline.mjs` | 20 文件，223 项：222 PASS / 0 FAIL / 1 SKIP | 现有 Node harness、真实维护模块、内存 fixture；PG 依赖项跳过；不是全套 Deno |
| `node qa/family-cloud-verification/offline/run.mjs all --candidate 789ad4feceb0680b8e2e5913083c5b834dc63db1` | 当前行为探针 18/18 复现；目标断言 6 PASS / **12 FAIL**，组合命令退出 1 | 真实 bootstrap/service + 合成驱动/内存 store；不是强杀进程或真实 SQL 事务 |
| `node qa/family-cloud-verification/security/run-fixtures.mjs` | 32/32 fixture 自洽；真实家庭权限 **0/32 执行，全部 NOT_RUN** | 拟定策略 oracle，自洽不等于授权实现通过 |
| `node qa/family-cloud-verification/security/run-source-probes.mjs` | 9/9 当前行为复现，7 缺口 / 2 支持性结果 | 当前记忆 service + 内存 store；与 A 重叠项不重复签收 |
| `node qa/family-cloud-verification/security/run-log-probe.mjs` | 合成 canary 进入 proactive logger，零内容日志门 FAIL | 捕获 logger 参数；不是已观察真实数据泄漏 |
| `node qa/family-cloud-verification/security/source-audit.mjs` | 16/16 anchor，44 源文件 pin MATCH | 静态来源定位；原生 `.public` 日志未运行 |
| `python3 scripts/check-repository-layout.py` | PASS | 目录/宿主边界 |
| `python3 scripts/check-repository.py` | PASS | 冻结来源、原始字节与归属 |
| `python3 scripts/check-deployed-source.py` | PASS | 部署快照身份及既有 14 个共享文件差异保留 |
| `python3 scripts/scan-repository.py` | PASS | 已知敏感模式静态扫描；不是运行日志验收 |

现有测试输出摘要、hash 与限制见 [BASELINE.json](BASELINE.json)。root 对汇集后的 A/B 脚本独立复跑结果见 [ROOT-RECHECK.json](ROOT-RECHECK.json)。原始 stdout 放忽略的 `build/family-cloud-verification/` 及 `offline/build/`，不提交运行缓存。运行脚本要求现有 Node v24+，不自动安装依赖。

具体失败：BOOT-02 同实例先失败后 100 次均 503、只初始化一次；REM-01/02 claim 放弃后两次模拟调度均无恢复并阻塞后 50 条；REM-03 四个位置各 25 次取消交错，取消先于提交仍产生 **100 个事件与 100 次模拟 dispatch**；REM-04/05/06/09 写失败产生丢 due/终态不一致/创建事件缺失；MEM-01 迟到更新覆盖纠正、MEM-03/04 clear/journal 或原 operation 重放后记忆重现、MEM-05 journal 写失败丢 fragments。模拟 dispatch 没有发送真实通知。

独立故障探针和家庭/安全 fixture 的命令、分母、源码行号见 [A 报告](offline/REPORT.md) 与 [B 报告](security/README.md)；探针确认缺陷时的绿色退出码只表示复现成功，不能当产品目标通过。

原有 222 PASS 与新增 18 项目标断言属于不同测试集；新增 12 FAIL 是故意补出的验收红灯，不能相互冲抵或混作同一套。18 个当前行为探针与 18 个目标断言也不是 36 个独立用例。[逐项分类](ASSERTION-MAP.json) 将每项映射到已知缺陷、新具体发现、未实现能力及夹具限制，并保留原验收分母。

## 五条可行动结论

1. **初始化自恢复缺陷已复现**：同实例失败后 100/100 仍 503。先关闭 BOOT-02 红灯，同时保留 BOOT-01 的100并发 single-flight。命令：`node qa/family-cloud-verification/offline/run.mjs targets`。
2. **提醒恢复/取消/写点不能由任务状态签收**：REM-01–06/09 暴露 claim 饥饿、取消后事件与模拟 dispatch、写失败丢 due/事件。命令同上；本机修复后用 `targets --candidate <完整40位SHA>` 保持分母复验。
3. **记忆纠正/删除/journal 需要统一复验**：MEM-01/03/04/05 是目标红灯；MEM-02 的不复活窄PASS仍伴随500。命令同上；来源/operation/hash附加缺口命令：`node qa/family-cloud-verification/security/run-source-probes.mjs`。
4. **真实日志入口接受了合成内容**：LP-01 在真实 `proactive/service.mjs:201` 捕获 `log('error', e.stack ?? e.message)`，输入仅为合成 listTasks 错误；`catpaw-proactive/index.ts:26,44` 的 console 接线是静态证据。命令：`node qa/family-cloud-verification/security/run-log-probe.mjs`。没有读取生产日志或真实家庭数据，**没有已有生产泄漏证据**；原生 `.public` 路径也仅静态发现。
5. **家庭权限32例尚未接真实权限层**：0/32 NOT_RUN 不是32次已证越权；固定base缺少家庭API/对象权限实现。先把fixture映射到本机实际候选的权限层，再验跨家庭/私有/撤权和receipt。fixture命令：`node qa/family-cloud-verification/security/run-fixtures.mjs`；只读源码依据：`node qa/family-cloud-verification/security/source-audit.mjs`。策略oracle不能当真实RLS证明。

## 尚不能签收

- **模型/Goal**：两个主子 Agent 显式请求并获接受 `gpt-6.1-sol + ultra`，A 的只读审阅子 Agent 也显式请求；bundled catalog 支持该组合。本次 root/子 Agent 的实际执行 model/effort 均无权威回读，记录 null / UNVERIFIED。B 的只读辅助 Agent 及 A 下属的孙级 SQL 辅助 Agent 未显式固定配置，已结束/被中断，相关证据由 A/B 主 lane 独立回读重跑，不能把全部 Agent 说成已验证。见 [CAPABILITIES.json](CAPABILITIES.json) 和 lane ledger。
- CLI 0.159.2 的 goals 开关及 Goal schema 存在，但当前云任务没有可调用 Goal 创建/状态工具与已核验 native thread binding；云端 `goal_id=null`、未创建独立原生 Goal。这是用户明确授权的普通离线验证准备，云端 M0 能力证据未闭合，不用于判断本机 Goal 阶段或要求其停止。
- 没有 Deno/已有公共依赖 cache、Swift/Xcode 或真实隔离 PG；未验证 PG/RLS/多实例事务、真机、真实模型质量、通知或部署。
- 100 次取消和两周期重领的离线目标已经 FAIL；真实 PG/进程层仍未验证。家庭权限及中文 recall 门槛待合同冻结与真实层复验；离线 fixture 通过不关闭这些验收。

本机拿到分支后可在自己的隔离验证 worktree 执行上述入口及 lane 报告命令；不要把旧 SHA 的行为复现结果当作修复候选结果。修复候选可通过 A runner 的显式 `--candidate <完整40位SHA>` 重建源码身份并保留相同分母。产品与协议修复由本机主线处理；本分支只提供复验材料。
