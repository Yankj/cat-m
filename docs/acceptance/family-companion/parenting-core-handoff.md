# 小咪育儿 M1 / M2a 版本交接 · 2026-10-24

按用户最新要求，本版收尾后暂停。周期、提醒及M3后续实现均未启动；不再以此前路线自动推进。本文是本版固定候选的接手回执，阶段路线仍见[育儿路线](../../design/family-companion/parenting-milestones.md)，逐次失败/修复保留在[23日](parenting-ci-2026-10-23.md)及[24日](parenting-ci-2026-10-24.md)记录。

## 候选、远端与工作区

- 产品代码候选：`ba1234a498d440f823505e3d7d839a29491c85b1`；[草稿PR #123](https://github.com/Yankj/mimi/pull/123)，head分支`feat/parenting-core`，base main `4ec8118b796f7c983ae4436268441c3c9d3d33db`。品牌PR #122及`ba560b9686e5b2dd8642dd75d351e72418659ecb`已在基线，内部安装/存储/wire身份保留。
- 本交接资料的提交位于上述候选之后；产品源字节保持不变。最终远端HEAD由[PR commits](https://github.com/Yankj/mimi/pull/123/commits)与父任务最终回执确认，并可用下方命令核对。区分已验产品SHA和仅交接资料提交，不能把新文档SHA冒充已运行测试的旧SHA。
- 本机隔离工作树`/workspace/mimi-parenting`；原`/workspace/mimi`、`/workspace/cat-m`及其他分支未覆盖。所有产品和交接改动提交后普通推送到同一分支；交接时的未提交状态由最终回执核对。没有force push、merge、auto-merge、部署、发版、真实手机安装、Library或附件上传。
- 独立治理PR #124不在本分支整合：不cherry-pick其历史恢复、CI策略、安全allowlist或扫描复核记录。存量PR关闭和网站迁站由其他任务负责，不据第三方转述在本任务执行。

```sh
git status --short --branch
git rev-parse HEAD
git ls-remote --heads origin feat/parenting-core main
git diff ba1234a498d440f823505e3d7d839a29491c85b1..HEAD -- apps/ios-conversation/Sources apps/ios-conversation/Resources apps/ios-conversation/cat.xcodeproj apps/ios-conversation/Scripts services/edge .github/workflows
```

最后一条在仅交接提交上应为空；生成版本号/产物不据此称二进制字节相同。不要覆盖其他人的worktree或强推。

本分支的`master-plan.md`仍含早期“M1/54未运行/待推送”快照，独立治理PR #124未整合且该入口由其owner维护。本交接与日期CI记录提供本次固定SHA证据；主计划索引同步列为接手协调项，不复制其他分支治理提交。

## 本版交付的行为

默认入口是今天/孩子成长/记录，聊天为辅助。家长交代一件事→明确发送与模型许可→原位等待/错误/取消/重试→严格候选→显式采用并编辑→保存待确认→确认安排→今天调整/取消/完成→关联目标和来源记录冷读。真实加密SwiftData账本；没有预置成功家庭、静态假功能或纯内存demo。普通未保存表单放弃后丢弃；AI unknown通过加密恢复引用只核对原请求，不自动新发。

M2a从已选安排说本次改动，仅发送原名称/原时间/本次原话/解释时区，不附孩子档案、目标内容或其他安排。候选只填新dueAt；原ID、名称、孩子、目标、状态及最初来源保留。完整差异、采用和确认保存分开；冻结快照/revision拒绝旧表单、旧回复、跨账号及迟到结果。同分钟planned事项提示“可能同刻”并要求精确核对；没有时长或照护者模型，不声称区间冲突检测。加密历史记录before/after、原话和时间，撤销可冷恢复；后续修改/完成/取消/删除使旧撤销失效，防ABA，不回滚整份账本或复活完成事实。

时间核对有界：完整带offset ISO，或明确年月日、今天/明天/后天配明确日段/24小时钟点；残缺钟点、歧义、证据不符、无效日期和DST gap/fold转澄清。已覆盖Lord Howe半小时回拨及邻接/显式offset正例；不是通用自然语言排程器。持续时长、相对推迟分钟、任意星期指代、周期语义及自然语言取消不属于本片。

目标由家长定义，安排是计划，观察/完成是家长记录的事实；有来源、时间、更正和删除。不给儿童打KPI，不凭空生成教育/医疗建议。延续暖橙奶白A1与温馨图标；深色CTA使用既有可读语义，确认/保存放在导航栏，添加目标label拥有44点实际触控范围。

## 固定SHA验证与四层边界

| 层 | 证据 |
|---|---|
| M1代码与自动测试 | `c37d82e8424fcaf323ab3cd96ea6bdd90084cbd4`的[CI40032353790](https://github.com/Yankj/mimi/actions/runs/40032353790)终态SUCCESS：编译/签名、69模块/0、7 UI/0；Edge913总/911pass/0fail/2skip，另12隔离文件。不能替代M2a自己的结果。 |
| M2a本版自动测试 | `ba1234a498d440f823505e3d7d839a29491c85b1`的[CI40046503653](https://github.com/Yankj/mimi/actions/runs/40046503653)：终态SUCCESS；NoBug、项目成员、Xcode build-for-testing与独立签名检查通过，99模块/0失败，10.613秒（壁钟11.623）；8 UI/0失败，1617.167秒（壁钟1617.187），TEST EXECUTE SUCCEEDED。iOS job120729392844；Edge job120729392912为913总/911pass/0fail/2skip，67.221秒，另12既有隔离文件。 |
| 设备/视觉 | Simulator实际Home/controller、生产Keychain-AES、SwiftData、终止重启；身份与模型transport为DEBUG合成。真实NativeAuth收据/同chat恢复另配mock Auth/scope端口测试。截图仅runner xcresult，未取回、上传或视觉审阅；没有真实手机、真实模型或真实家庭体验验收。 |
| 线上 | 专用后端未部署；没有生产Auth/PG/RLS、多实例、APNs或通知送达验证。现网旧端点会明确不支持，不回退聊天冒充成功。 |

99模块包括Auth8、Account4、ArrangementEdit14、Inline27、Intake8、Reschedule16、Workspace22；8 UI为原7条完整主流程/失败恢复加1条M2a改期/冷读/撤销。实际每条结果以日期记录/同SHA日志为准，不跨SHA拼接。前序118的99模块及7 UI通过、新旅程在采用前的导航失败已记录；修复只调整新旅程顺序，保留全部断言及15秒条件/16次滚动/60分钟整组预算，没有删测试或整方法重试。

早期70项Node及54项未运行XCTest是历史记录。54已在974dbb1实际运行通过并继续演进为69/99，不能继续报未运行；旧23脚本中4静态、9纯JS、10真实产品模块+mock，不等于原生测试。后续本机handler/ChatService重点65/65、扩大120/120含HTTP20/20为真实JS模块加合成Auth/provider/TestRepository，两组重叠不累加，也不证明真实PG。

## 准确复验入口

使用现有SDK/依赖和合成家庭，不复制生产配置、配置凭证、调用真实Auth/模型/数据库或新装依赖。以下命令从仓库根执行，除已注明cd。

```sh
python3 scripts/check-capabilities.py
python3 scripts/check-brand-migration.py
python3 scripts/check-repository-layout.py
python3 scripts/check-repository.py
python3 scripts/scan-repository.py --json-output build/parenting-core/handoff-sensitivity.json
git diff --check
```

当前静态capabilities13、品牌兼容472通过。layout仍因外迁网站说明被当成本机路径失败，frozen仍因历史ReadoutPolicy pin失败，扫描保留source-logo.jpg及NativeOAuthTests.swift:106两项基线待审/132精确旧复核；规则未放宽。它们由独立治理分支处理，不能在本版顺手导入。Linux缺Swift/Xcode/plutil，L10前4段1430 lookups/360育儿声明/2111双语及插值通过，最终plist阶段未执行；旧check-source/设计检查的历史基线问题见审查，不冒充本版新SDK失败。

Mac使用既有Xcode/iOS Simulator runtime，项目入口`apps/ios-conversation/cat.xcodeproj`。先确认没有`Configuration/Local.xcconfig`；script存在时会拒绝运行。CI实际先执行：

```sh
cd apps/ios-conversation
./Scripts/test-nobug-p0.sh
python3 Scripts/validate-project.py
xcodebuild -project cat.xcodeproj -scheme cat -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$PWD/../../build/parenting-core/SimulatorSigningDerivedData" build-for-testing CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= "CODE_SIGN_ENTITLEMENTS=$PWD/Configuration/SimulatorFixtureAcceptance.entitlements"
bash Scripts/test-parenting-core-simulator.sh
```

脚本核对主App/Simulated xcent/独立Keychain group及ad-hoc签名，再创建自己的新模拟器；只删除本次创建的设备。清除后端配置和继承fixture环境，不下载runtime、不做真机签名或安装；选择99模块与8 UI。`Scripts/check-localization.py`可在Mac另跑，但不据Linux前半通过宣称完整命令通过。

HTTP离线重点复验的现有命令（不要用它声称原生或真实PG通过）：

```sh
node --no-warnings --import ./qa/family-cloud-verification/offline/offline-prelude.mjs --import ./services/edge/test/support/node-strip-loader.mjs --test services/edge/test/parenting-intake-http.test.mjs
```

CI Edge实际运行`cd services/edge && ./scripts/ci-node-tests.sh`；它可能安装既定公开jose/postgres依赖，使用loader并保留12隔离文件和2真实PG跳过，并非与本机网络屏障相同的“全部离线”命令。本交接不授权本机装依赖或生产验证。

## 文件入口

以下原生路径相对`apps/ios-conversation/`。

| 文件 | 接手位置 |
|---|---|
| [Sources/App/catApp.swift](../../../apps/ios-conversation/Sources/App/catApp.swift) / [Sources/App/NativeAuthApplicationModel.swift](../../../apps/ios-conversation/Sources/App/NativeAuthApplicationModel.swift) / [Sources/App/LocalConversationReceipt.swift](../../../apps/ios-conversation/Sources/App/LocalConversationReceipt.swift) | 实际入口、可信账号代次重建、canonical scope admission；旧Store写屏障不能放宽 |
| [Sources/Features/Parenting/ParentingHomeView.swift](../../../apps/ios-conversation/Sources/Features/Parenting/ParentingHomeView.swift) | 今天/成长/记录、表单原位整理与差异确认、撤销菜单、来源历史、UI标识 |
| [Sources/Domain/ParentingWorkspace.swift](../../../apps/ios-conversation/Sources/Domain/ParentingWorkspace.swift) / [Sources/Domain/ParentingArrangementEdit.swift](../../../apps/ios-conversation/Sources/Domain/ParentingArrangementEdit.swift) | 计划/事实模型、原子命令、快照/revision、冲突精确集合、持久ABA失效 |
| [Sources/Domain/ParentingRescheduleTime.swift](../../../apps/ios-conversation/Sources/Domain/ParentingRescheduleTime.swift) | 有界日期/钟点证据、真实时区偏移唯一性，禁止静默修正DST |
| [Sources/Persistence/ParentingWorkspaceStore.swift](../../../apps/ios-conversation/Sources/Persistence/ParentingWorkspaceStore.swift) / [Sources/Features/Parenting/ParentingWorkspaceModel.swift](../../../apps/ios-conversation/Sources/Features/Parenting/ParentingWorkspaceModel.swift) | 账号分区AES、真实持久CAS/幂等、保存成功才发布、固定epoch |
| [Sources/Domain/ParentingIntakeDraft.swift](../../../apps/ios-conversation/Sources/Domain/ParentingIntakeDraft.swift) / [Sources/Domain/ParentingInlineIntake.swift](../../../apps/ios-conversation/Sources/Domain/ParentingInlineIntake.swift) / [Sources/Features/Parenting/ParentingInlineIntakeModel.swift](../../../apps/ios-conversation/Sources/Features/Parenting/ParentingInlineIntakeModel.swift) | v1严格解码、编辑target绑定、许可/未知/取消/恢复/清理 |
| [Sources/Persistence/ParentingIntakePersistence.swift](../../../apps/ios-conversation/Sources/Persistence/ParentingIntakePersistence.swift) / [Sources/Providers/NativeParentingIntakeComposition.swift](../../../apps/ios-conversation/Sources/Providers/NativeParentingIntakeComposition.swift) / [Sources/Providers/NativeChatHTTPBackend.swift](../../../apps/ios-conversation/Sources/Providers/NativeChatHTTPBackend.swift) | 隔离加密恢复、现有transport适配、专用路径和身份回执 |
| [Sources/App/ParentingUITestFixture.swift](../../../apps/ios-conversation/Sources/App/ParentingUITestFixture.swift) / [Tests/ParentingWorkspaceUITests.swift](../../../apps/ios-conversation/Tests/ParentingWorkspaceUITests.swift) | 合成边界与真实UI旅程；不注入成功账本/假cipher |
| [Tests/ParentingArrangementEditTests.swift](../../../apps/ios-conversation/Tests/ParentingArrangementEditTests.swift) / [Tests/ParentingRescheduleIntakeTests.swift](../../../apps/ios-conversation/Tests/ParentingRescheduleIntakeTests.swift) / [Tests/ParentingAccountLifecycleTests.swift](../../../apps/ios-conversation/Tests/ParentingAccountLifecycleTests.swift)及原三类育儿测试 | 真实领域/Store/controller/parser/lifecycle加mock边界 |
| [Scripts/test-parenting-core-simulator.sh](../../../apps/ios-conversation/Scripts/test-parenting-core-simulator.sh) / [cat.xcodeproj/project.pbxproj](../../../apps/ios-conversation/cat.xcodeproj/project.pbxproj) / [.github/workflows/ci.yml](../../../.github/workflows/ci.yml)（根目录） | 正式target、99+8选择、签名和环境隔离 |

后台入口仍为`services/edge/supabase/functions/_shared/api.mjs`、`services/edge/supabase/functions/_shared/core/src/chat-service.mjs`及同目录`parenting-intake*.mjs`，HTTP回归在`services/edge/test/parenting-intake-http.test.mjs`。M2a复用严格v1七键与受限purpose，没有扩大后端执行/工具/记忆权限。

## 数据与删除

账本和operation回执在原账号/scope的同一加密preference；不新增云端家庭影子账本。孩子/目标/安排/记录及调整历史由用户显式维护。临时journal/recovery加密最多24小时逻辑可恢复；cleanup仅保留身份/ID/pending无原文，失败不报删除成功并阻止新整理。服务器持久层仅标识/哈希/脱敏元数据，原话/答案进程缓存最多可读15分钟；幂等墓碑阻止delete-before-create和迟到finalizer复活。取消不承诺provider同步停止，第三方留存及后台物理清除时效未验证。临时整理删除不会自动抹去用户另行保存的安排来源，已保存记录需在对应入口删除。

## 恢复与接手步骤

1. 核对远端HEAD/草稿状态、main基线及工作区clean；先读本版日期证据与[交互合同](../../design/family-companion/parenting-adjustments.md)，不要从旧conversation-first文档恢复默认聊天入口。
2. 在新隔离worktree检出产品候选SHA；不覆盖并行目录。运行上述只读/离线检查，按同SHA核对CI证据；Linux不能运行SDK时保留NOT RUN，不用字符串/复制算法测试代替。
3. 恢复包仅存在执行环境`/workspace/mimi-parenting/build/parenting-core/`，不是手机可下载链接，也没有上传Library/文件服务。产品候选补丁`checkpoint-ba1234a4.patch`为974132字节，SHA256 `41fca9c714d4e8be34182f7daeb26ef1db3ba21a0c6481303d59c05ea13b8845`；对应json含51个路径SHA256。基线archive上apply-check/apply后51文件逐字节匹配。`m2a-handoff-current.json`及父任务最终回执记录资料提交的最终HEAD/补丁哈希/CI状态；若与旧tar包冲突，以精确SHA清单为准。
4. 只能在干净的main基线副本上`git apply --check`/`git apply`该补丁；不要对已经包含候选的分支再应用。GitHub同分支提交可正常fetch作恢复来源；不需导入其他治理分支。
5. 若要真机、真实模型、后端部署、PG/RLS、多人同步或系统通知送达验证，先明确取得该操作的授权和所需环境；本交接没有授予这些权限。现有草稿不合并、不部署、不发版。

## 后续backlog与暂停点

- **当前暂停**：M2a收尾候选及资料交接完成后停止；M2a代码与合成原生主流程门已关闭，完整M2及设备/线上验收未关闭；只保留下面待办，不自动开始下一片。
- M2b每周有限周期、稳定实例/单次例外、本次及以后、整组撤销：只有只读方案，未实现/未冻结。ignored的`m2b-next-contract-DRAFT.md`仅草案，不能当产品合同或完成证据。
- M2c按实例本机提醒、明确权限、desired generation/库存核对、晚到add与取消/完成/删除一致性、时区及账号清理：未实现。当前本机安排仍明确不会发提醒；不伪造成功。
- M3基于实际来源记录的阶段回顾、M4可纠正删除的长期家庭记忆、M5家庭同步分工/可靠主动通知、M6真实家庭试用后扩展家庭/自我管理：均未启动。不能把当前手动事实账本称为长期主动管理终局。
- 真实手机/模型/生产/视觉验收、部署后数据层验证及原有治理基线仍单列缺口；没有招募真实儿童数据、安装服务或扩大凭证权限。
- 子代理请求`gpt-6.1-sol / ultra`为用户要求的最高支持档配置意图；实际effective runtime与root实际模型无法独立核实。
