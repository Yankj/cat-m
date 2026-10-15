# 原生 R5 build29 · 2026-10-15

候选 `AF-UX-R5-NATIVE-20261015-29`，**0.3.0(29)**。两条新执行的原生 UI 用例全部通过，App 已独立保存并更新到现有“Catpaw 最新体验”模拟器；这是可点测的离线阶段版。**完整软键盘、R5 与产品验收仍未关闭。** 当前进度只见 [master-plan](../status/master-plan.md)。

冻结本地源码 `090c5431189d146e32a3c649f0b04dd7d2fdc279`；选择性发布远端 `51d3ca96c34a82a886b274d99373dd9f022ef5a5`，tree `4ea4785a7323dff087c9c852934a774429452941`。409 项输入逐项与冻结 Git 对象一致。33 文件包指纹 `eb9f94e2f281b70081db924d96f1addb2ea9e5624f18ba16f824dd312b1513be`；独立 `frozen-app` 和主目录体验副本均逐文件匹配，Info.plist 都是 0.3.0(29)。本地与选择性发布的完整 tree 分别记录，不混同历史。

本次修正共同触控边界：共有 `touchTarget(minimum:)` 把辅助字号所需尺寸及 `contentShape` 放在按钮标签，保证视觉尺寸与实际可点击区域一致，底线仍为 44pt。沿用原语义字体，没有再改局部文字字号。设置顶部新增读取实际 Bundle 的“关于”版本/构建号；所有配置共用 `Version.xcconfig`，构建阶段检查覆盖与格式。

| 本次实际检查 | 结果及边界 |
|---|---|
| 最大字号报告修改 | **PASS，160.870s**：同选定 v2、限制详情可读、关闭保留原文、退出恢复普通草稿、追问独立、冷启动恢复同版本和未发原文；冷恢复不新增 artifact POST |
| R5 输入与菜单 | **PASS，19.027s**：空输入禁用发送、多行工具行、更多→设置→返回精确保稿、不新增正式用户消息；“关于”两个字段存在 |
| SDK/资源/设计 | non-DEBUG Simulator SDK、114 源码成员、1089 双语资源、13 个设计变异反例与 Debug build-for-testing PASS |
| 安装读回 | 现有体验环境读回 29、同包指纹，保留原 store 与 loopback 8772；启动/一次读取探测期间 accepted、memory、provider 计数增量均为 0 |
| 来源治理 | 源阶段 AF/FINAL/CG 规划及敏感检查 PASS；敏感日志为 1159 候选、0 阻断/0 待审，早于本日期三文件 |

UI29-r1 本轮共 **2/2 PASS、0 FAIL，179.896s**。不把 build28 的另外四条 UI 通过或数值辅助方法算作 build29 新测。两条用例使用真实 SwiftUI/UIKit/XCTest 操作与明确 DEBUG 进程内离线夹具；现有体验运行在合成 loopback 后台，没有真实模型、生产 Auth/SQL、后端部署、手机安装或系统效果。启动前后的 provider_calls 都为 2，含义是本次增量为 0，不是历史总调用数为 0。

协调者实际审阅原生附件 `803A8BF3-A918-4D31-9F93-DAE61F68E218.png`，确认可见系统中文软键盘，详情图标和输入均在其上方，与 `keyboard_top=545` 一致；这一具体人工观察 PASS。用例名包含 AboveKeyboard，但测试未对每个关键转场建立严格的“软键盘确实可见且在屏内”前置断言，也未覆盖完整尺寸矩阵；**不能签收完整软键盘门**。“关于”UI 目前只断言字段存在，0.3.0(29) 精确值由包与安装读回证明，手工屏内读值另补。旧附件仍带 v21 名称，不作为包版本身份。实际浅深色截图已由协调者存入 ignored `local-audit/screenshots/native-r5-build29-20261015/`；协调者实际审阅 `dark-qa.png`，确认近黑阅读面与深蓝本人气泡，浅色来自原固定体验环境。两张仅是局部视觉证据，不是完整主题/对比度验收。“关于”未完成手工可视读值，不宣称已在屏内核对 29；精确版本依实际包及安装指纹。build28 未完成主题渲染的 dark.png 不继承为深色证据。

[RESULT](evidence/native-r5-build29-20261015/RESULT.json)和[409 输入/33 文件源包快照](evidence/native-r5-build29-20261015/source-snapshot.json)固定日志、安装计数与哈希。原始日志、xcresult、附件及独立 App 留在 ignored `build/native-r5-build29-20261015/`，主目录体验副本留在 ignored `build/device-hub-latest/packages29/`；仅文本证据进入仓库，不上传 PNG/App。

[build28 失败历史](restart-native-r5-2026-10-15.md)保持：r1–r5 失败、最大字号详情失败、假深色截图及原包被覆盖不改写。build29 是新候选上对同详情/冷恢复路径的新通过，独立保存包避免再覆盖。完整尺寸/主题、可见软键盘、VoiceOver、动态辅助设置和抽屉中断接管仍待同候选实测；AF-U、CP-01、AF-G5、FINAL-G1/G2/G3、七天真实日用及具名竞品配对未关闭。
