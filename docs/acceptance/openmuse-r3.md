# OpenMuse 原生合成 Demo r3 终态验收

本文件保留冻结r3的历史合成本地终态，实际报告与source identity不改。用户后续真机反馈不接受该Demo产品体验，且此前首启Security阻断未由本任务工具完整复验。当前产品方向/新主链验收只见 [主交付计划](../status/master-plan.md)，不能用下面历史PASS替代。

正式依据为客户端任务 `handoff-local.json`、r3最终报告、最后源码清单及最终ZIP。ZIP为6,401,200字节，SHA256 `a5bf5e0eb77800257a8f928b33db29b9b58e97b099a010486d08ed8187ee7af5`，其194项文件全部逐项hash通过；另有一份自描述SHA256 manifest，所以ZIP entry总数195。ZIP含unsigned Simulator App，本仓库不复制ZIP、App或缓存。

最后 [source manifest](evidence/openmuse-r3/last-source-sha256.json) 的101项同时与冻结目录/ZIP对应。43项App业务Swift、资源、Xcode工程、Swift测试和合成响应样件在 [apps/ios-openmuse-demo](../../apps/ios-openmuse-demo/README.md) 保持原字节。仅4个测试工具和1份适配说明作路径/输出迁移，转换前后hash在 [r3 provenance](../status/openmuse-r3-provenance.json)，不修改业务源。原v1和r2基线保留。

| 客户端任务最后实际运行 | 终态结果 | 证据与边界 |
|---|---|---|
| pure fixture / 磁盘 | 15项通过 | [fixture输出](evidence/openmuse-r3/build-openmuse-resume-fixture-15.txt)，不是iOS/XCTest/真实网络 |
| 合成r2响应重放 | 5项通过 | [重放输出](evidence/openmuse-r3/build-openmuse-snapshot-02.txt)，无live网络或Worker执行 |
| 最后源码iOS构建 | BUILD SUCCEEDED | 读取最后构建原日志核对；Xcode27.1/Swift6.4编译器、Swift5模式、SDK27.1、部署17、unsigned arm64 |
| 实际Swift loopback恢复链 | 四客户端/四服务进程通过 | 读取最后HTTP结果/日志，四阶段同独立文件恢复同一Task；接纳/审批各一次POST |
| 实际façade原生UI | 1用例通过，88.981秒 | 主动连接→提交→App重启→原任务→版本/hash审批→重启→unknown原回执/本机效果→来源 |
| 原生具名fixture UI | 1用例通过，59.425秒 | 同最后源码结果包，磁盘/保存/审批/恢复/来源 |
| 原生截图 | 共10张；精选4张入库 | [图与manifest](../design/openmuse-r3.md)，保持原像素，仅合成内容 |
| 真实Intelligence/模型/外部写入 | 0 | 尚未配置/授权，不证明真实云持久执行 |

终态摘要 [validation-summary.json](evidence/openmuse-r3/validation-summary.json) 已移除设备UUID、PID、绝对个人路径和随机业务运行身份；原报告/日志hash与机器位置仅留仓库外本地审计。原生结果是iOS27.0 Simulator，部署目标iOS17不证明iOS17运行时或真机已验。本轮仓库整合只复核终态字节/日志，不另称独立Simulator重跑。

## 本轮关键语义

读回中Worker发布新引用时抛 `OpenMuseSnapshotReadChanged`，拒绝混合结果；只对该错误最多读3次。持续变化恰好3次/6个Run GET后抛明确可恢复 `OpenMuseReadBudgetExhausted`，结束busy，保留原接纳/已检投影；用户以后主动读原任务可恢复，Run POST仍仅一次。hash/scope等不匹配直接失败，不伪装成并发重试。每个HTTP请求30秒超时。

保存dispatch前事务失败不调用transport；unknown接纳加原任务缺失不重新创建。v2保留v1、失效旧审批；hash不符整批拒绝。pause/revoke的迟到成功不能发布，revoke不静默重授权；resume只准备新身份草稿，显式提交才创建。AG-UI EOF/RUN_FINISHED/工具提议不声明业务完成或授权工具执行，停止观察不取消业务任务。

HTTP丢响应为客户端故障注入丢弃已成功响应，不是物理断网。`resolved_local`只证明合成本机效果记录，不能提升为独立远端核验。一个operation/business Run/Task/preview effect可以有两个Worker尝试；尝试数量不代表业务重发。来源图拍摄时显示1次尝试，终态记录为2次，两者时间点不同。

## 清理、失败与剩余门槛

原任务已停止全部自持服务、端口无监听、所持Simulator关闭；未动其他设备，本轮不操作它们。早期宏权限、容器标识遮盖按钮、重启分区选择、混合快照、响应重放路由/参数失败均已记录并在最后源码复验；不把早期通过或未完成日志计入终态。

本轮合成本地Demo闭环已验。真实服务协议尚待用户；真实身份/key/provider、Intelligence与额度、真实模型/AG-UI chat/SSE重放、完整SDK/上游启动、SQL双连接/多实例/极早启停竞争、云worker/后台/推送、iOS17/真机未验。控制回执丢失仍需人工诊断，未实现自动服务control reconciliation。新页只实际验中文/深色/单一Simulator，大字号/VoiceOver/英文/浅色、deeplink多App共存待验；继承v1全套单元/UI/语音未重跑。

Library官方上传失败，未保存任何新身份；本轮不绕过原失败。仓库只保留本地资产，push/PR仍待用户授权。
