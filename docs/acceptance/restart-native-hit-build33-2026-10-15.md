# 原生许可与抽屉 build33 · 2026-10-15

候选 `AF-UX-HIT-DRAWER-20261015-33`，**0.3.0(33)**。`Native33-r1` 最终 **14/14 单元 PASS；7 条原生 UI 为 6 PASS / 1 FAIL**，整轮 FAIL。导航返回和双会话草稿已在本候选新测通过；普通正文横拖后的前景遮罩仍不可命中。**build33 未交付用户，固定“Catpaw 最新体验”仍为 build29，UX 门未关闭。** 本文件为日期快照，当前进度只见 [master-plan](../status/master-plan.md)；[31](restart-native-hit-build31-2026-10-15.md)／[32](restart-native-hit-build32-2026-10-15.md)失败保留。

冻结本地源码 `6fc2408ed42ccfa596949a8144c607809a66af20`；选择性发布远端 `b8344afc2ff8431282cacaf88b22a6e6f7b5f4c7`，tree `58a1888f960133411b673fe69c1d8020d3f65d94`。415 项输入固定于 ignored `build/native-hit-drawer33-20261015/source-snapshot.json`，SHA-256 `e7be5c52d71c0790ecf212991839481bfed805eeacead85aee14d1e41b750d1f`。独立 `frozen-app/CatpawM.app` 的33项包文件逐项大小及SHA-256与 `package-files33.json` 匹配，Info.plist为0.3.0(33)；包指纹 `a8d4a0d49b96d5544cbe20d90e98f42cca20af45bb05a55b91f24f8a5482656f`，manifest SHA-256 `42453a25d202ea2c975a9ff3f973d7c108404f798f0842d7cfb88c9a946cd105`。后续工作区或34候选不属于这些冻结字节。

| 实际方法 | 结果及边界 |
|---|---|
| 时间线投影10条＋许可模型4条 | **14/14 PASS，7.551s**；许可身份/修订拒绝、拒绝恢复、呈现绑定清除及冷队列 |
| `testLongLoopbackConsentRejectReopenAllowPreservesOneOriginalRequest` | **PASS，26.529s**：长中文告知实点拒绝、正常重开后允许，原UUID/原文一次受理 |
| `testChineseEditorAndModalDetailsKeepHorizontalGestureOwnership` | **PASS，24.080s**：中文编辑与详情弹层手势归属 |
| `testReadOnlyLongPressOwnsSystemCopyMenuThenBodyPanResumesWithoutSending` | **PASS，28.940s**：实际系统菜单、焦点转移和正文手势恢复，精确保稿且不发送 |
| `testIntegratedSidebarRoutesSearchAndNativeBackPreserveSavedDraft` | **PASS，28.168s**：侧栏搜索、任务/成果/设置路由、原生返回及原草稿；这是33新测，32的root-ready超时未改写 |
| `testReadingAboveBottomSurvivesStreamAndJumpResumesFollowing` | **PASS，28.346s**：流式更新保持阅读位置，回到底部恢复跟随 |
| `testSidebarSearchClearAndTwoUnsentDraftsRemainInTheirConversations` | **PASS，29.549s**：搜索清除及两个会话各自未发草稿；不沿用32未执行到的结果 |
| `testReadOnlyReplyPanRevealsForegroundStripAndClosesKeepingChineseDraft` | **FAIL，19.408s**：原测试第90行 `sidebar.scrim.exists && isHittable` 失败；关闭按钮等待已通过，但后续从保留前景关闭及精确保稿断言未完成 |

七条UI共 **185.021s**，日志结尾 `TEST EXECUTE FAILED`。唯一失败时，AX显示屏幕宽402，scrim已是 **`{{320,62},{82,778}}`**，与实际右侧可见宽82一致，仍不能满足命中断言。因此32的越屏宽度已在本候选改正，但**不能再把宽度错误当作充分根因，更不能以AX矩形正确声称实际命中已修复**。关闭态元素条件挂载后的导航与草稿路径虽通过，不足以替代此独立失败。

下一候选34拟只把自定义 `GeometryEffect` 位移替换为原生 `offset`，先运行同一普通正文横拖专项检验“视觉/AX位移与实际命中坐标不一致”的假设；本记录没有证实该假设，也不将计划写成已修复。34须另固定源码、包与实际结果，不能继承33通过数。

同输入 Debug build-for-testing、non-DEBUG Simulator SDK typecheck、语法、116 App成员、1091双语资源、13设计变异以及布局/冻结来源/规划检查PASS。源阶段敏感扫描1173候选、0阻断/0待审，早于本日期文件。31的最大辅助字号许可和package21/21仍仅对应原冻结输入，不计33新测。

原始App、日志、`Native33-r1.xcresult`、附件和录屏仅留在 ignored `build/native-hit-drawer33-20261015/`。最终 `native-r1.log` SHA-256 `55587e8edcd213daed3440871ece689f8933cb99c83b3dd440f1fd3ee7ab1d21`；`sdk.log` SHA-256 `04180761095a6325d9796787fccd31fb413a862fa150cbb3e06f313dceb393c6`；`build.log` SHA-256 `a0869ad0a4330858e7e77889a47baf1f640243e830e34c285c7b476048e41579`。仅此日期文本发布，不上传媒体或App。

本轮是实际SwiftUI/UIKit/XCTest与明确本机合成夹具，没有真实Auth、模型、生产SQL、部署、手机安装或用户体验版覆盖。原build29长中文许可实点24.295s通过、用户原症状 **NOT_REPRODUCED／根因未定位** 的边界保持；旧harness错误不是产品失败。全尺寸/主题/软键盘、VoiceOver、Reduce Motion、中途接管动效、图片二级许可及真实产品门仍未关闭，不能签收AF-G5、FINAL-G1/G2/G3、七天日用或竞品门。
