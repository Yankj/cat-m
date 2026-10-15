# 同任务有限改稿片 · 2026-10-15

候选 `AF-CP01-REVISION-WORK-20261015-27`，**0.3.0(27)**。本地源码 `261729d890e9c349e1ed6b71b3357c2c8849acaa`，46条明确文本路径已发布到 `feat/s03-revision-work`，远端源码 `4c7a6b87d9a7173c911a9073a351e081fa2ac457`。这是可构建源码与离线验证候选，尚未安装；用户可点测的原Simulator仍是build25。实时状态只见 [master-plan](../status/master-plan.md)。

用户选中已完成报告，输入修改要求，查看原版本并重新确认本次范围、期限与预算后，Agent沿同一Task/run生成新成果版本。旧请求、旧额度、原成果与回执保留。有来源任务固定原目录的公开来源读取范围，确认页不能降为仅本地整理；新的worker使用本次明确上下文与记忆快照。原手动编辑权限与新的有限改稿授权分别裁决。

新增 `catpaw.task-revision-work.v1` 与严格v2 grant，复用既有records、事务、许可算法和TaskWorker。受理原子保存新计划、操作、许可和精确回执；共有selector在模型、来源、due、结算和恢复处选择同一段权限。新会话提交与暂停恢复按原改稿操作自动有界唤醒；未知结果保留原ID，仅GET核对，不补额度、不刷新期限、不重发。新回执经严格验证后才可解除旧展示围栏，普通迟到投影不能解除。

| 实测 | 结果及边界 |
|---|---|
| 维护后台 | 最终444/444离线PASS；含20 HTTP、19合同、12新grant、8来源授权用例；注入provider、TLS及SQL stub，非真实PG/模型 |
| Swift合同与应用 | 86断言／3组维护Node字节golden、8组持久化/确认/队列/冷恢复PASS |
| 实际URLSession/SSE | 正常、丢响应冷GET、篡改outer共23断言PASS；3次显式提交=3次POST，重复提交/冷恢复零额外POST；载荷由实际维护handler生成 |
| 既有回归 | 对话52、队列16、HTTP94／36次明确POST通过；原有路由保持，最终新增UUID方法另经SDK和新wire重验 |
| SDK与产品包 | 完整non-DEBUG SDK、语法、114成员、1086双语PASS；Release generic Simulator编译链接PASS，20文件包hash `7c9895377b619466a365cf39a60fe826286ac3fee717dc4f739ec82e5d4b595c` |
| 来源／治理 | 402输入逐项SHA与独立远端索引Git blob一致；布局、冻结来源、部署快照、AF/FINAL/CG合同、敏感及空白检查PASS；无媒体上传 |

[RESULT](evidence/revision-work-20261015/RESULT.json)与[源快照](evidence/revision-work-20261015/source-snapshot.json)固定证据。完整包清单、日志和wire留在ignored `build/revision-work-20261015/`。远端tree `d6b3e782d9988fa9ad70c8eaa95ec8c3287a54b1`与独立重建一致；未推旧本地历史或未授权PNG。

独立审查修复真实入口问题：能力字段名不一致、来源报告默认范围错误、新上下文未到worker、fallback缺冻结intent，以及新会话唤醒被旧session限制。实际wire发现Swift UUID大写造成outer哈希失败；只规范两个协议UUID字段，保留严格校验，补含字母UUID与实际维护回放。过期／删除来源错误在共用执行围栏分类，真实损坏仍报错。SDK首轮仅在本地化scanner对ui(ternary)拒绝，改两支显式ui并将便宜资源检查前置；原失败均保留。没有再分散调整字体字号。

限制：本片没有新Simulator UI/安装、手机、真实模型/Auth/PG、多实例、线上部署或系统效果验收。API21与用户build25保留；原r7唯一真实请求429仍为FAIL，不重试。跨会话收件箱、独立调度/变化跟进、系统日程与全部AF/FINAL验收继续未完成；不关闭CP-01或FINAL-G3。
