# 育儿核心 M1：GitHub 与原生 CI 接续证据

本记录接续本地候选[日期审查](parenting-core-review.md)，不改写其54项原生未运行、Linux工具缺失和70项离线Node结果。实时状态在 [master-plan](../../status/master-plan.md)，后续依赖在 [M1–M5差距矩阵](../../design/family-companion/parenting-milestones.md)。

## 已获授权的操作与来源

2026-10-23用户明确批准新分支普通推送及草稿PR，随后要求逐个里程碑推进；不包含合并、自动合并、部署、发布、生产调用或附件上传。本轮沿同一 `feat/parenting-core` 和 [draft PR #123](https://github.com/Yankj/mimi/pull/123) 继续，不覆盖独立分支。

创建前已核实仓库ID `1413057312` 对应 `Yankj/mimi`，main为 `4ec8118b796f7c983ae4436268441c3c9d3d33db`，同名分支及PR不存在。推送后远端精确SHA为原本地提交 `973a8f2cdc468e60ed007c128194adcac334a2ae`；PR读回为draft/open/unmerged，base为上述main。此前PR #122品牌成果仍为祖先。没有force push。

仓库内已知触发器审查：`ci.yml`在PR运行，`release-ipa.yml`仅`release/**`push或手动dispatch，Website仅网站路径变更。本次分支与PR无已知生产部署触发；未修改部署配置。仓库外Apps/webhooks配置不由本地文件证明。

## 精确候选与执行层

| head SHA / CI | 实际执行与结论 | 未执行及归因 |
|---|---|---|
| `973a8f2cdc468e60ed007c128194adcac334a2ae` / [39983178500](https://github.com/Yankj/mimi/actions/runs/39983178500) | macOS26.6.2 / Xcode26.6；便携Swift编译真实失败：`ParentingInlineIntake.swift:4` 找不到 `ConversationSessionService`；属于本次引入。修复push后的concurrency取消旧Node job | 工程检查、宿主build-for-testing被前序失败跳过；54 XCTest未运行。旧run不得写为通过 |
| `58cada277f5ce8e31242ff593f49017e17275a39` / [39983474486](https://github.com/Yankj/mimi/actions/runs/39983474486) | 最小移动factory到功能层；名称/签名/权限不变。便携357通过、PR90 proactive通过，官方工程检查238源/4targets通过。宿主编译真实失败：InlineModel:94在catch中未写self，赋值误指不可变Error绑定；属于本次引入，已补self.error | 54 XCTest未运行；未把便携测试或工程检查算作育儿原生测试 |
| `dd8661a4e3b703eb67184661b2a0a4f7ef5011d0` / [39984692961](https://github.com/Yankj/mimi/actions/runs/39984692961) | 便携及工程检查通过；编译推进到catTests，新增夹具:757的可选MainActor throwing闭包三元表达式触发Swift诊断失败。已改为显式if赋值，语义和54项数量不变 | build-for-testing失败，定向XCTest步骤跳过；不能把产品模块编译进展称完整构建通过 |

PR workflow默认checkout GitHub生成的合并候选：初次为 `00d333a7a5b3395a55afaed3d69a4dd6af75523a`（973a8f2合入4ec8118），不是实际合并到main。必须将head、base、CI合并候选和部署版本分开。

## 后端实际回归及修复

初次Edge CI在 `dialogue-p0.test.mjs` 的“one authentication per POST”实际报 `2 !== 1`。本次API新增的普通namespace预读取先鉴权，随后原startTurn又鉴权，属于本次回归；断言又在provider latch清理前失败，使旧suite挂住，后续修复push由concurrency取消它，不能记Node全量通过。

现已移除URL层预读取，将purpose比较放到既有授权事务。普通start/revision/accepted-work仍用原startTurn事务检查；read/cancel/retry/control/device/interrupt各在已有读写点校验；observe在snapshot及缓存事件输出前核对。PG conversation-head不投影purpose，因此两个readTurn存储分支核对turn marker。育儿只读入口在同一事务先做不加锁的主体/purpose拒绝预检，随后仍执行原有fresh source/consent/epoch围栏，不复用预检授予访问，也不增加一次鉴权。测试清理加after钩子，失败时也释放provider latch，原1次鉴权断言保留。

本机Linux追加实跑两组：`dialogue-p0 + parenting-intake-http + sse-observer-retry` **53/53 PASS**；原9文件组加task-revision/revision-work/accepted-work的12文件组 **115/115 PASS**。两组有重叠，不累加为168个独立测试。新intake现在15项，新增单次鉴权及投影存储port覆盖；此投影mock不证明真实PG/RLS执行。均使用既有offline-prelude及strip loader，无依赖安装/生产调用。日志在忽略目录 `build/parenting-core/m1-auth-regression.log` 和 `m1-expanded-node-regression.log`。

## 接续测试范围

新增CI定向运行脚本只选择 `catTests/ParentingWorkspaceTests`、`ParentingIntakeTests`、`ParentingInlineIntakeTests` 三类合成用例。使用已安装iPhone runtime创建自己的空白模拟器，结束只删除本次创建的设备；存在Local.xcconfig时拒绝执行，移除四个backend环境配置及继承fixture/connection/simulator-child注入，不安装依赖或下载runtime。测试使用临时文件和mock transport，无真实儿童数据、真实模型、生产Keychain或数据库。空Debug配置使项目Auth/后端启动被guard拦住；现有AppDelegate仍有系统APNs注册/BG任务注册，未测量全进程或系统网络次数，不声称全进程零网络。

`build-for-testing`只编译，定向XCTest步骤运行后才可报告其实际执行数量。新测试script和workflow的shell/源码检查不能代替SDK执行；此刻仍无原生UI、真机、真实模型、PG多实例、系统通知或线上后端验收。

远端Edge job沿现有Node22脚本，包含既有quarantine并安装既定公开依赖；没有本机offline-prelude网络屏障，不能把它改称“与本机70项相同的全部离线测试”。其结果按该job实际分母/失败另列；不据绿色Node结果推断数据库或原生通过。
