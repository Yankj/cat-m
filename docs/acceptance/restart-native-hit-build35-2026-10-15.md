# 原生许可与抽屉 build35 · 2026-10-15

候选 `AF-UX-HIT-DRAWER-20261015-35`，**0.3.0(35)**。已完成的严格正文横拖和整合两轮共 **21个不同方法全部PASS（14单元＋7原生UI）**；最大系统辅助字号同方法另一次执行也已PASS（34.933s），同包35已更新到固定体验环境，原store/backend保留。完整UX/产品门仍未关闭。当前进度只见 [master-plan](../status/master-plan.md)。

416项输入固定于 ignored `build/native-hit-drawer35-20261015/source-snapshot.json`，SHA-256 `4651a638c0513140a9efe0e621a31a721f581094b884e48c330a8d6df942259e`。冻结本地提交 `c19d0268af6be0a3e3d8d86bbce9b36d417915b4`，416项逐项与该提交Git对象一致；远端选择性5路径发布 `6da724796a0b04663d22580d7cc0dcc4df31c69f`，tree `105d604e190bfc51aebde8c37e5d7aa82106a32a`，由协调者更新并读回确认。snapshot中的base是旧34/33来源，不能混同35发布或声称本地/远端完整tree相同。独立 `frozen-app/CatpawM.app` 的33项包文件已逐项大小及SHA-256匹配，Info.plist为0.3.0(35)。包指纹 **`874f80bf8c91250988707368f8bf3e468186b211fdca4374a746cf8a227db87a`**；`package-files35.json` SHA-256 `346e1a1f54316a230acd95ca77ef33a210c2e2ea33e8854d93b4ff8c1630e32d`。

| 本轮实际执行 | 结果及范围 |
|---|---|
| `BodyPan35-r1` 严格正文横拖 | **1/1 PASS，27.256s**：保留原scrim可命中与可见框断言，从实际只读正文启动横拖、保留前景关闭，精确保留中文草稿且无追加发送；未以绝对坐标诊断替换正式门 |
| `Native35-r2` 单元 | **14/14 PASS，7.547s**：10条时间线投影＋4条许可身份/修订、绑定、拒绝恢复与冷队列 |
| `Native35-r2` 原生UI | **6/6 PASS，168.527s**：长中文许可27.871s、中文编辑/详情归属24.469s、长按复制后焦点恢复28.638s、导航与返回保稿29.062s、流式阅读位置28.457s、双会话各自未发草稿30.030s |
| `MaxAX35-r1` | **1/1 PASS，34.933s**；同长中文许可方法在最大系统辅助字号重新执行，真实拒绝/恢复/允许和原请求一次受理；不增加独立方法数。系统字号已恢复large，协调者已目视实际截图，但不签全文视觉门 |
| CatpawNavigation最终package | **25/25 PASS**，仅arm64e-apple-macos14.0 package编译/逻辑，八个具名输入执行前后稳定；不替代宿主/VoiceOver/动效验收 |
| 源码治理 | Debug build-for-testing、non-DEBUG Simulator SDK typecheck、语法、116 App成员、1091双语资源、13设计变异、布局/冻结来源/规划PASS；源阶段敏感扫描1176候选、0阻断/0待审，早于本报告 |

交付前布局、冻结来源、部署快照、AF规划、goals、FINAL规划及CGUI七组检查再次PASS，固定于同目录 `*-final.log`，仅证明相应治理门。协调者实际目视原生视频、中途帧和最终打开状态，定性确认静态侧栏位于整体平移的全宽对话后方；版本/哈希来源见ignored `media-provenance.json`。这不是FPS、完整全文视觉或中途接管验收；原始媒体不发布。

本次共有AX modal范围把活动侧栏面板和保留前景关闭动作纳入同一modal范围，hosted panel避免嵌套独立modal，standalone默认行为保留；修改针对scrim的AX边界。严格原生路径在此候选通过，**不把这项修正宣称为用户原29许可popup不能点击的唯一根因**。原29完整指纹同段长中文实点24.295s已PASS，原症状仍NOT_REPRODUCED／根因未定位；其r1/r2只是harness错误。

[31](restart-native-hit-build31-2026-10-15.md)、[32](restart-native-hit-build32-2026-10-15.md)、[33](restart-native-hit-build33-2026-10-15.md)失败以及[34](restart-native-hit-build34-2026-10-15.md)严格FAIL19.395s/物理点击诊断PASS21.783s均保留。AX框正确、物理点击能关闭与严格isHittable失败是旧候选同时存在的事实，不因35通过而改写。

package证据为 ignored `packages/ios-navigation/.build/reveal-review/RESULT-final-common-modal-25-r7.json`，SHA-256 `9809d313e6f3b00863172392700310ac0e1cf407c7a54924a70af19cefed958a`，对应Host `1c7a2dada7e0d05d0b50e3fe7848592bc73ed5846d2132b98b93ae16a1f08f50`；日志SHA-256 `68c9c7b69c6de32f87dc2ac3aad4fdc513b798e6bedf5b97eddee12379e47dde`。原始App、日志、xcresult、附件/视频和去敏汇总 `RESULT.json` 留在 ignored `build/native-hit-drawer35-20261015/`；不发布原始媒体或完整App文件名清单。`body-pan-r1.log` SHA-256 `012c0c3218b7b9781492537afd922ef0457dc6fa3ce56b0080776ffd3cbbe895`；`native-r2.log` SHA-256 `15465bec0c2abc57309241701bf5d4f83044f589977c6a063e469a0b2bc510b7`。`max-ax-r1.log` SHA-256 `33373e7fa91170fd121557f79c7403f1d2cb29d59d1357e813aba489b1856e0e`。

用户固定“小咪最新体验”已由29更新为35。主工作目录 ignored `build/device-hub-latest/LAUNCH-RESULT.json` 在 `2026-10-15T06:40:30.745740+00:00` 读回0.3.0(35)、`installed_bytes_match=true`及同33文件指纹；本次独立读取结果SHA-256 `159d834cba2ea1124aac507431ce3b111e6e24376098a19113483cb4f860734b`。启动前后requests为77→78；accepted_posts均0、memory_posts均0、provider_calls均4、turns均2，四类增量均0，不能把历史provider总数4写成0。原store、合成backend27和session保留，未续期；私有设备/store/session标识不发布。本轮测试是实际SwiftUI/UIKit/XCTest加明确本机合成夹具，未执行真实Auth、模型、生产SQL、部署或手机安装。21个不同方法通过与最大字号同方法复验共22次执行，不能记成22个独立方法。全文视觉、全尺寸/主题/软键盘、VoiceOver、Reduce Motion、中途接管像素、card-growth、图片二级许可及真实产品门没有完成，不签收AF-G5、FINAL-G1/G2/G3、七天日用或竞品门。

本版去敏归档：[416项源码哈希](evidence/native-hit-drawer35/source-snapshot.json)、[实际结果汇总](evidence/native-hit-drawer35/result.json)。它们记录本地冻结与选择性发布的区别，不包含原始媒体、完整App文件名清单或私有体验标识。
