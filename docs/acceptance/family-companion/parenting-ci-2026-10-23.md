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
| `d5f739e9039046c8b52d785c34eb58ff32fa8e4b` / [39989566438](https://github.com/Yankj/mimi/actions/runs/39989566438) | 三个job均完成SUCCESS。Xcode26.6 build-for-testing通过；[原生job120537569259](https://github.com/Yankj/mimi/actions/runs/39989566438/job/120537569259)实际56项XCTest（21 workspace + 8 parser + 27 inline），0失败，新增准备失败清理重开和实际NativeHTTP凭据矩阵均通过。Edge job120537568994实际909通过、0失败、2跳过（911总数），约53.9秒 | 没有UI、真机、真实Auth/model/PG或上线验收。后续定点复现finalizer故障和真实Auth收据恢复组合问题，见下，不能以本次绿色提前关闭M1或进入M2 |

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

上述2项随后在d5f739e的CI实际执行通过；56项模块测试耗时约12.3秒，xcodebuild测试操作338.129秒，16:59:37返回成功。该候选没有UI测试；摘要为忽略目录 `build/parenting-core/ci-39989566438-ios-excerpt.log`。

## 下一M1候选：运行清理、可信账号组合与UI旅程

继续审查发现两项需实证收口的问题，均保留此前绿色的精确候选身份：

- **finalizer读取失败**：在真实admission事务commit后、缓存登记前暂停，DELETE先返回200；恢复执行且最后一次终态读取抛错，d5f739e残留临时原话并未释放运行租约，provider调用0、持久库无原话。嵌套finally现在不让数据库读取失败阻断缓存输入清理或租约释放；只有成功读取rate_limited状态才保留输入供明确重试。新增2项真实handler回归，内存加载旧源码19/20（故障场景红），修复20/20；本机含dialogue/SSE/lease重点组 **65/65 PASS**。扩大12文件组120/120 PASS（51.145秒），与65项组重叠不累加。日志 `m1-finalizer-regression.log`、`m1-expanded-finalizer-regression.log`，不等于真实PG故障演练。
- **回访收据先挂载、认证后恢复**：原Home的StateObject可能在AccountEpoch尚为空时创建固定token Store，随后Auth同namespace复用chat，原对象id不变使重试永久不可用。现在NativeAuth发布实际的 `ParentingWorkspacePresentation`，只在已验证用户、chat主体、scope和当前token匹配时创建模型；同代保留，换代重建，离开账号清空。生产Home注入这一模型并按完整身份重建；旧Store固定token读写屏障保持，未从收据激活账户，也不以联网状态控制本机账本。新增 `ParentingAccountLifecycleTests` 用真实SwiftData、实际Auth生命周期与共享生产组合模型：持有合成/user至preview挂载，验证此时没有账本组合；放行认证后保留同chat，读回既存账本并确认/完成，旧nil-token Store仍拒读写。Auth、scope resolver及cipher为明确合成边界，不是生产Auth或UI截图证据。

新增 `ParentingWorkspaceUITests` 的3条实际宿主操作旅程：空态→手建合成孩子/目标→明确许可/原位合成回复→编辑采用→选时间→待确认→确认→调整→完成记录/目标关联→冷重开；准备失败→退出无安排→清理pending禁发→明确重试清理→新整理；深色accessibility5空态与编辑取消冒烟。DEBUG入口使用独立UUID隔离目录、实际SwiftData/AES/Store/SwiftUI，模型/许可/删除仅在进程内注入；不预置成功旅程的孩子或安排。它预激活合成账号，不覆盖上述真实收据恢复，后者由单独Auth组合测试覆盖。未就绪或打开失败停在fixture专用页，跳过Auth启动、OAuth、APNs、后台任务和调试路由。默认URLProtocol为额外防御，未声称能覆盖每一种系统/后台网络配置。

育儿主按钮改用既有 `calmCTATop/Bottom` 暖橙语义；白字对两端的静态sRGB比为4.520/5.427，按下只缩放、不降低背景透明度；disabled使用已有中性背景/深字。此前dark action白字仅2.323。数值计算不替代渲染验收。

本次提交的预期筛选为 **57项模块测试 + 3项UI测试**，新增部分提交时尚未SDK编译/运行；CI定向步骤设20分钟上限，不将数量或静态检查写成通过。XCTest截图以 `Synthetic-Parenting-M1-*` 附件留在runner xcresult；未新增任何上传，runner结束后的持久截图获取仍缺失。无真机、真实模型、PG多实例、系统提醒或线上验收，后端仍未部署；M2暂停。

## M1 scope 与冷重开接续候选

563f07c 的 [CI 39993290367](https://github.com/Yankj/mimi/actions/runs/39993290367) 已到终态：changes / Edge SUCCESS，Edge 913总数、911通过、0失败、2跳过；iOS job120550319708 FAILURE。该job真实 build-for-testing 成功，57项模块测试全部通过（21 workspace + 8 parser + 27 inline + 1 Auth composition），约10.853秒；3条UI全部实际运行失败，共210.160秒，均在填写首个孩子昵称、点击保存后，等输入页消失超时（当时Tests.swift:212）。它们已到真实首页与添加表单，并非模拟器启动超时，也没有执行完主要AI/安排旅程。xcodebuild测试操作743.546秒，返回 `TEST EXECUTE FAILED`，未因20分钟上限取消。当前日志没有打印表单错误，不能据此断定是关闭动作或Keychain/磁盘失败，下一候选增强该失败点诊断。不得将57模块通过写成3UI通过。后续候选仍只修M1，不进入M2。

独立复审发现默认配置不固定 scope 时，已验证账号可能先打开临时分区，resolver 返回 canonical scope 后再换库；若育儿账本先允许写入，刚保存的数据将从新首页消失。现在仅实际 scope admission 或带 `canonicalScope: true` 的已确认本机 receipt 可以绑定育儿模型，账号验证及固定 epoch 屏障仍必须满足。临时聊天只供原有内部恢复，不再保存 receipt，不获得育儿写入能力。旧三字段 receipt 继续解码并保留原目录，但即使它的 UUID 不像 deterministic provisional scope，也不能证明旧配置 scope 已确认；须等一次实际 resolver 成功。新增标记为可选本机元数据，旧 reader 忽略它，内部安装、存储键和 wire 字段不改。已确认 receipt 在账号验证成功但 scope discovery 暂不可用时仍可编辑本机账本，不以 `networkAdmissionAllowed` 一刀切阻断。此前写入临时目录的数据保留，没有自动跨 scope 迁移。

canonical 打开跨异步磁盘与 detach 时由独立 attempt UUID 占位，迟到 receipt/provisional 不能抢走空槽；取消、账号变更和退出同步失效该占位，旧 attempt 的 defer 不能清除新 attempt。账本等待页增加显式重试，调用既有 foreground/重试机制。

新增3项真实 Auth composition 回归（原1项保留）：无固定 scope 且 resolver 挂起时不暴露账本、解析后只在 canonical 库保存；明确 canonical receipt 在 scope 服务不可用时读写旧账本；迟到旧 receipt 在 canonical 打开窗口被拒绝、原目录保留且新库可写。使用真实 NativeAuthApplicationModel / SwiftData / 生产 presentation，Auth 与 resolver 为合成端口。另加1项生产 Keychain/AES +真实SwiftData首次保存/新Repository冷读回归，使用随机合成subject，不以测试cipher替代失败。筛选预期现在为61项模块测试；未运行的新项不能借前个 SHA 的绿色结论。

本次独立 UI 增强：原有成功旅程增加冷重开时原 arrangement UUID、可见时间、completed 状态、完成记录 UUID 及 goal 关联断言。失败旅程改为真正 terminate/launch，保持同一隔离 store UUID，验证加密 cleanup pending 仍在且阻止有效新原话请求，再由显式清理恢复；仅移除下一进程的合成一次性 transport 失败，不改保存字节。它仍不覆盖真实 Auth/model。

| M1 路径 | 当前证据边界 |
|---|---|
| 保存/确认/完成/记录及目标关联 | 产品模块已有回归；增强 UI 候选待实际运行，不以定义当通过 |
| planned 安排取消后冷重开 | 模块状态机有覆盖；原3 UI没有此旅程，待补最小真实交互或设备验证 |
| 独立观察新增/更正/删除及冷读 | 模块 CRUD 有覆盖；原3 UI未覆盖，不冒充完成记录旅程已测独立观察 |
| 保存失败保留表单并重试 | 模块有持久化失败回归；当前UI没有磁盘故障注入结果，待设备/专项验证 |
| unknown 中断后按原ID核对 | 控制器有mock回归；当前UI fixture.observe明确拒绝unresolved，不具备成功核对证据 |
| 深色大字号 | 原3 UI仅 accessibility5 冒烟，不能替代全页面可读性或真机验收 |

## d92bc91 诊断与 Simulator 签名修复

[d92bc912a0f8993fe26af33e490b004df80f7322 / CI39997128533](https://github.com/Yankj/mimi/actions/runs/39997128533) 已终态：changes、Edge SUCCESS，Edge911通过/0失败/2跳过（913总数）；[iOS job120563531153](https://github.com/Yankj/mimi/actions/runs/39997128533/job/120563531153) FAILURE。真实 build-for-testing 成功；4项 Auth composition 全通过，包括临时scope禁止写入、已确认receipt在scope发现失败时本机可写、迟到旧receipt的打开竞态，以及原同chat认证恢复。模块61个方法中60个通过、1个失败；真实cipher首写显式记录 `cat.L2SecureStoreError.keychain(-34018)`，该方法的断言及再次抛错合计2个failure events（1 unexpected），不能误报2个方法失败。3 UI均实际失败于首个昵称保存，表单直接显示同类L2SecureStoreError，尚未完成主要旅程。模块执行10.796秒，UI249.172秒，测试操作736.377秒，非20分钟取消。

这确认当前无签名Simulator测试包缺少真实Keychain首写所需权限；此前57项使用synthetic cipher的绿色无法证明该边界。修复只调整本CI Simulator lane：由Xcode用仓库既有 `SimulatorFixtureAcceptance.entitlements` 生成本地ad-hoc完整测试产物，build/test共用固定DerivedData和参数。没有真实团队、证书、provisioning profile或设备签名，没有手工重签、测试cipher替换、修改生产entitlements或稳定Bundle ID。运行前精确核对主App的Info.plist、Xcode生成的Simulated.xcent、展开后的application identifier与唯一对应Keychain group、空team，以及本地ad-hoc签名；该静态/产物验证仍不能代替真实Keychain测试。

旧receipt竞态测试进一步使用非空旧配置scope且resolver返回不同canonical scope，明确覆盖旧三字段也可能来自配置临时scope的兼容边界。UI等待失败现在附实际AX tree。下一候选仍为61模块+3 UI，尚待fresh签名构建与实际运行；planned取消、独立观察CRUD的两条UI候选仍未应用，保存失败输入重试与unknown原ID回查也没有UI通过证据。M1未签收，M2暂停。

## 3371c61：真实加密恢复，UI滚动仍失败

[3371c617e68a34c7ddc19af8848cd49c83846aa2 / CI40000305787](https://github.com/Yankj/mimi/actions/runs/40000305787) 已终态：changes、Edge SUCCESS；[iOS job120574431253](https://github.com/Yankj/mimi/actions/runs/40000305787/job/120574431253) FAILURE。Xcode实际签名build-for-testing成功，主App签名、生成的Simulated.xcent与Keychain group核对通过；生产Keychain/AES+真实SwiftData首次保存及fresh cipher/repository冷读真实通过。**61模块方法/0失败**，包含4项Auth/scope，约10.484秒。

3条UI全实际运行失败，已越过昵称保存，失败在安排表单找不到disabled Save或AI整理按钮。日志显示16次拖动均用App窗口x14（约0.03），键盘仍在，未把长Form滚到目标；最终诊断又读取不存在target.identifier，XCTest先抛snapshot错误遮住了完整AX tree。UI共724.235秒，测试操作1066.232秒，非20分钟取消；没有完成主要旅程，不能把61模块和签名成功等同M1 UI通过。

下一候选仅修可达性与受影响验证：测试手势定位实际CollectionView/Form或ScrollView，在容器内部x约0.85拖动，裁剪导航/键盘，逐次重算；disabled按钮与非交互组的可见性和可点击性分开，实际tap仍严格要求enabled+hittable。不存在的目标不读取属性，失败直接附整棵App AX tree。`arrangementHistory`、候选和cleanup组增加`.contain`，避免组identifier传到子控件覆盖其独立标识；已有日志的两个历史Disclosure按钮均被组标识覆盖，后续需实际运行核对，不能仅靠源码断言。

追加8个与本次真实Auth改动相关的既有运行方法：rotation恢复、503重试合并、receipt同chat重试、网络/登出围栏、首次本地读取中登出、离线恢复取消、drain前关闭权限与再次登录、冷验证重试。用方法级allowlist，不改旧测试文件/pins，不加skip或quarantine。该旧类共有35方法，3个以源码检查为主，其中一项仍要求旧聊天首屏；此次不把它们算新育儿入口验证，也不声称跑完整旧类。新增8项会真实执行临时SwiftData、UserDefaults、Keychain删除和通知/LiveActivity清理，仅在无后端配置的一次性Simulator、单并发中运行，不是全链纯mock/零系统作用。

本候选收敛为**69模块+7 UI**，新部分尚未SDK编译或执行。保留原3旅程，另外加入：planned→取消→同UUID/时间冷重开且不生成完成记录；独立观察→更正保留原文/更正时间→同UUID/goal冷读→明确删除→再次冷读；真实SwiftData注入提交失败/rollback→输入保留/同表单重试→冷读仅一个孩子；未知响应→仅按原cid/op/epoch及完整编码请求回查→可编辑候选且不自动应用/保存。后两项仅扩DEBUG合成transport/既有故障缝，不替换生产cipher或持久化。临时transport原文仅在内存，删除清除；不扩生产接口/服务/权限。记录来源组增加contain以保留来源与时间的独立AX标识；实际层级效果仍待CI。

仅调整整组测试预算至45分钟，不改15秒条件等待、16次滚动上限、实际点击enabled+hittable或业务断言。依据上轮UI724.235秒/3×7加非UI341.997秒粗估33.9分钟，再留约33%启动/新增Auth余量；这是7条旅程的串行预算，不把失败改为通过。实际耗时按新SHA日志复核。无skip/quarantine新增。M1未签收，M2暂停。

## c1de83f：69模块通过，保存失败恢复UI通过，表单可达性继续修复

[c1de83f6e3d466e63746929ba4cc086d5ed25f2c / CI40006576610](https://github.com/Yankj/mimi/actions/runs/40006576610) 已终态：changes、Edge SUCCESS，Edge913总数/911通过/0失败/2跳过，保留12个既有隔离文件；[iOS job120595974044](https://github.com/Yankj/mimi/actions/runs/40006576610/job/120595974044) FAILURE。Xcode签名build-for-testing和产物guard成功；**69模块/0失败**，分项为8既有Auth runtime + 4育儿Auth composition + 27 inline + 8 parser + 22 workspace，15.636秒（壁钟16.971秒）。生产Keychain/AES、真实SwiftData冷读、scope和账号围栏继续通过。

7条UI均实际执行，其中真实SwiftData提交故障→rollback→同表单输入保留重试→同store冷启唯一孩子**通过**（76.922秒）；其余6条失败在保存/原位整理/安排名称的表单节点可达性，未到其完整验收终点。失败前原话仍在，记录保存Button在AX树中明确存在，无持久化失败新证据。UI共1735.823秒，测试操作2039.628秒；非45分钟取消，不把69模块或其中1条UI等同M1主流程通过。

完整AX定位了输入面板的几何差异：Keyboard节点y611开始，但inputView/SystemInputAssistantView从y567开始；旧拖动起点约(349,591)，实落44px预测栏。dark前8次同样命中预测栏；第9次反向从Form上部拖动后键盘消失，余下向上搜索使Form停在0%。因此终态无键盘不否定前段遮挡，也不能据此判断按钮消失。这里修正了先前‘TextEditor吞掉全部拖动’的过早归因。

本次同时处理用户主动作可达性：安排和观察/完成记录的**唯一保存按钮**移入现有系统导航栏confirmationAction，沿用已经真实通过的昵称/目标保存模式；删除原Form底部重复位置。save()、操作ID/去重、所有valid/saving/model.busy/intake.busy/intakeCallID禁用条件保持，保存草稿后仍须独立确认安排。可见短文案配完整动作accessibilityLabel，保留保存中进度及A1 tint，不引入浮层或扩大到新功能。时间选择页不在此改动中。

测试保留69模块+7UI和原15秒等待/16次滚动上限；取真实输入面板顶沿裁剪，Form手势落在cell内侧padding（实测cell x20、TextEditor x40），并使用视口20%–80%避开safearea。空frame不作为方向锚点，已知下方虚拟化节点不再盲目半程反向；上方输入仍由既有input()回到页首。Disclosure按当前AX的Other容器定位实际Button点击。新增导航栏位置/键盘上方断言；dark冒烟改472字符合成长输入并明确检查键盘仍可见，不能把更长输入称已通过。下一SHA构建与7UI仍待真实运行。

M1尚未签收、M2暂停。仍无真机、真实模型、生产Auth/PG、系统通知、部署或持久交付的截图；不增加上传。

## 47e6d0e：保存可达、两条持久恢复UI通过，其余五条按AX证据修复

[47e6d0e7fc28aa522cdebb382ede3f3aaae99572 / CI40013451171](https://github.com/Yankj/mimi/actions/runs/40013451171) 已终态：changes、Edge SUCCESS；[iOS job120619457801](https://github.com/Yankj/mimi/actions/runs/40013451171/job/120619457801) FAILURE。签名build-for-testing及产物guard通过；**69模块/0失败**，6.510秒（壁钟6.860秒），包含8既有Auth runtime、4育儿Auth composition、27 inline、8 parser、22 workspace。Edge913总数/911通过/0失败/2跳过，保留12个既有隔离文件，68.392秒。

**7 UI实际运行：2通过、5失败**，1748.431秒；测试操作2257.958秒，非45分钟取消。通过项为planned安排取消→原UUID/时间/取消状态冷读→无完成记录（305.438秒，包含“本机安排不会发送提醒”的实际文案断言），以及真实SwiftData提交故障→rollback→输入保留同表单重试→冷读唯一孩子（80.532秒）。

原位成功旅程已完成许可、解析候选、显式采用、编辑、选择时间、保存待确认草稿；随后全文标题断言失败：XCTest在光标开头输入得到首位空格，Domain按既有规则裁剪后保存，实际标题与裁剪后的预期一致。独立观察也已由真实Store保存并显示正确正文/目标，但通用AX查询先取得同标识的leaf Image，误作目标文字。深色accessibility5实际输入472字符、保持键盘可见并通过固定保存位置/禁用断言，随后与准备失败旅程同样卡在放弃弹窗：系统输出两层同标识Button，单匹配查询有歧义。未知结果旅程已验证只显示原请求核对且没有新发送/重试按钮，但在点击核对前的原话保留检查停住：source仍存在而frame为零，旧helper只对不存在字段向上搜索，实际16次向下把Form滚到100%。因此本SHA没有后续原ID回查、完成/回顾和观察更正删除的整段UI通过证据。

下一候选仅按上述证据修复：安排/记录目标及完成状态Label合并其可访问性子节点，让辅助技术读取业务文字；Discard与邻接Delete采用精确query的firstMatch并严格等待exists/enabled/hittable，弹窗不走底层Form滚动；三处编辑文本的expected依既有Domain规则裁剪首尾空白，保存、重开、冷读仍全文精确比较，来源原文逐字保留；已知上方字段在缺失或零frame时向上查找，有正常frame仍按几何方向，移除额外3次预拖动，统一保持16次上限。未删除用例、放宽断言、增加等待或替换真实持久化；生产状态机、服务和权限未变。新SHA的69模块+7 UI仍待实际运行。

本机静态项目239源/4target、capabilities13、品牌兼容472和diff检查通过。敏感扫描无新增项，既有图片与NativeOAuth合成凭据两项待审不改规则；layout/frozen仍是此前独立治理范围的迁站描述及历史ReadoutPolicy hash错误。本次未导入#124。M1未签收、M2暂停；真机、真实模型/生产Auth/PG、多实例、通知和持久截图交付仍未验证，未部署或上传。

## 7a1a31f：六条UI（含主流程）通过，最后一条被整组预算截断

[7a1a31f0adb8989cd7076e1308e784e52e5bac73 / CI40019861647](https://github.com/Yankj/mimi/actions/runs/40019861647) 已终态：changes、Edge SUCCESS；[iOS job120641357588](https://github.com/Yankj/mimi/actions/runs/40019861647/job/120641357588) FAILURE。签名build-for-testing、产物guard和**69模块/0失败**通过，模块13.686秒（壁钟16.697秒）。Edge913总数/911通过/0失败/2跳过，保留12个既有隔离文件，94.596秒。

| 实际UI方法 | 终态 |
|---|---|
| dark / accessibility5 / 长输入 / 放弃无草稿 | PASS，295.641秒 |
| 独立观察新增 / 更正 / 原文与更正时间 / 原ID与goal冷读 / 删除再冷读 | PASS，350.772秒 |
| 原位AI许可 / 候选未自动应用 / 显式采用编辑 / 时间 / 待确认 / 确认 / 调整 / 完成 / 目标回顾 / 原UUID时间状态记录冷读 | PASS，696.413秒 |
| planned取消 / 同UUID时间状态冷读 / 无完成记录与无提醒文案 | PASS，266.988秒 |
| 准备失败 / 退出 / pending冷恢复禁发 / 明确清理 / 新整理 / 取消无安排 | PASS，360.708秒 |
| 真实SwiftData提交失败 / rollback / 输入保留 / 原表单重试 / 冷读唯一孩子 | PASS，57.273秒 |
| unknown原请求回查 / 候选 / 采用编辑 / 最后原话核对与取消 | 已启动，未到终态；被45分钟整组上限截断，不能计通过或略过 |

前6条执行时间合计2027.795秒。最后一条不是同处重复卡死：21:21:54显式点击原请求核对后，已得到严格解析的候选；随后验证候选未自动应用、原话保留、仍不可保存，21:24:12显式采用、21:24:36实际编辑标题，21:24:47在最后一次返回上方原话检查时拖动，21:24:48 Actions报告45分钟超时。无该方法的失败断言或结束事件，也没有完整7 UI聚合结果和xcodebuild正常结束结果。不能把6条通过、unknown已有局部证据或69模块通过写成整组通过。

下一候选不扩大测试范围或产品功能，仅减少重复AX读取并修正整组预算：每次reveal迭代只采一次app/nav/tab/input边界，传给候选选择、viewport和drag，下一次拖动后重采；toolbar与普通目标的中心判断、候选优先级/回退、raw frame归一化及手势不变。不采用isHittable快速放行，不跨输入/弹窗/冷启缓存；15秒条件等待、16次拖动及全部全文/身份/去重/冷读断言保留。原日志中成功旅程的tearDown也生成名为failure的截图，改为诚实的end-of-case诊断名称；截图不是方法成败依据，仍不上传。

45分钟预算原先由失败旅程估算，未覆盖这次实际完整成功路径。已观察到45分钟仍有明确末尾动作，加上结束导出及运行波动，整组上限改60分钟；不延长单次条件或静默重试，不增加macOS并发job、依赖、artifact上传、真实服务调用或跳过项。新SHA仍须完整重跑同一69模块+7 UI，不能借7a的6条绿色代替其结果。

M1尚未签收，M2未开始；设备与线上状态仍是未验证、后端未部署。独立治理#124未整合。

## 3a6eeeb：完整7条UI终态，余下独立观察的AX查询失败

[3a6eeebf19f6888ed542fc416bc856a4ff0ef52d / CI40027128695](https://github.com/Yankj/mimi/actions/runs/40027128695) 已终态：changes、Edge SUCCESS；[iOS job120666074653](https://github.com/Yankj/mimi/actions/runs/40027128695/job/120666074653) FAILURE。build-for-testing和签名产物guard通过；**69模块/0失败**，10.170秒（壁钟11.077秒）。Edge913总数/911通过/0失败/2跳过，保留12个既有隔离文件，97.549秒。

| 同一组实际UI方法 | 终态 |
|---|---|
| dark / accessibility5 / 长输入 / 放弃无草稿 | PASS，135.480秒 |
| 独立观察新增 / 更正 / 冷读 / 删除 | FAIL，188.100秒；打开表单后第一次record.text AX查询超时，未开始输入或保存 |
| 原位AI / 可编辑草稿 / 确认调整 / 完成回顾 / 原UUID时间状态记录冷读 | PASS，470.356秒 |
| planned取消 / 原UUID时间状态冷读 / 无完成记录与无提醒文案 | PASS，161.796秒 |
| 准备失败 / pending冷恢复 / 明确清理 / 新整理 / 取消 | PASS，268.643秒 |
| 真实SwiftData提交失败 / rollback / 保留输入重试 / 冷读唯一孩子 | PASS，55.129秒 |
| unknown只回查原请求 / 候选未应用 / 显式采用编辑 / 原话保留 / 取消 | PASS，348.261秒 |

UI **7项/1失败**，1627.764秒（壁钟1627.838秒）；22:12:13正常返回TEST EXECUTE FAILED，非整组60分钟上限。unknown终于取得完整终态，不能把该6项与7a的观察通过拼成当前SHA的7项通过。

观察失败发生于点击新增后，导航栏已出现；record.text的全类型Any.exists从89.10秒经两次框架重试到183.06秒报快照查询超时。未进入reveal的拖动、15秒条件等待、输入、保存或业务结果断言。现有日志没有AX树、线程栈或watchdog信息，不能断言App挂起、产品保存失败或测试框架是唯一原因。7a相同观察CRUD曾完整通过，本次completion模式的同一编辑器也通过，但这些不排除观察模式特有问题。

下一候选只收窄已知输入类型：原话/观察TextEditor按TextView、昵称/目标/安排标题按实际TextField查询，直接交给原reveal；不再先对整个AX树执行Any查询，也不凭暂时exists结果猜类型。失败时在end-of-case截图后打印完整合成AX树，便于若复现继续定点定位。15秒条件、16次滚动、60分钟整组预算、全部正文/来源/UUID/时间/状态/去重/冷读断言及真实Keychain/SwiftData保持。没有新增方法、跳过用例或重试整个方法；类型收窄的效果仍需新SHA实际运行。

M1尚未签收，M2未开始。设备和生产均未验证，后端未部署；未调用生产服务、上传截图或整合独立治理#124。

## 早期接续测试范围（截至d5f739e）

d5f739e及之前的CI定向脚本只选择 `catTests/ParentingWorkspaceTests`、`ParentingIntakeTests`、`ParentingInlineIntakeTests` 三类合成用例。使用已安装iPhone runtime创建自己的空白模拟器，结束只删除本次创建的设备；存在Local.xcconfig时拒绝执行，移除四个backend环境配置及继承fixture/connection/simulator-child注入，不安装依赖或下载runtime。测试使用临时文件和mock transport，无真实儿童数据、真实模型、生产Keychain或数据库。空Debug配置使项目Auth/后端启动被guard拦住；现有AppDelegate仍有系统APNs注册/BG任务注册，未测量全进程或系统网络次数，不声称全进程零网络。

`build-for-testing`只编译，定向XCTest步骤运行后才可报告其实际执行数量。新测试script和workflow的shell/源码检查不能代替SDK执行；截至d5f739e尚无原生UI验收；后续原生UI结果见上方固定SHA记录，真机、真实模型、PG多实例、系统通知或线上后端验收仍缺失。

远端Edge job沿现有Node22脚本，包含既有quarantine并安装既定公开依赖；没有本机offline-prelude网络屏障，不能把它改称“与本机70项相同的全部离线测试”。其结果按该job实际分母/失败另列；不据绿色Node结果推断数据库或原生通过。
