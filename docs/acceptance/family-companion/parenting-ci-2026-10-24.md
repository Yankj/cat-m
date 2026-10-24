# Parenting native evidence — 2026-10-24

接续[2026-10-23固定SHA记录](parenting-ci-2026-10-23.md)，按代码、自动测试、设备、线上分别记录。M1固定c37的69模块+7 UI成功证据保留；本日M2a须以自己的SHA验收。

## 1180815：99模块和原7条UI通过，新增旅程尚未到达采用

[118081546f6f0c742606124c725ef9867f15a65e / CI40042802016](https://github.com/Yankj/mimi/actions/runs/40042802016) 已终态FAILURE；changes120717528528和Edge120717583850成功，[iOS120717583845](https://github.com/Yankj/mimi/actions/runs/40042802016/job/120717583845)失败。base4ec8118、测试合并候选67b5d96127f388a614ea617933cca3a0094cd8c0；没有实际合并。

NoBug便携测试、项目成员、Xcode build-for-testing和签名检查通过。**99模块方法全部通过、0失败**，11.330秒（壁钟13.254秒）；包括14项安排调整/Store、16项request/parser/controller及全部M1模块。Lord Howe半小时回拨方法本次0.020秒通过，保留两次重复时刻、邻接有效时间及显式offset向量。

| 同SHA实际UI方法 | 终态 |
|---|---|
| 深色accessibility5长输入/放弃 | PASS，147.340秒 |
| 独立观察新增/更正/来源时间/原ID目标冷读/删除再冷读 | PASS，126.156秒 |
| 原位AI/确认调整/完成回顾/原ID时间状态记录冷读 | PASS，439.248秒 |
| planned取消/原ID时间状态冷读/无完成记录及无提醒文案 | PASS，199.892秒 |
| 准备失败/pending冷恢复/清理/新整理/取消 | PASS，245.761秒 |
| M2a选中安排改期/冷读/撤销 | FAIL，414.388秒；采用按钮未被点击，后续保存/冷读/撤销仍未到达 |
| 真实SwiftData保存故障/rollback/输入保留重试/冷读唯一孩子 | PASS，48.491秒 |
| unknown只核对原请求/不自动采用/显式采用编辑/取消 | PASS，235.411秒 |

**8 UI为7通过/1失败**，1856.687秒（壁钟1856.713秒）。107个原生方法全部开始并结束：106通过/1失败方法/1失败断言，没有native跳过或整方法重试。原生job00:01:10–00:41:00，测试步骤00:06:01–00:40:53，正常exit65、TEST EXECUTE FAILED，非超时或取消。Xcode26.6(17F113)，macOS26.6.2；不等于真实手机体验。

唯一失败在UI测试219行的Adopt reveal：候选原/新时间、原名称及Save禁用检查已通过，candidate-not-applied截图已生成。测试先滚到候选下方名称输入，再默认向下找已虚拟化的上方Adopt，16次拖到表单底部后失败；没有合成tap、业务保存错误或持久化失败证据。AX仍显示编辑页、禁用保存及原名称/原时间/最初原话。此前添加目标的18点label已修为44点，本次原有7条UI完整通过，不把单次绿色当成此前丢点击的唯一根因证明。

下一候选只调整新增旅程的顺序：候选日期差异/Save禁用/截图 → 实际采用 → 检查名称仍为原值 → 下方确认区 → 导航栏保存 → 原ID冷读/撤销/再冷读。名称断言保留并移至采用之后，实际检验模型替代名称未被应用；不再先滚下再找上方虚拟化候选。独立只读复审确认此顺序符合现有Form布局，后续Home为非lazy VStack，未发现同类确定遗漏。全部99模块/8 UI方法、原文/身份/时间/目标/历史/去重/冷读断言、15秒条件、16次滚动及60分钟整组预算保持；没有加整方法重试或产品功能。

Edge913总数/911通过/0失败/2跳过，51.176秒；12个既有隔离文件仍排除。真实PG及CRUD/RLS检查仍跳过，不据此宣称SQL或多实例验收。41次截图attachment事件含一次改期候选，未到history/undo阶段；截图只在runner xcresult，未取回、上传或视觉审阅。

**118尚未关闭M2a**；当前产品字节的编译和99模块通过，原7条UI也通过，但新增主旅程仍需新候选完成。M2b周期/单次例外及M2c本机提醒尚未实现；没有真实手机、真实模型、生产Auth/PG/RLS/系统通知或线上验收，后台未部署。未导入独立治理#124、调用生产、新配凭证、上传源码/截图附件、合并或发布。

118恢复补丁仅本地保存：968808字节，SHA256 `cd8f078421b811ecd01ea412bda88eb66b7912d0b5adda8c3feeac08db316403`，从main基线应用后50个文件逐一字节匹配；不是用户可下载链接。

## ba1234a：M2a编译、99模块及8 UI全部通过，交接后暂停

产品候选 **`ba1234a498d440f823505e3d7d839a29491c85b1`** 的[CI40046503653](https://github.com/Yankj/mimi/actions/runs/40046503653)已终态SUCCESS；changes120729341943、[iOS120729392844](https://github.com/Yankj/mimi/actions/runs/40046503653/job/120729392844)、[Edge120729392912](https://github.com/Yankj/mimi/actions/runs/40046503653/job/120729392912)全部成功。GitHub测试合并候选48e3276320e9ca8a9a4ddf8f799da6dbce2e7c89，base main4ec8118b796f7c983ae4436268441c3c9d3d33db；没有实际合并。

NoBug便携测试、项目成员、Xcode build-for-testing及独立主App签名/生成标识/Keychain group检查通过。**99模块/0失败**，10.613秒（Selected tests壁钟11.623秒），包括Auth8、Account4、ArrangementEdit14、Inline27、Intake8、Reschedule16、Workspace22。

| 同SHA实际UI方法 | 终态 |
|---|---|
| 深色accessibility5长输入/放弃 | PASS，139.551秒 |
| 独立观察新增/更正/来源时间/原ID目标冷读/删除再冷读 | PASS，229.139秒 |
| 原位AI/确认调整/完成回顾/原ID时间状态记录冷读 | PASS，434.606秒 |
| planned取消/原ID时间状态冷读/无完成记录及无提醒文案 | PASS，115.575秒 |
| 准备失败/pending冷恢复/清理/新整理/取消 | PASS，156.429秒 |
| M2a选中安排改期/同ID时间及来源历史冷读/撤销/原时间冷读 | PASS，310.730秒 |
| 真实SwiftData保存故障/rollback/输入保留重试/冷读唯一孩子 | PASS，41.533秒 |
| unknown只核对原请求/不自动采用/显式采用编辑/取消 | PASS，189.603秒 |

**8 UI/0失败**，1617.167秒（Selected tests壁钟1617.187秒）。107个原生方法均实际开始并通过，没有跳过或整方法重试；01:23:23UTC为TEST EXECUTE SUCCEEDED，xcodebuild测试operation1835.227秒。没有删除失败用例、缩减行为断言或放宽15秒条件/16次滚动/60分钟整组预算。ba相对118仅移动新增旅程的名称保留断言至采用之后并更新文档，产品源码/资源/工程/脚本/后端/CI字节相同；本次实际走到了保存、冷读、撤销和再次冷读，不能仅由前序部分绿色推断。

Edge **913总/911通过/0失败/2跳过**，67.220671539秒；12个既有隔离文件仍排除。两项真实PG与CRUD/RLS集成未运行，不证明SQL、多实例或生产。M1固定c37的69模块+7 UI通过保留为独立基线，不与本次重复累计。

实际UI使用Home/controller、默认生产Keychain-AES、SwiftData、终止后重启；身份和模型transport合成。NativeAuth收据/可信代次/同chat恢复另用真实应用model加mock端口。截图只在runner xcresult，未取回、上传或视觉审阅；没有真实手机、真实模型、生产Auth/PG/RLS、APNs或通知验收，后端未部署。没有采集真实儿童数据。

本次关闭M2a代码与合成原生回归门，**不等于完整M2或生产验收**。用户最新要求“在最近一个版本收尾然后理清handoff”，因此完成[版本交接](parenting-core-handoff.md)后停止；M2b周期/例外、M2c提醒及M3后续不再自动推进。交接资料提交位于ba之后，应单独核对最终远端HEAD及其CI，不把ba结果冒充后来文档SHA的实际运行。保持同一草稿PR #123，不合并、不部署、不发版、不上传源码或截图，不导入独立治理#124。

产品补丁仅本地保存：974132字节，SHA256 `41fca9c714d4e8be34182f7daeb26ef1db3ba21a0c6481303d59c05ea13b8845`；从main基线apply-check/apply后51个路径逐字节匹配。最终资料提交的补丁及远端/CI回执写入ignored的`build/parenting-core/m2a-handoff-current.json`，父任务最终摘要另回传精确SHA；执行环境路径不是手机可下载链接。
