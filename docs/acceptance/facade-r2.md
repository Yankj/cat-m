# façade r2 历史独立验收

来源：r2独立复验最终报告，2026-10-11，限定合成本地实现。未运行 SQL 多实例、完整 SDK、真实模型、Intelligence、部署或 iOS 客户端。本页为可移植摘要；精选 TAP 为原测试输出路径去标识副本，原/副本 hash 在 [导入 provenance](../status/import-provenance.json)。

| 实际集合 | 通过/失败 | 保存证据 |
|---|---|---|
| 原交付14 + 前轮独立负向15 | 29/0 | [original-and-independent.tap](evidence/facade-r2/original-and-independent.tap) |
| 真实HTTP8 + 三次进程启动1 | 9/0 | [loopback.tap](evidence/facade-r2/loopback.tap) |
| 独立新增修复边界 | 13/0 | [independent-edges.tap](evidence/facade-r2/independent-edges.tap) |
| 独立新增真实HTTP边界 | 4/0 | [http-edges.tap](evidence/facade-r2/http-edges.tap) |
| 原纯函数离线 | 29/0 | [offline.tap](evidence/facade-r2/offline.tap) |

同前轮口径38/38，新增17/17，共55/55，不含纯函数29。不是把作者14+15+20的复验结果另加计数，重复覆盖不视为新增能力。本轮只重跑其中不监听端口的便携用例，见仓库准备记录。

F01 operation/run跨委托冲突、F02缺lease与诊断、F03expired500/回滚、F04reconciliation非对象已在此范围关闭。F01真实PostgreSQL双连接门槛保留。F02 guard后迟到暂停/撤权/接管仍拒绝，普通进度存储异常保存failed和error；F03只提交窄过期分支，其他异常回滚；F04无效JSON/过大body/认证也独立覆盖。

固定上游44项原文与Git blob/SHA256一致；Worker运行副本增加一行闭包lease事件字段，不能称未经修改。合同SHA256仍是 `08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9`。历史79项r2交付聚合 `f4edb4f1de194c2ae271b39c54b498c34984e6d2d9cf91009afb4570ccdfdb26` 对应原交付路径/全集，不能当本重组仓库聚合hash。

数据库模型没有实际 SQL/隔离/唯一键等待。恢复测试为正常停止/重启，不是commit途中SIGKILL/断电。上游Worker极早停止的迟完成worker-status写入窗口仍是覆盖缺口；独立HTTP harness只保证其自有测试排空/清理。FileRepository不允许多个写进程共享，生产恢复、锁错误与完整SDK组合必须独立验收。
