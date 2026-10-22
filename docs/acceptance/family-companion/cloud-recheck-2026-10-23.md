# dot 验证资产：本机候选复跑回执

2026-10-23。被测候选 **`88c71ac753bb2f52fa6ddbe2a1c25b6629293946`**（`docs/family-m0`）；验证资产 **`b5d365f8c8cd49a0525f6ae76d18af74b9759567`**（`test/family-cloud-verification`）。[机器回执](cloud-recheck-2026-10-23.json)保存命令、18项实际观察、源码/输出hash和证据边界。实时进度见[主计划](../../status/master-plan.md)。

已优先读取云端HANDOFF。云分支相对`789ad4fe`只新增`qa/family-cloud-verification`内39个普通文件，没有产品或共享协议改动。Root在候选的独立`test/family-local-recheck`工作树精确导出这39个文件，复跑后逐一确认字节未变，原云报告没有覆盖。新输出只写ignored执行目录，再收敛为本回执。

本候选包含M0准备资料、100条记忆固定集、来源映射及两个历史原型共12处链接修复；**产品修复项为0**。原生、functions、migrations均与旧产品基线字节一致。这是对新候选实际执行得到的结果，不能把相同结果归因于未经测试的后续修复版本。

## 三组分母分别报告

| 测试集 | 本机实际执行结果 | 可证明的范围 |
|---|---|---|
| 新增故障目标断言 | 18项完整执行，6 PASS / **12 FAIL** / 0 SKIP；exit 1 | 真实维护模块与合成驱动/内存存储的离线目标断言 |
| 既有定向测试 | 20文件，223项：222 PASS / 0 FAIL / 1 SKIP；exit 0 | 另一套既有Node测试；不能抵消上面的12 FAIL |
| 家庭权限fixture | 32/32 oracle自洽；**真实权限0/32执行，全部NOT_RUN** | 尚未接真实权限层，不表示权限通过或已经越权 |

本次只运行`targets`，没有把“旧行为复现成功”计作产品通过，也没有将18个探针加18个目标断言算作36项。

## 仍失败的12项

| ID | 本机实际观察 |
|---|---|
| BOOT-02 | 首次初始化失败后，同实例后续100次全部503，恢复0次 |
| REM-01 / REM-02 | claim放弃后两周期无法重领；批量任务无法恢复并出现饥饿 |
| REM-03 | 4处交错各25次；取消先完成后仍产生100个事件、100次假dispatch；没有真实推送 |
| REM-04 / REM-05 / REM-06 | 写入失败后出现丢due或事件、次数、下一次执行时间不一致 |
| REM-09 | 任务创建成功但对应创建事件缺失 |
| MEM-01 | 迟到更新返回200并覆盖较新的更正，未返回期望的409 |
| MEM-03 / MEM-04 | 清除后的迟到journal或原operation重放重新创建内容 |
| MEM-05 | journal写失败后fragments已清空，重试不能恢复片段 |

6项窄PASS为BOOT-01、BOOT-03、MEM-02、REM-07、REM-08、SAFE-01。它们不关闭完整初始化、记忆、提醒或权限验收；例如MEM-02只检查该交错不复活，不证明其HTTP错误语义正确。

## 额外安全证据与运行边界

本机另执行9项记忆现状探针，保留7项缺口与2项支持性结果；不与18项重复相加。日志探针再次确认合成canary进入真实proactive logger，零内容日志门FAIL；未读取生产日志，不声明已有真实数据泄漏。静态审计定位16个anchor，44个源文件pin匹配，不是原生日志运行验收。

已有Node `v24.19.0`，无需安装依赖。各命令以清空环境启动；B探针在静态产品import之前预载完整offline prelude/loader。独立审阅覆盖169个字面相对导入闭包文件，未发现联网CLI或网络子进程；JS guard不是操作系统网络沙箱。

```text
node qa/family-cloud-verification/offline/run.mjs targets --candidate 88c71ac753bb2f52fa6ddbe2a1c25b6629293946
node qa/family-cloud-verification/run-existing-offline.mjs
node --import ./qa/family-cloud-verification/offline/offline-prelude.mjs --import ./qa/family-cloud-verification/offline/offline-loader.mjs qa/family-cloud-verification/security/run-fixtures.mjs
```

其余B入口`run-source-probes.mjs`、`run-log-probe.mjs`、`source-audit.mjs`使用同样预载方式。B的source pin和静态Git读取仍固定`789ad4fe`；本回执另外逐项核对它们与候选`88c71ac`当前源码相同，没有伪改原pin。以后产品字节改变时，必须先审阅并版本化适配，不能原样外推B结论。A生成报告和既有wrapper内的cloud/model/base字符串是原脚本历史字段，不能当作本机运行端或云端effective model证明。

**真实PG/RLS/多实例、真机、图片/音频端到端、真实模型质量和真实通知均NOT_RUN；部署0。** 本轮不签收M0、M1或产品。

## 新增家庭与交互标准的接收边界

用户补充12个家庭场景/36条可观察断言、10类交互状态/14项UI检查；统一版本化入口尚未提供，本轮远端family分支查询也未发现新增入口，暂不虚构ID或合并数量。收到正式文件后再映射现有97项矩阵并去重。重点保留：未确认的接送不能说已安排；一次性安排不能变成永久记忆；取消后旧结果不能复活；模糊输入先澄清；主动提醒不能增加家长负担。所有新增场景是待验收标准，图片和音频脚本不代表多模态实测通过。

## 独立复核与仓库检查

独立QA直接核对原TAP、JSON、Git与Root回执，0 findings：18个唯一目标ID及分母一致，39份QA文件和13份原始输出hash/大小匹配，9项A source binding与44项B pin均绑定候选字节；产品修复0和各项NOT_RUN保持。独立报告SHA256为`ae6d3851ec2ba793f108fa4f4b4b88295488bce822acdd8ab13c4a6396ceaaee`；机器比对为`7bfd7124cc49ed956d202675e7abfe813675e9d6f94c7963ca2e391d73a2b295`，原始报告保存在QA工作树ignored build，未伪称又执行一轮产品测试。

最终布局、冻结源、部署快照、AF切片/Goal、FINAL、CG七项静态检查通过；新文档链接与45项输入hash通过；敏感扫描1810个候选文件，0 blocking / 0 manual review，豁免规则未改；whitespace检查通过。提交本回执只增加证据与索引，不改变被测产品源码。
