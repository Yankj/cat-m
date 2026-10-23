# 原生许可与抽屉 build32 · 2026-10-15

候选 `AF-UX-HIT-DRAWER-20261015-32`，**0.3.0(32)**。`Native32-r1` 最终 **14/14 单元 PASS；7 条原生 UI 为 4 PASS / 3 FAIL**，整轮 FAIL。**build32 未交付用户，“小咪最新体验”仍为 build29，UX 门不关闭。** 本文件为失败日期快照；当前进度只见 [master-plan](../status/master-plan.md)。[build31 失败历史](restart-native-hit-build31-2026-10-15.md)保留，后续 build33 不继承本轮通过数或覆盖失败。

冻结本地源码 `d2b5d5200d35c5717f591f087da01d3b85d17431`；选择性发布远端 `33c6eb634d1b63370f2eaa7f40ed1beb8d809dae`，tree `3cb0bb80613c6fbf2f65761f53dda2ee8c4163bd`。415 项输入固定于 ignored `build/native-hit-drawer32-20261015/source-snapshot.json`，SHA-256 `a7d577b034b3678ec0c139a893794fb6c4faa9107efb6920833c643ba4e2a459`。以冻结输入裁决，不把正在修33的工作区称作32。

独立 `frozen-app/CatpawM.app` 的 33 项包文件与 `package-files32.json` 逐项大小和 SHA-256 匹配，Info.plist 读回 0.3.0(32)。包指纹 `f014d7689adeea6334ff8dc5a55151b42bc86d5dc19f1b899cd1fc8f0198f47a`；包 manifest SHA-256 `a5ab691c08de0da21eaf665c4f373d3ca75c3fb8b7e6c8c57a1c2f5b6672fc4e`。保留包只证明候选可追溯，不等于验收通过。

| 本轮实际方法 | 结果及停止位置 |
|---|---|
| 时间线投影 10 条＋许可模型 4 条 | **14/14 PASS，7.512s**；许可身份/修订拒绝、拒绝后恢复、呈现绑定清除和冷队列专项 |
| `testLongLoopbackConsentRejectReopenAllowPreservesOneOriginalRequest` | **PASS，28.856s**：同段长中文 loopback 告知，真实拒绝关闭→正常重开→允许，原 UUID/原文只受理一次 |
| `testChineseEditorAndModalDetailsKeepHorizontalGestureOwnership` | **PASS，25.703s**：中文编辑和详情弹层保持横向手势归属 |
| `testReadOnlyLongPressOwnsSystemCopyMenuThenBodyPanResumesWithoutSending` | **PASS，29.771s**：系统复制菜单、实际输入焦点转移后恢复正文横拖，精确保留原草稿且不发送；这是32新测，不改写31同方法失败 |
| `testReadingAboveBottomSurvivesStreamAndJumpResumesFollowing` | **PASS，28.148s**：阅读上方时不被流式更新拉走，回到底部恢复跟随 |
| `testReadOnlyReplyPanRevealsForegroundStripAndClosesKeepingChineseDraft` | **FAIL，20.973s**：原测试第78行，`sidebar.scrim.exists && isHittable` 不成立；关闭按钮等待已通过。AX 中 scrim 为 `{{320,62},{402,778}}`，屏幕宽402，命中框仍宽402且大部越出可见屏幕；后续前景关闭/保稿断言未完成 |
| `testIntegratedSidebarRoutesSearchAndNativeBackPreserveSavedDraft` | **FAIL，21.098s**：公共等待第88行超时；选回会话后 `waitForClosedSidebarRoot` 要求 close/scrim 均不存在，实际持续观察到 scrim 残留，未进入后续任务/成果/设置返回验证 |
| `testSidebarSearchClearAndTwoUnsentDraftsRemainInTheirConversations` | **FAIL，19.876s**：同一公共等待超时；新会话后的 root-ready 门未通过，未进入第二份草稿输入及双会话搜索/持久验证，不能写成已证明草稿丢失 |

七条 UI 最终耗时 **174.425s**、3 个失败，日志结尾 `TEST EXECUTE FAILED`。关闭态 scrim 在候选 Host 中仍常驻，仅切换 hit testing/AX hidden；原生结果没有满足关闭后不存在的边界。协调者下一候选33将改实际可见命中矩形及 active 条件挂载；这里只记录下一修复方向，不将未执行的新候选写成已修复或32通过。

同输入 Debug build-for-testing、non-DEBUG Simulator SDK typecheck、语法、116 App 成员、1091 双语资源、13 设计变异以及布局/冻结来源/规划检查 PASS。源阶段敏感扫描为1172候选、0阻断/0待审，早于本日期文件。31的最大辅助字号32.495s及 package七路径21/21保持各自旧输入证据，本轮没有将其重算成32新测或推广到33。

原始日志、App、`Native32-r1.xcresult` 与录屏材料留在 ignored `build/native-hit-drawer32-20261015/`。最终 `native-r1.log` SHA-256 `a61ead13f24870e9d9edfc2d4023f3c41a6c973f8aaf5487f794422d69ea9a13`；`sdk.log` SHA-256 `7ee7c2986a706c005365ff38babd5f196118cf1eff3339a267fb59dc2a8a2466`；`build.log` SHA-256 `9bc2358507904cc2a340d3214bb224ce7d485143e1862a3d9f23a6212596045f`。仅此日期文本进入仓库，不上传媒体或包。

这些是实际 SwiftUI/UIKit/XCTest 加明确本机合成夹具结果，无真实 Auth、模型、生产 SQL、部署、手机安装或用户体验版覆盖。原 build29 长中文实点24.295s通过的记录保持：用户原点击症状仍 **NOT_REPRODUCED，根因未定位**，其 r1/r2 harness 错误不是产品失败。全尺寸/主题/软键盘、VoiceOver、Reduce Motion、中途接管动效、完整图片二级许可及所有真实产品门仍未关闭；AF-G5、FINAL-G1/G2/G3、七天日用和竞品门不因本轮变更签收。
