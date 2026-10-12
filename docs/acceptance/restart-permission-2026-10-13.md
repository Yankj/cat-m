# 重启首片：许可与维护基线验证

日期：2026-10-13。输入为原生HEAD `582e4e4`与12文件WIP，hash见[导入清单](../status/restart-import-candidate-2026-10-13.json)。新仓保留原候选，修复`ConversationFirstView.stateName`缺return，并增加拒绝后重新确认、旧revision拒绝执行两个测试。许可业务review独立于弹窗binding；提供稳定确认入口；队列折叠；只在完整回复通过协议校验并落盘后记录回复证据。

| 实际检查 | 结果与范围 |
|---|---|
| 冻结合同/44个上游原件/受控patch/历史来源 | PASS，静态完整性 |
| 便携对话 / 待发队列 | 7/7与9/9 PASS，合成 |
| non-DEBUG SDK源码 / 项目成员 / 本地化 | PASS，含实际中文英文表与零缺失literal；不代表真实IME或VoiceOver |
| DeviceTrial产品配置 | 无签名generic Simulator构建PASS，不签名、不安装手机 |
| 最终DeviceTrialNativeTests | 39/39 PASS，注入合成backend；包含绑定清除、重复许可、拒绝重开、过期revision、冷启动队列、撤权迟到结果与持久terminal校验 |
| 实际原生alert按钮UI | 1/1 PASS，Simulator人工fixture；批准前0次授权/回复、批准后1次授权/原消息回复，增量文字可见并落盘 |
| AF-A02 / AF-A03产品签收 | NOT_RUN：同版物理手机许可与真实模型仍需验证，不能以本批低层结果关闭 |

精确源码与日志hash见[RESULT.json](evidence/restart-permission-2026-10-13/RESULT.json)。原始日志与xcresult留在忽略build目录。

首轮显式结果包导出在用例结束后卡住（Xcode主机buildVersion诊断），该驱动不算完整通过。最终以关闭非必要测试诊断的模式重跑，39原生＋1 UI、`TEST SUCCEEDED`与退出0均取得。generic产品build亦有`BUILD SUCCEEDED`与退出0。保留首次getter编译失败，不将历史结果移记成新通过。

本批0真实模型调用、0手机安装、0云部署、0tick；没有改供应商、付费fallback或第三方账户。手机仍是旧build15。旧真实App记录：新人工会话同意后仍等待，后来选择暂不允许暂停；当时没有观察到完整回答，故许可→发送FAIL、模型UNVERIFIED。新的实际provider验收使用现有路由，另绑定具体新包与原turn证据。
