# 原生许可与抽屉 build31 · 2026-10-15

候选 `AF-UX-HIT-DRAWER-20261015-31`，**0.3.0(31)**。本记录为日期快照；当前进度只见 [master-plan](../status/master-plan.md)。**build31 未交付用户，固定“cat 最新体验”仍为 build29；抽屉专项失败，UX 门未关闭。** 后续 build32 修复不能改写或继承本轮结果。

冻结本地源码 `205c7377bd087799d40d2902d23c5887d3af3061`；选择性发布远端 `cecf20b9ecf473c57db23d23f48a45a1f0c78301`，tree `0f8121aa48f2c49b2c7620227836be538d650c05`。415 项输入见 ignored `build/native-hit-drawer31-20261015/source-snapshot-r2.json`，SHA-256 `d85750169f596a3cc5b354b5d7977dd88ed3a53669356e6b5fe67aee167074d6`；原 `source-snapshot.json` 保留。r2 仅新增第三条只读选择 UI 用例，产品源码未变，不把后续工作区当作冻结 build31。

独立 `frozen-app/CatpawM.app` 的 33 项包文件与 `package-files31.json` 逐项大小及 SHA-256 匹配；包指纹 `be8536be771294edf61de8910b430a34c78e3a94748c3172e40f222b02dc582e`，manifest SHA-256 `676b2b8d77924c12ca25edd160d00b845a459c1b36fcf8897afba7c2b278a2b3`。包可追溯不等于产品验收通过。

| 实际执行 | 结果与范围 |
|---|---|
| Focused31-r1 单元 | **14/14 PASS**：10 条时间线投影及 4 条许可身份、拒绝后恢复、绑定清除和冷队列专项；7.538s |
| Focused31-r1 原生 UI | **3/3 PASS**：长中文 loopback 拒绝→恢复→允许原请求 25.332s；短许可原消息一次受理 20.228s；阅读位置与回到底部 27.982s。共 73.542s |
| LongConsent31-MaxAX-r1 | **1/1 PASS，32.495s**：同段长中文告知在最大辅助字号下，两按钮实点、拒绝关闭、正常入口重开及原 UUID/原文一次受理；这是同方法另一字号执行，不增加独立方法数 |
| CatpawNavigation 冻结 package | **21/21 PASS**，arm64e-apple-macos14.0；仅七个具名输入的 package 编译与逻辑专项，不能替代宿主触控/像素/动效验收 |
| SDK/源码治理 | Debug build-for-testing、non-DEBUG Simulator SDK typecheck、语法、116 App 成员、1091 双语资源、13 设计变异、布局/冻结来源/规划检查 PASS；源阶段敏感扫描 1171 候选、0 阻断/0 待审，早于本日期文件 |

抽屉宿主 `Drawer31-r1` 实际 **5 条，1 PASS / 4 FAIL，107.678s**，不能记整轮通过：

| UI 方法 | 原始结果及停止位置 |
|---|---|
| `testChineseEditorAndModalDetailsKeepHorizontalGestureOwnership` | **PASS，22.705s**：中文编辑和详情弹层的横向手势归属专项 |
| `testReadOnlyLongPressOwnsSystemCopyMenuThenBodyPanResumesWithoutSending` | **FAIL，31.351s**：原测试第 126 行，退出选择后的正文横拖未得到可命中的 `sidebar.close`；未通过手势恢复，不据此推断发送或草稿丢失 |
| `testReadOnlyReplyPanRevealsForegroundStripAndClosesKeepingChineseDraft` | **FAIL，18.731s**：原测试第 78 行，打开后 `sidebar.scrim.exists && isHittable` 不成立；前一关闭按钮等待已完成，保留前景的后续关闭/保稿断言未完成 |
| `testIntegratedSidebarRoutesSearchAndNativeBackPreserveSavedDraft` | **FAIL，17.058s**：第 409 行，点击 `sidebar.tasks` 时没有匹配按钮；后续任务/成果/设置导航与返回未完成，根因尚未由该日志证明 |
| `testSidebarSearchClearAndTwoUnsentDraftsRemainInTheirConversations` | **FAIL，17.832s**：第 431 行，新会话输入 `typeText` 时无键盘焦点；后续两个会话草稿/搜索验证未完成，不能将停止位置写成持久草稿已丢失 |

用户报告的原 build29 两按钮不能点击：独立 UI Runner 指向已交付原 App，在同段长中文告知上真实点“暂不允许”、正常重开后点“允许此对话”，`Original29-LongConsent-r3` **PASS，24.295s**；原安装快照完整 33 项指纹 `eb9f94e2f281b70081db924d96f1addb2ea9e5624f18ba16f824dd312b1513be` 与已交付 29 一致。因此原用户症状记 **NOT_REPRODUCED，根因未定位**。r1 是复制测试工程后的状态文件路径错误；r2 是 135 字正文作为 identifier 查询超过 XCTest 128 字限制，均发生于有效按钮检查/点击前，属于 harness 错误，不能记产品按钮 FAIL。build31 改为可滚动告知和固定底部动作的 sheet 是新候选设计及新测，不证明修复了已定位的原29故障。

原始 App、日志、xcresult、附件与视频保存在 ignored `build/native-hit-drawer31-20261015/`。关键日志 SHA-256：`focused-r1.log` = `16e45185721349db01faa2c6cb8beab69bf820a0e4aef73d56e421adf9a01af7`；`long-consent-maxax-r1.log` = `1fe027d11a21c0804bf461eef1de5aa608ebac5d193157241aef393f9f171f54`；`drawer-r1.log` = `eed0bf04aaf29c47b80298d3a32a49b56358a416a78e8fcc9d000d19adc72bf1`。原29日志另在 ignored `build/consent-hit-20261015/`；`original29-ui-r3.log` SHA-256 `c4eae131605ea3ee687b42ee7114395fdc2d8122f86822f5d96143c35040e7d0`。

package 七路径与执行前后稳定性由 ignored `packages/ios-navigation/.build/reveal-review/RESULT-final-frozen-21-r3.json` 固定，SHA-256 `3fe37bfd0df13a26a34946de8a0dd5a21a3c8fd87cc12f9be3a59e41c69ca4e3`；其 `final-frozen-21-tests-r3.log` SHA-256 `fa4d22540a778ccd64b503901f95a3be9c453ab260ffc4f46c2f258a7581fb25`。后续32修改须另冻输入、另验，不继承21/21。

本轮使用实际 SwiftUI/UIKit/XCTest 与明确本机合成 loopback；许可/普通请求的 HTTP POST 和脚本 provider 计数不代表真实外部调用。无真实 Auth、模型、生产 SQL、部署或手机安装；用户 build29/store/8772 保留。没有完成全尺寸/主题/软键盘、VoiceOver、Reduce Motion、中途接管动效或完整图片二级许可矩阵，不关闭 AF-U、CP、AF-G5、FINAL-G1/G2/G3、七天日用或竞品门。媒体与包不随本日期文本发布。
