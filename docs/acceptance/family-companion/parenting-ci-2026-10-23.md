# 育儿核心 M1：GitHub 与原生 CI 接续证据

本记录接续本地候选[日期审查](parenting-core-review.md)，不改写初次候选的54项原生未运行、Linux工具缺失和70项离线Node历史结果。实时状态在 [master-plan](../../status/master-plan.md)，后续依赖在 [M1–M6差距矩阵](../../design/family-companion/parenting-milestones.md)。本轮仅收口M1；里程碑和治理文档由独立 `refactor/mimi-roadmap` 分支负责，未收到精确提交前不并发修改或整合。

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
| `974dbb13db1113a49bd5b5cdc3c645663313b13a` / [39986351154](https://github.com/Yankj/mimi/actions/runs/39986351154) | 三个job均完成SUCCESS。Xcode26.6实际build-for-testing通过；[原生job120527182599](https://github.com/Yankj/mimi/actions/runs/39986351154/job/120527182599)实际执行54项XCTest（21 workspace + 8 parser + 25 inline），0失败，`TEST EXECUTE SUCCEEDED`。Edge job120527182538实际906通过、0失败、2跳过（908总数），约95.3秒 | 合成XCTest不是UI操作或真机体验验收，也不证明真实模型、PG/RLS、系统通知或线上服务；新发现的删除早于创建问题需下一个候选修复并重跑 |

PR workflow默认checkout GitHub生成的合并候选：初次为 `00d333a7a5b3395a55afaed3d69a4dd6af75523a`（973a8f2合入4ec8118），不是实际合并到main。必须将head、base、CI合并候选和部署版本分开。

974dbb1的CI合并候选为 `f412391d763017d5a970f35234e2917e0596180d`，base仍为 `4ec8118b796f7c983ae4436268441c3c9d3d33db`。原生定向步骤约16:33:32开始，16:40:19返回成功；xcodebuild记录404.179秒，测试本体约7.5秒。先前in_progress期间日志暂不可取，不能作为通过证据；此处结论来自终态job及54条实际执行结果，未出现超时或用例失败。该日志摘要保留在忽略目录 `build/parenting-core/ci-39986351154-ios-excerpt.log`。

## 后端实际回归及修复

初次Edge CI在 `dialogue-p0.test.mjs` 的“one authentication per POST”实际报 `2 !== 1`。本次API新增的普通namespace预读取先鉴权，随后原startTurn又鉴权，属于本次回归；断言又在provider latch清理前失败，使旧suite挂住，后续修复push由concurrency取消它，不能记Node全量通过。

现已移除URL层预读取，将purpose比较放到既有授权事务。普通start/revision/accepted-work仍用原startTurn事务检查；read/cancel/retry/control/device/interrupt各在已有读写点校验；observe在snapshot及缓存事件输出前核对。PG conversation-head不投影purpose，因此两个readTurn存储分支核对turn marker。育儿只读入口在同一事务先做不加锁的主体/purpose拒绝预检，随后仍执行原有fresh source/consent/epoch围栏，不复用预检授予访问，也不增加一次鉴权。测试清理加after钩子，失败时也释放provider latch，原1次鉴权断言保留。

本机Linux追加实跑两组：`dialogue-p0 + parenting-intake-http + sse-observer-retry` **53/53 PASS**；原9文件组加task-revision/revision-work/accepted-work的12文件组 **115/115 PASS**。两组有重叠，不累加为168个独立测试。新intake现在15项，新增单次鉴权及投影存储port覆盖；此投影mock不证明真实PG/RLS执行。均使用既有offline-prelude及strip loader，无依赖安装/生产调用。日志在忽略目录 `build/parenting-core/m1-auth-regression.log` 和 `m1-expanded-node-regression.log`。

## 删除早于创建的M1阻断

独立审查复现：原位整理在远端create之前持久保存cleanup引用；离线、旧端点404或鉴权失败后退出，DELETE不存在cid持续404，账号后续所有整理被deletionPending阻断；同cid迟到create反而能成功。不能通过忽略所有404解决，否则会丢失身份围栏并允许迟到创建复活。

修复在同一scoped业务事务中为不存在cid使用 `insertIfAbsent` 建立subject/scope/purpose绑定、无原文的revoked墓碑；唯一键冲突后重读并校验身份，不能UPSERT覆盖普通会话或别的主体。create与DELETE采用一致scope→cid锁顺序，迟到create/start返回410；重复DELETE返回精确绑定的200凭据。客户端保留严格的HTTP200、subject/scope/cid/purpose/purged校验，不放宽404。该墓碑不含孩子档案、原话或答案，保留其标识用于拒绝原请求复活；新的独立cid仍可整理。

新增3项实际HTTP handler/ChatService/TestRepository测试覆盖：创建前取消及冷恢复、两种create/delete顺序、缺失预读后普通/foreign插入赢家。新intake共18项，独立复跑18/18 PASS；与dialogue-p0、SSE observer组成的本机组 **56/56 PASS**。实际产品模块执行，外部鉴权/模型/持久数据库port为合成边界；并发顺序及注入交错不等于真实PG双连接并发。日志 `build/parenting-core/m1-delete-before-create-regression.log`。补充原生控制器和实际NativeHTTP删除凭据测试后，仍须以新SHA的CI结果判定。

扩大12文件组首次117/118：对普通create增加的conversation锁改变既有account-consent锁序观测。将新增scope→cid协议限定育儿create后重跑 **118/118 PASS**（51.115秒），未修改原锁序断言；普通/旧创建者仍由唯一键 `insertIfAbsent` 冲突检查保护。两组合计有重叠，不能累加分母。日志 `build/parenting-core/m1-expanded-delete-regression.log`。

原生测试新增2项至 **56项**（21 workspace + 8 parser + 27 inline）：真实控制器在准备失败后取消、持久pending、fresh epoch和repository重开、清理重试后新cid成功；真实NativeHTTP adapter配全拦截URLProtocol验证10种固定wire输入，404/401/离线和错误身份/purpose/purged/retained均拒绝，仅精确200墓碑回执接受。URLProtocol不实现服务器状态机，也不会退回真实网络。这2项写入及静态审查通过，提交时尚未SDK编译或运行，不能借974dbb1的54项通过替代。

## 接续测试范围

新增CI定向运行脚本只选择 `catTests/ParentingWorkspaceTests`、`ParentingIntakeTests`、`ParentingInlineIntakeTests` 三类合成用例。使用已安装iPhone runtime创建自己的空白模拟器，结束只删除本次创建的设备；存在Local.xcconfig时拒绝执行，移除四个backend环境配置及继承fixture/connection/simulator-child注入，不安装依赖或下载runtime。测试使用临时文件和mock transport，无真实儿童数据、真实模型、生产Keychain或数据库。空Debug配置使项目Auth/后端启动被guard拦住；现有AppDelegate仍有系统APNs注册/BG任务注册，未测量全进程或系统网络次数，不声称全进程零网络。

`build-for-testing`只编译，定向XCTest步骤运行后才可报告其实际执行数量。新测试script和workflow的shell/源码检查不能代替SDK执行；此刻仍无原生UI、真机、真实模型、PG多实例、系统通知或线上后端验收。

远端Edge job沿现有Node22脚本，包含既有quarantine并安装既定公开依赖；没有本机offline-prelude网络屏障，不能把它改称“与本机70项相同的全部离线测试”。其结果按该job实际分母/失败另列；不据绿色Node结果推断数据库或原生通过。
