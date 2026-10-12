# 历史OpenMuse r3 最终快照整合

这是2026-10-11冻结r3的本地资产整合记录，保留当时的源码/测试口径。当前用户产品反馈与conversation-first主链只见 [主交付计划](master-plan.md)。本记录不代表新主链已完成，也不作为未冻结chat/原生/记忆源码的导入许可。

客户端任务已完成终态验收并冻结独立副本。本轮依据正式handoff、最后报告/构建/UI/HTTP日志、101项source manifest与最终ZIP，逐文件核验后纳入 [apps/ios-openmuse-demo](../../apps/ios-openmuse-demo/README.md)。本轮不改原交付目录，也不复用v1工程作为r3。保留独立demo bundle/storage与已交付v1的36份业务源基线。

## 已满足的整合输入

- 客户端101项最后源码均与冻结目录和最终ZIP对应；ZIP的194项文件逐项hash通过。43份App Swift、资源、工程、Swift测试及合成响应原字节保留。
- contract SHA256为 `08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9`，客户端/服务字节一致，服务为r2受控façade。scope/认证/DTO属于本机合成演示，未把façade称为upstream API。
- 最后源码的fixture15、响应重放5、iOS BUILD SUCCEEDED、四阶段Swift HTTP恢复链与2条原生UI终态已核对。当前源码不继承旧轮通过结果；细节与未验项见 [r3验收](../acceptance/openmuse-r3.md)。
- 只迁移4个测试工具的引用/输出根和1份适配说明；121项导入的原文/副本hash逐项记录在 [provenance](openmuse-r3-provenance.json)。业务源和断言未改。
- 精选4张合成原生图保留原像素/hash，最终摘要移除设备UUID、PID、个人路径和随机运行身份。ZIP/App/全量截图、设备日志、Library传输身份及源码打包工具排除。
- 本地仓库重验来源、spec/合同、上游许可与patch，执行纯fixture/响应重放、源码/工程/双语资源检查和HTTP runner编译；实际命令及结果在 [仓库准备验收](../acceptance/repository-preparation.md)。没有另启服务或Simulator。

## 保留边界

15项fixture是Foundation/磁盘，5项重放没有live网络；实际HTTP/原生UI来源为客户端终态证据。本轮没有独立重跑Simulator。unknown仍只读原请求，暂停/撤权的迟到结果不能发布，resume仅准备新草稿；合成本机效果不提升为远端核验。

真实协议/身份/模型/Intelligence、SQL双连接与多实例、云后台/推送、iOS17运行时/真机、控制回执自动reconciliation、完整视觉/无障碍和继承v1全套原生/语音回归仍未验。Library官方上传失败，无新文件身份，本轮不补传。没有commit/push/PR/公开发布；首次远端写前须重新只读核对refs并取得用户授权。
