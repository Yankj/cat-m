# build23 原生阶段体验与字号共性收敛

日期：2026-10-14。最终候选 `AF-UX-TYPOGRAPHY-20261014-23-R2`，版本0.3.0(23)，源码/证据已按41条审阅路径提交为`7ac5518aa8d64d58707f9a093c2fd24ac48fee98`，读回234项输入hash全部一致。当前进度仅维护[master-plan](../status/master-plan.md)；本文件固定此候选的操作范围和证据，不关闭AF或FINAL产品验收。

## 立即点测

已安装并启动到已有专用iPhone17模拟器，读回build23、系统large，402×874pt、iOS27。Xcode27用Device Hub展示模拟器，打开命令成功；Mac锁屏阻止了窗口人工观察，不把CLI成功说成窗口已人工验过。解锁后选择`Catpaw-AF-start-20261014`；需要重开流程时，在仓库根运行：

```sh
zsh apps/ios-conversation/Scripts/run-simulator-review.sh report
```

本地[完整模拟器包](../../../build/typography-trial-20261014/CatpawM-0.3.0-build23-simulator.zip)和[启动脚本](../../../apps/ios-conversation/Scripts/run-simulator-review.sh)已准备；包为模拟器架构，不能安装到iPhone。Xcode工程保留原配置版本，复构建此候选需显式`CURRENT_PROJECT_VERSION=23 MARKETING_VERSION=0.3.0`，包指纹不符时启动脚本会拒绝，应按新候选重新核验，不能仅用build号证明对应。

默认进入**明确标注的离线原生流程**，系统字号large、正文17pt。先发送一条任意短文本，等合成报告v2出现；展开工作卡，进入成果，点手动编辑、保存，再返回对话检查未发送草稿。来源与回执是人工数据，没有网页读取、Auth或模型调用。试验模式不把模拟回答伪装成真实Agent。

同一份App还可切换：

| 命令末尾参数 | 可点测行为与边界 |
|---|---|
| `input` | 普通输入、草稿、明确合成流；没有真实模型 |
| `plan` | 查看/修改同工作计划、关闭重开保稿；计划后端在进程内，不承诺跨进程云持久化 |
| `report` | 成果v2、手动改稿v3、历史/来源阅读、独立对话草稿与修改草稿；人工server文件持久化，来源未实际读取 |
| `approval` | 精确审阅、关闭找回审批、接受后待设备；不写系统日历/通知 |
| `control` | 同工作暂停、恢复、撤回授权及人工回执；不证明真实worker接管 |
| `calculator` | 本地时间预算试算、流中输入稳定；无日程效果 |
| `normal` | 没有fixture的正常首用页；本包不含云配置，开始体验禁用 |

每次脚本启动生成新的隔离fixture目录，保留既有目录和用户数据，不清空、卸载或重置。脚本先核验build23、bundle身份和五个公共云字段为空，清除所有继承的`SIMCTL_CHILD_*`后仅添加选定P0场景。它主动还原默认字号，不能用于XXXL/AX5或冷恢复取证。实际源码位于`apps/ios-conversation/Sources/`，不是独立演示页面；fixture仅提供受控数据/服务替身。

## 这次处理的共性

此前四张22图片都是显式accessibility5压力档，但长标题被同排状态挤窄确属真实布局缺陷。此前只验证共享编辑器，没有把页面字号绕行和容器排布纳入共同门；截图也未优先展示默认档。此次按四个边界修复：

1. 当前页面使用语义字号，SwiftUI环境与UIKit的preferred font映射一致；侧栏由宿主注入语义Font，图片preview显式传递字号/locale。
2. 共用header先按内容实际宽度选择同排或全宽纵排，辅助字号强制纵排，完整标题/状态与44pt区域保留，VoiceOver不依赖排布分支。
3. 启动场景与字号解耦；未设置`CATPAW_UI_TEST_TEXT_SIZE`时尊重真实系统类别。旧最大字号用例在各测试helper显式选择压力轴。
4. caret提交依据实际scroll extent与一物理像素容差，装饰padding只参与滚动目标。保留IME/拖动门，不把20次同viewport重新计算变成20次提交。

`scripts/check-typography.py --self-test`已接入宿主check-source，默认覆盖新增和现有活跃源码；10个具名旧presenter属于非生产入口排除。SF图形和QA只按具名表达式豁免，不能凭整个DEBUG文件绕过门。静态门不能判断每句话的视觉层级，仍需要每片默认字号实际页面复核。

## 证据与限制

初始revision的默认13项、XXXL2项、AX5五项在旧断言下通过，后续截图复核发现默认改稿正文实际只可见19.33pt，判为视觉FAIL。旧断言把键盘前的边界和键盘后的field/footer混在一起，不能当可见性通过。保留原包、原始结果、截图，以及同原包上的严格断言RED 1/1 FAIL，未改写为PASS。

最终revision的共享恢复改用实际UIKit内外层交集，并保留IME/拖动期间的待恢复请求。最终同包：默认12项（8个真实UIKit/算法单元＋4个宿主UI）、XXXL2项、AX5三项全PASS，17次执行、14个不重复方法。覆盖18组预算、40KB连续编辑、实际caret/marked API、不变viewport、真实嵌套外层恢复、改稿/跟进/保稿、正常无fixture首用、系统字号与长标题/撤权。严格UI断言要求三组稳定AX+实际UIKit观测、当前EDIT-END选区末尾、完整光标和≥44pt编辑区；默认/XXXL/AX5实测编辑区129.67/172.67/121.67pt、字体17/23/53pt。字体见证用例三档均没有QA字号override。计划与精确审批在此前同文字组件revision已测，但未在最终编辑恢复revision重跑，不冒充本版完整业务总回归。

最终234项source/test/config hash、完整App的26文件（含Debug dylib与签名）hash、六张未改像素截图来源、测试/检查日志hash固定于[RESULT.json](evidence/native-typography-20261014/RESULT.json)。启动脚本会核完整包指纹，拒绝同build号却字节不符的包；测试或附件旧v20命名不是实际版本，实际build23与revision由包读回和此映射裁决。

本包是Debug模拟器阶段体验版，未安装手机。真实provider已有第一条失败证据，未新增请求或改变模型路由；没有复制生产配置、部署或发布。下一可交付版本应接通现有真实会话链路并将CP-01服务/原生同版核验，不能用本版替代真实Agent体验。W50/W60六个独立后台原语文件保留为未集成WIP，不计交付。

物理iPhone性能、完整VoiceOver/动效/跨设备尺寸、真实图片传输、真实PG竞争/独立调度/日程效果、七天日用及竞品配对仍未由本片验证。实际UI有滚动/拖动，但未获得手势过程中caret selection/帧呈现的独立观测，不能把UIKit单元的人工marked API当真实输入法操作。图片preview的环境转交完成SDK检查，具体弹层尚未由本轮运行时截图单独签收。
