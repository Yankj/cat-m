# 原生抽屉 build34 · 诊断失败快照 · 2026-10-15

候选 `AF-UX-HIT-DRAWER-20261015-34`，**0.3.0(34)**。原生 `offset` 替换自定义位移后的正式正文横拖专项仍 **FAIL**；同一冻结 App 的独立绝对坐标点击诊断 **PASS**。两者证明的事实不同，**诊断通过不覆盖严格 AX/可命中失败，也未证明 offset 是根因**。build34 未交付用户，固定“cat 最新体验”仍为build29；UX门未关闭。当前进度只见 [master-plan](../status/master-plan.md)，[33失败](restart-native-hit-build33-2026-10-15.md)不改写。

冻结本地源码 `2d88683d513e9a9b94dbcb967856d2be240a4c58`。**截至本快照，34源码尚未独立远端发布，没有34远端SHA/tree。** manifest的 `base_remote_commit` 是此前33来源，不是34发布证明。ignored `build/native-hit-drawer34-20261015/source-snapshot.json` 固定r1的415项输入，SHA-256 `daedff7fd420208413d6b5060130941bdee3a31eb581bfe80090cdf838effef3`；`source-snapshot-r2.json` 固定416项输入，SHA-256 `c751b962052fc1dc89949aa85adf8a57b2f0afb60204030b95a78647c308b6d0`。逐项比较仅新增 `ConversationDrawerScrimCenterDiagnosticUITests.swift` 并修改PBX的UI测试成员，未变产品源码，原始r1输入保留。

独立 `frozen-app/CatpawM.app` 的33项包文件逐项大小及SHA-256与 `package-files34.json` 匹配，Info.plist读回0.3.0(34)。包指纹 **`ffd764f683593b175e8869e1f7fb28bd589bfc50e8725c8047a2d1ec62ceb71c`**，manifest SHA-256 `2b31adff549e8d4f807f7d70434e35d9c9587a3881d6dbf63cc9d1d7577f8333`。两轮测试针对同一冻结产品App；r2增加独立测试Runner能力，不是另一产品修复。

| 实际执行 | 结果及精确边界 |
|---|---|
| `BodyPan34-r1`：`testReadOnlyReplyPanRevealsForegroundStripAndClosesKeepingChineseDraft` | **FAIL，19.395s**；第90行 `sidebar.scrim.exists && isHittable` 不成立。保留原严格断言，后续从前景关闭及保稿验收未完成 |
| `PhysicalCenter34-r2`：`testDiagnosticAbsoluteVisibleScrimCenterAfterReadOnlyBodyPan` | **PASS，21.783s**；先实际正文横拖展开，再从App绝对坐标 **(361,451)** 点击可见scrim中心，关闭完成且中文草稿逐字相同，user echo仍1、未追加发送 |

r2点击前文本附件 `physical-center-r2-attachments/0E4572EB-D12C-4714-8CB4-182440D7276E.txt` 记录：`scrim_exists=true`、`scrim_enabled=true`、**`scrim_hittable=false`**，AX frame及可见交集均为 **(320,62,82,778)**，`opened_by_body_pan=true`。点击后附件 `EE580BD0-363E-4C88-BC4D-341EA9F58279.txt` 记录：scrim/close不存在、`closed_endpoint=true`、`draft_exact=true`，原中文输入和echo数保持。该诊断有意通过App绝对坐标点击，不能冒充 `scrim.tap()` 或 `isHittable` 验收；也不能把“绝对坐标能关闭”写成原严格失败已解决。AX矩形已正确、物理事件能到达与AX可命中状态仍假在本候选同时存在。

下一候选35拟仅在共有Host层调整AX modal范围，先对同一正式路径验证单变量假设。本快照没有证明AX modal就是充分根因，不预写35结果。

同Host SHA-256 `30021f7b057042251c7f5a30a92668ec63049e5ed7b62cf2badb611a3a39a890` 的CatpawNavigation **25/25 PASS**，仅macOS package编译/逻辑。八个具名输入及执行前后稳定性见 ignored `packages/ios-navigation/.build/reveal-review/RESULT-final-native-offset-25-r6.json`，SHA-256 `cb9b3f228a6192aaaae9329961883b9eeec168e06b9a788aa9a94886b04454a5`；日志 `final-native-offset-25-tests-r6.log` SHA-256 `b5c81e2149d435b328182cb6b1ea5cc5b8cc93f6559a36e93a726aad57478c1d`。package通过不替代宿主失败，后续35修改不继承。

本轮Debug build-for-testing、non-DEBUG Simulator SDK typecheck、语法、116 App成员、1091双语资源、13设计变异、布局/冻结来源/规划检查PASS；r1源阶段1174候选及r2测试阶段1175候选敏感扫描均0阻断/0待审，早于本日期文件。**没有执行34的14单元＋7UI全21方法整轮，也没有34最大辅助字号用例；不继承31/32/33的通过数。**

原始App、`BodyPan34-r1.xcresult`、`PhysicalCenter34-r2.xcresult`、截图/文本附件、录屏和原始record仅留在 ignored `build/native-hit-drawer34-20261015/`。严格失败日志 `body-pan-r1.log` SHA-256 `f224c3e590ca1e512172dae6ebd8338e6a856891accd2edbeb5686de26619701`；诊断日志 `physical-center-r2.log` SHA-256 `95368ded0dbfd437728a4c63afcb91c39c761ac2eae8f0e2e36917696a336a01`。媒体及App不随日期文本发布。

这些是实际SwiftUI/UIKit/XCTest和明确进程内合成夹具的观察，无真实Auth、模型、生产SQL、部署、手机安装或用户体验版覆盖。原build29许可症状NOT_REPRODUCED／根因未定位的边界保持。完整触控/VoiceOver/Reduce Motion/中途接管动效、全尺寸字号及真实产品门均未关闭，不签收AF-G5、FINAL-G1/G2/G3、七天日用或竞品门。
