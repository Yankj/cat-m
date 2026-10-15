# 原生阅读锚点 build36 · 2026-10-15

候选 `AF-UX-READING-20261015-36-R7`，**0.3.0(36)**。最终产品源码的8条新单元通过；上方成果增长补偿、用户主动移动后下方增长不补偿、回到底部恢复跟随的完整原生方法同包 **PASS，31.059s**。旧14单元＋8UI回归已终端PASS；最终源治理及源码发布已读回。合计31个不同方法通过，分三次执行对齐同一最终产品字节，不把r6整条UI失败改写为通过。固定用户体验版已由35更新36，版本和同包字节已实际读回，原store/backend/session保留。当前进度只见 [master-plan](../status/master-plan.md)，本文件保留失败演进，不关闭完整UX/产品门。

最终419项输入见 ignored `build/native-reading-anchor-20261015/r7/source-snapshot.json`，SHA-256 `64bc47fb03db60c08fbfc93fb0b2414ad0115a1b9591955c4dcc686f67f8a17d`。冻结本地提交 `dff947889ffdad7d57024b3173097859f46650da`，419项源码由协调者逐项核对Git对象PASS；分支 `fix/reading-anchor` 的7条明确路径选择性发布远端 `03471262092a659781429edf06fb1ff317ead44e`，tree `8f4740698ace7492c400d6216e9d323a6ca15cdc`，已更新并读回。snapshot内base是此前来源；不声称本地/远端完整tree相同。独立 `r6/CatpawM.app` 的32项文件已逐项大小/SHA-256匹配 `r6/package.json`，Info.plist为0.3.0(36)，包指纹 **`ca1ff05be0af4c1d7a9144dcd0f3b568fde3e5088767521c13718dc47095a147`**，manifest SHA-256 `8eaea6d34e7215e75d622b3dff6d6a60bde8d32844535822a6baa9ec0f61e5d3`。r6→r7只修改测试 `ConversationReadingAnchorUITests.swift`：先由正常用户手势移到下方待处理卡附近，确保其实际渲染，再检查下方增长；产品源码及包指纹不变。

| 实际轮次 | 结果与证据边界 |
|---|---|
| 最初RED r1–r3 | 测试前置失败：AX框包含被键盘/导航遮挡的区域、远处lazy卡未渲染、阅读深度不足；不能当产品漂移证明。原日志与attempt-history保留 |
| 无补偿旧实现对照包 / `Reading-red-r4` | **严格FAIL，28.359s**；阅读块未变，上方实际成果替换已发生，正文y约54→653，**漂移599pt**，超过3pt门。包指纹 `1e9f61ba1a1fc2b398f6ae8301bc838b2e383e1f432b738030258850e263a104`；这是标记36的对照测试包，不能冒称已交付35原包 |
| 首次实现r2产品 / `Reading36-focus-r4` | **8单元PASS，原生UI仍FAIL27.177s、同599pt漂移**；包 `f76596de060c35074d6e58120a6931703a95e6467ebb3aae1168520606542a46`。单元通过未证明真实UIKit布局链可用 |
| 诊断r5 | 原生方法仍FAIL27.030s；保存的100条真实诊断事件中，32次 `old_y==new_y` 的offset KVO紧接下一次commit前已清空旧锚点。零实际位移回调破坏了用于比较增长前后的snapshot；原100事件及419份源码字节仅留本地，不发布原ID |
| 最终产品 / `Reading36-focus-r6` | **8条新单元PASS，0.232s**；实际上方增长≤3pt断言已通过，但下方lazy卡未渲染，完整UI **FAIL33.261s**。不能只摘上半段写整条PASS；协调者实际目视前后段2/3保持同位置 |
| 同一最终产品 / `Reading36-native-r7` | **完整UI PASS31.059s**；真实上方结果/表单卡已出现，同正文与相对位置≤3pt；明确用户移动后，下方结果实际渲染且不误补偿；一次合成reply，回到底部恢复跟随 |
| `Reading36-regression-r7` | **14/14旧单元＋8/8旧UI PASS**，unit7.472s/UI228.948s，最终 `TEST EXECUTE SUCCEEDED`；覆盖许可、三条抽屉、GenUI编辑保留、导航/双草稿及流式阅读位置 |

最终修复只在真实offset变化时清除旧阅读snapshot，使用稳定行和行内阅读点进行补偿；跟随最新、实际用户移动及无共同测量行的边界由新单元覆盖。临时runtime诊断已移除，`P0ExperienceProbe.swift`恢复与35相同旧字节，SHA-256 `8dd1c7de269ccb8d4f63c58fd6dc2ad0bad41879a4348f5205d0892acb75dedb`。诊断r5的419份 `source-files` 已独立逐项重哈希匹配，来源清单 `r5/source-inputs.json` SHA-256 `d42e870420996b21154afdf38ba68374ef2da8a8c09c9d66bfe8a2a4935feab7`；原100事件附件SHA-256 `e50faf05a144519af8f065c5e5b7d4a475c3d5a64bd7a74e3ef241ad42fe25fc`，仅引用去敏统计。

SDK-r6 **PASS**：non-DEBUG Simulator SDK typecheck、语法、117 App成员、1091双语资源及13设计变异。r7仅测试改动的Runner构建通过。布局/冻结来源/部署快照/AFgoals/AFplan/FINAL/CGUI/敏感八组在 `*-r7.log` 重跑PASS；敏感扫描1182候选、0阻断/0待审、145既有精确误报，当时新日期报告尚未落盘，最终证据提交仍需协调者最后复扫。新9个方法＋旧22个方法共31个不同方法（22单元/9UI），分别来自focus-r6中8条单元、native-r7完整新UI及regression-r7，历史失败轮次不计最终通过数。

协调者另实际目视r7下方增长前后段16/17位置不变；两组仅定性观察与3pt断言，不宣称0px或FPS。

原始日志、对照/中间/最终App、xcresult、截图、诊断原数据及去敏 `RESULT.json` 均在 ignored `build/native-reading-anchor-20261015/`，媒体及完整App文件名清单不发布。关键日志SHA-256：`reading-red-r4.log` = `255ea212ab907baed3f407ced333130ebeb877cfeeae60015b9a55c8ed635c72`；`reading36-focus-r4.log` = `1e25b79f558b3ca071c509458fa1f0775e200a986f763bcfe9b87f97766a4049`；`reading36-focus-r6.log` = `17fb3daf248723678d33fdc5718972156d0b92594061e39173d5d70f592b5ed4`；`reading36-native-r7.log` = `4c64885d7b684b8addbf7b239c8036a8dbd032460470ebbbac186fa66c3a67ff`。最终 `reading36-regression-r7.log` SHA-256 `8c983f8c7cac8e5e543ec1d3c66b3d9c21e94be386b48875722ca52f27dad8bf`。

固定“Catpaw 最新体验”已安装并启动36。主工作目录 ignored `build/device-hub-latest/LAUNCH-RESULT.json` 在 `2026-10-15T07:18:12.671344+00:00` 读回0.3.0(36)、`installed_bytes_match=true`、同32文件指纹及同源提交；该实际结果SHA-256 `92acb17d8f2ca9c0704e4dd846c415faef8d069e49fdaddeb89b5c6bd5484222`。启动前后requests81→82，accepted_posts均0、memory_posts均0、provider_calls均4、turns均2，四类增量均0；历史provider总数4不是本次新增调用。原store、合成backend27及session保持，无续期或额外发送；私有标识和个人绝对路径不发布。验证为实际SwiftUI/UIKit/XCTest加受控离线事件，不是真实模型/云端成果增长；无真实Auth、模型、生产SQL、部署或手机安装。**没有36最大辅助字号、VoiceOver、完整Reduce Motion、冷启动阅读锚点持久化及全卡类型/增长矩阵证据**，不关闭AF-U04全矩阵、AF-G5、FINAL-G1/G2/G3、七天日用或竞品门。

Archived evidence: [419 source hashes](evidence/native-reading-anchor36/source-snapshot.json), [actual scoped results](evidence/native-reading-anchor36/result.json). These are dated, source-only/redacted records; raw media and App inventories remain local.

Final delivery: all 419 frozen input Git blobs also match the independent public index whose tree was confirmed by the GitHub API. Layout, frozen/deployed sources and AF/FINAL/CG planning checks pass; final evidence sensitivity scan has 1185 candidates, zero blocking/manual findings, and the same145 reviewed exceptions. No media or extra exception was added.
