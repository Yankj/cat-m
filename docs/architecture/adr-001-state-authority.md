# ADR-001：执行状态由服务记录裁决

状态：已在合成本地实现采用，2026-10-11。

适用历史v1/r2/r3。目标PG领域事务单权威与当前chat/Store适配见 [整体设计](server-first-delivery-design.md) 和 [主计划](../status/master-plan.md)；本ADR的历史Task/ActionProposal关系不能被解读为已部署PG或已完成新主线。

原生页面只显示核验过的领域投影。Repository 保证本地事务提交与成功事件一致；façade 用固定上游 TaskWorker/ActionService 处理执行和审批。cat records 负责授权、冻结请求、业务关联、成果版本与核验，不能成为第二套执行调度器。

AG-UI `RUN_FINISHED` 只结束模型流；tool call/card 不赋予执行权。服务受理、任务完成、unknown 与远端效果核验分开。断流或重启后读取原 operation/approval，不重建请求来“恢复”。此选择需要明确稳定 ID 和版本/hash 校验；真实模型与云端实现必须沿用这些语义再单独验收。
