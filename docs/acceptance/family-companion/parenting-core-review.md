# 育儿核心独立审查与测试清单

2026-10-23；独立执行者：`acceptance_review`。这是本次本地切片的日期证据，实时交付状态仍由主计划维护。

**原生产品验收尚未完成。** 已新增调用真实产品接口的 54 个 XCTest 方法（账本 21、回复合同 8、原位 controller / 密封恢复与清理 25），并实跑支持的 Linux 离线检查；当前环境没有 Swift、Xcode、iOS SDK 或模拟器，因此 54 项均为 **NOT RUN**，不能把源码审查、测试数量或工程引用当作运行通过。

**原位 AI 整理已落到源码，原生交互仍未运行验收。** 首页表单调用独立 controller / 私有会话 / 密封 journal 与专用受限 HTTP 模式，旧聊天接续文件已删除。实际等待、许可、失败、原身份查询/重试、取消、迟到结果、恢复与清理均需在现有 Xcode 环境执行；当前不能称核心交互 complete。

基线为 `4ec8118b796f7c983ae4436268441c3c9d3d33db`，分支 `feat/parenting-core`，审查时对象含本地未提交修改；最终本地 commit / 补丁包身份由交接 manifest 记录。请求的模型/推理配置为 `gpt-6.1-sol / ultra`；本审查没有可独立回读的 effective 配置，不补写为已验证。环境实测 Node `v24.19.0`、Python `3.12.14`；`swift`、`xcodebuild`、`deno`、`psql`、`sqlite3` CLI 不可用。

## 已交付测试

文件：[ParentingWorkspaceTests.swift](../../../apps/ios-conversation/Tests/ParentingWorkspaceTests.swift)。所有昵称、身份、原话和时间均为合成数据；时间固定为 UTC。测试直接调用 `ParentingWorkspace.applying`、`ParentingWorkspaceStore`、`Repository`、`FilePersistence`、`ParentingWorkspaceModel`、`ParentingIntakeRequest.parse`、`ParentingInlineIntakeModel`、`ConversationSessionService`、`ParentingIntakeConversationBackend` 与真实 `ParentingIntakePersistence`，没有另写领域或 controller 实现。

持久化测试通过临时磁盘文件重新创建 `Repository`，避免用同一内存对象冒充冷启动。注入的测试封套故意使用简易掩码、摘要和随机 nonce，仅用于验证实际读写边界、损坏拒绝及随机密文重试；**它不证明生产 AES-GCM 或 Keychain 行为**，也不访问生产 Keychain。

| 类 / XCTest 方法 | 要验证的行为 | 执行状态 |
|---|---|---|
| Workspace / `testEmptyLoadHasNoSeededChildOrImplicitWrite` | 空态无预置孩子、不隐式写盘 | NOT RUN |
| Workspace / `testDraftConfirmEditCompleteCreatesIndependentRecordAndColdReopens` | 持久草稿→确认→修改→完成→独立记录→冷盘重开 | NOT RUN |
| Workspace / `testOperationRetryAfterLaterEditReturnsLatestWorkspaceWithoutDuplicate` | 同命令重试返回最新状态，不回滚后续修改 | NOT RUN |
| Workspace / `testSameOperationWithDifferentCommandIsRejectedWithoutMutation` | 同操作 ID 改内容拒绝，内存及磁盘不变 | NOT RUN |
| Workspace / `testConcurrentSameOperationWithDistinctSealedBytesHasOneDurableResult` | 两个 store、随机封套的同命令并发不重复落盘 | NOT RUN |
| Workspace / `testSaveFailureDoesNotChangeMemoryOrDiskAndSameOperationCanRetry` | 写盘失败保留原状态；原操作可重试 | NOT RUN |
| Workspace / `testUnconfirmedAndCancelledDraftCannotBecomeCompletedOrRevive` | 未确认不能完成；取消后不能完成或重新确认 | NOT RUN |
| Workspace / `testRepeatedCompletionCreatesOnlyOneRecordAndBlankNoteUsesTitle` | 重复完成只有一条记录；空补充说明回落标题 | NOT RUN |
| Workspace / `testDeletingGoalClearsReferencesAndKeepsArrangementAndObservation` | 删目标解除关联，保留安排和观察 | NOT RUN |
| Workspace / `testDeletingChildRemovesOnlyThatChildsReferencesAndSurvivesReopen` | 删孩子仅级联其对象，保留另一合成孩子 | NOT RUN |
| Workspace / `testDeletingArrangementPreservesIndependentEditableCompletionRecord` | 删安排保留完成记录；记录可更正、删除 | NOT RUN |
| Workspace / `testStaleRevisionAndWrongChildGoalRejectWithoutChangingSavedDraft` | 旧 revision、无效孩子/目标关联拒绝 | NOT RUN |
| Workspace / `testSuggestionsChoicePersistsWithoutChangingExistingArrangement` | 回顾提示选择可持久化，不修改已有安排 | NOT RUN |
| Workspace / `testOldEpochCannotReadOrWriteAfterSameSubjectSignsInAgain` | 同账号重新登录后，旧 epoch 不能读写 | NOT RUN |
| Workspace / `testEpochChangeDuringSealPreventsRepositoryCommit` | 受理后、持久化前切 epoch，禁止提交 | NOT RUN |
| Workspace / `testTwoSubjectPartitionsInSameRepositoryNeverReadEachOthersLedger` | 同一 Repository 中两个身份分区隔离、可冷读 | NOT RUN |
| Workspace / `testSubjectAndEpochMismatchCannotCreateLedger` | 缺身份/身份与 epoch 不符不能建账本 | NOT RUN |
| Workspace / `testCorruptCiphertextIsNotTreatedAsEmptyAndCannotBeOverwritten` | 密文损坏拒绝读写，保留原文件 | NOT RUN |
| Workspace / `testUnsupportedSavedEnvelopeSchemaIsNotTreatedAsEmpty` | 不支持的封套版本不能当空账本覆盖 | NOT RUN |
| Workspace / `testInvalidDecodedWorkspaceReferencesAreRejectedBeforeMutation` | 解码后的无效关联由真实领域校验拒绝 | NOT RUN |
| Workspace / `testModelPublishesOnlyDurableSuccessAndKeepsPriorWorkspaceOnFailure` | 保存失败不发布成功投影，保留错误与旧数据 | NOT RUN |
| Intake / `testCompletedReplyKeepsSelectedIdentityAndUnknownDateWithoutGuessing` | 主体沿用本机选择，缺日期保持未知 | NOT RUN |
| Intake / `testExplicitDateWithLiteralSourceEvidenceCanBecomeEditableCandidate` | 完整回复与原文时间依据形成可编辑候选 | NOT RUN |
| Intake / `testKnownTurnsOtherTopicsAndMismatchedOperationsAreNotImported` | 旧 turn、错话题、错操作不导入 | NOT RUN |
| Intake / `testStreamingFailedUnknownAndIncompleteRepliesCannotBecomeDrafts` | 流中、失败、未知、残缺及工具回复不导入 | NOT RUN |
| Intake / `testChangedAccountConversationAndAmbiguousMatchesAreRejected` | 账号/epoch/对话/分区变化、多匹配拒绝 | NOT RUN |
| Intake / `testNonceExtraIdentityDuplicateKeysAndMalformedJSONAreRejected` | nonce、额外身份键、布尔版本、重复键、非纯 JSON 拒绝 | NOT RUN |
| Intake / `testDatesWithoutLiteralDateAndClockEvidenceAreRejected` | 无原话片段或缺日期/钟点不能补时间 | NOT RUN |
| Intake / `testInterveningUserOrToolMessageCannotBeReadAsThisIntakeAnswer` | 介入的新用户/工具内容不能冒充本次回复 | NOT RUN |

## 实跑检查

在现有网络屏障之后加载 Node strip loader，避免依赖安装及意外网络传输。`Deno.env` 被测试屏障置空；本组使用合成 store/token/模型边界，不验证真实鉴权或数据库。

```sh
node --no-warnings \
  --import ./qa/family-cloud-verification/offline/offline-prelude.mjs \
  --import ./services/edge/test/support/node-strip-loader.mjs \
  --test services/edge/test/capabilities.test.mjs \
         services/edge/test/family-contract.test.mjs \
         services/edge/test/family-flag-gate.test.mjs
```

| 检查 | 本轮结果 | 范围 / 限制 |
|---|---|---|
| 上述 Node 命令 | PASS，exit 0，23/23；0 fail、0 skip | 能力/品牌 12、家庭合同 4、功能开关 7；镜像更新后已复跑。不是新 Swift 功能运行 |
| `python3 scripts/check-capabilities.py` | PASS，exit 0，13 项 | 能力清单与镜像、锚点静态一致 |
| `python3 scripts/check-brand-migration.py` | PASS，exit 0，472 项 | 安装、存储、协议身份源码约束；不证明升级/重登录数据恢复 |
| `python3 scripts/check-deployed-source.py` | PASS，exit 0 | 两套快照 50/43 文件、14 处差异保全；无部署 |
| `python3 scripts/check-agent-foundation-plan.py` | PASS | 12 requirements / 21 criteria / 9 acyclic slices；规划完整性 |
| `python3 scripts/check-final-product-plan.py` | PASS | 18 functional / 12 UX / 3 scenario mappings；规划完整性 |
| `python3 scripts/check-conversation-ui-plan.py` | PASS | 10 cases / 6 domain cards；规划完整性 |
| `python3 scripts/check-agent-foundation-goals.py` | FAIL | 旧 `design/catpaw-restart-review-and-plan-2026-10-13.md` 与 Goal 输入 pin 不符；当前文件 SHA 与基线 HEAD 相同，本轮未改 |
| `git diff --check` | PASS，exit 0 | 空白与补丁格式检查 |
| `zsh apps/ios-conversation/Scripts/check-source.sh` | FAIL，exit 1（root 实跑） | 先停在既有 Typography：StreamProgressVisuals:278、catLaunchStatic:33/42；未进入 Swift SDK typecheck，不能称 Swift 失败或通过 |
| native design / typography 检查 | FAIL（root 实跑） | 既有 5 / 3 处基线命中，无 Parenting 命中；不签收视觉质量 |
| 育儿文件 Xcode Sources membership 独立读取 | PASS，静态 | 育儿领域/持久化/controller/UI/composition 源及测试均在正式 targets；以最终全工程 238 source 检查为准 |
| `python3 build/parenting-core/local-plist-validation.py apps/ios-conversation/Scripts/validate-project.py` | PASS，exit 0 | 238 App source memberships、4 targets、scheme、启动资产、版本 1.2.0/build 702 dirty；使用 ignored Python OpenStep helper 替代缺失 `plutil`，不代表 SDK 编译 |
| `python3 scripts/check-repository-layout.py` | FAIL，exit 1 | 已知基线：清单将外迁官网说明当作本地路径 |
| `python3 scripts/check-repository.py` | FAIL，exit 1 | 已知基线：冻结 `apps/ios/Sources/Domain/ReadoutPolicy.swift` 哈希不符 |
| `python3 scripts/scan-repository.py` | FAIL，exit 1 | 已知基线：`docs/brand/png/source-logo.jpg` unexpected_binary；`NativeOAuthTests.swift:106` secret_assignment_review；未新增命中 |
| `python3 apps/ios-conversation/Scripts/check-localization.py` | 整体 FAIL，exit 1；原生工具缺失 | 最终前半 PASS：1428 lookup、308 育儿 UI/enum/error key、3 个精确协议 source 排除、自检、2075 双语及占位符；随后缺 `plutil`。原位 UI 与资源冻结后已独立复跑；此前中间缺资源失败在资源同步后消除 |
| `python3 build/parenting-core/local-plist-validation.py apps/ios-conversation/Scripts/check-localization.py` | 整体 FAIL，exit 1 | 同一前半 PASS；Python 替代 `plutil` 后停在第 137 行 permission-key exact-set 旧断言。品牌改名已在 InfoPlist.strings 加显示品牌键；不是新的育儿缺资源 |

治理三个失败与 [mimi 身份修复记录](../mimi-identity-2026-10-23.md)中的基线一致，未在本切片扩修历史 App、官网或扫描豁免。root 在原位源码冻结后实跑扫描为 1925 个候选、54,133,077 字节，仅上述两项旧命中；该计数早于最终审查文档收口，精确交付范围见交接 manifest。本审查此前独立扫描同为这两项命中。上述命令没有运行网站 CI、外部网站仓库、Deno、生产服务或依赖安装。

最终受影响回归由 root 实跑，本审查独立读取日志 `build/parenting-core/inline-node-regression.log`：**9 files / 70 tests，70 PASS、0 fail、0 skip，exit0；duration 7150.008353ms**，其中包含旧23与新增13（非额外叠加）。后端 owner 另有 `build/parenting-core/parenting-intake-http-final.log` 的13/13运行记录。使用同一网络屏障/strip loader：

```sh
node --no-warnings \
  --import ./qa/family-cloud-verification/offline/offline-prelude.mjs \
  --import ./services/edge/test/support/node-strip-loader.mjs \
  --test services/edge/test/capabilities.test.mjs \
         services/edge/test/family-contract.test.mjs \
         services/edge/test/family-flag-gate.test.mjs \
         services/edge/test/parenting-intake-http.test.mjs \
         services/edge/test/turn-cancel.test.mjs \
         services/edge/test/v11-account-consent-r3.test.mjs \
         services/edge/test/chat-runtime-lease.test.mjs \
         services/edge/test/chat-stream-budget.test.mjs \
         services/edge/test/conversation-memory-http.test.mjs
```

这是 JS 路由/服务变更的受影响回归；不执行新增 Swift XCTest，不证明 NativeHTTP 已真实连接或后端已部署。

本地化后半还有旧品牌契约未更新：permission 表的精确键集合、`Localizable.strings` 的旧 cat 键和 `FixtureProvider.swift` 的旧 hash。独立实际命令只执行到第 137 行；后两项是源码/owner 补充审阅，不冒充已逐项运行失败。它们应在 Mac 接续时保留并准确处置，不能因育儿 key 扫描通过而称整个 localization 命令通过。

## 既有 23 个 Node 用例的证据分类

以下是对已经运行的同一组 23 项的逐项源码审计，**没有新增或重复运行 23 项**。其中 4 项主要检查静态资源/JSON/文案；9 项调用实际 JS 组件函数；10 项运行实际 JS 模块或 HTTP/runtime 组合并注入合成边界。没有任何一项执行新 Swift 育儿首页、账本、controller 或原位 AI 交互。

未发现把产品算法另抄一份后测试自身的情况。测试中的期望字面值是断言 oracle；`shippedSection` / `gatedSection` 仅切分输出。部分断言仍是同源自洽，下面逐项标出。以下代码路径均相对仓库；行号对应此次审计源码，不外推到未来修改。

### capabilities：12 项

`C`＝`services/edge/supabase/functions/_shared/capabilities.mjs`，`T`＝同目录 `core/src/tools.mjs`。断言文件为 `services/edge/test/capabilities.test.mjs`。

| ID / test 原名 | 断言行 | 证据类型、实际被测入口与限制 |
|---|---:|---|
| C01 `display identity agrees with native app/widget names and localized proactive labels; internal links stay stable` | 16–30 | **静态资源/JSON**：读 canonical manifest、3 个 Info.plist、UIStrings；检查身份/scheme 字符串，不执行 Swift、原生显示或跳转 |
| C02 `chat base prompts keep mimi identity with public sources on/off, including image turns without capability injection` | 35–39 | **实际组件**：`T.chatPromptFor` / `chatBasePromptFor`（74–82）、`C.capabilityPromptFor`（206）；测试自行拼接 base+capability，验证组件返回值，不经过真实聊天/图片 dispatch |
| C03 `proactive reminder request uses mimi / 小咪 while preserving internal request identity` | 48–51 | **实际模块＋mock fetch**：`proactive/model.mjs:createReminderModel().reminder`（9–23）构造请求并取合成响应；不验证真实模型、调度、通知送达 |
| C04 `proactive decision request uses mimi / 小咪 while preserving internal request identity` | 58–61 | **实际模块＋mock fetch**：`proactive/decision-model.mjs:createDecisionModel().decide`（30–58）；固定 getter 与响应，检查提示词/header/JSON取值，不验证决策质量或推送 |
| C05 `generated module mirrors the canonical manifest (run scripts/check-capabilities.py --write after editing it)` | 65 | **静态 JSON 一致性**：`C.catCapabilities` 与磁盘 manifest 相同；不证明清单宣称能力可用 |
| C06 `manifest shape: unique ids, shipped/planned only, planned entries have no UI entry` | 68–70 | **静态结构/导出值**：manifest 字段与 `C.CAPABILITY_LINK_TARGETS`（177）的 5 个目标；不验证真实 UI anchor 或 handler |
| C07 `prompt: identity, every shipped capability, planned features stated honestly, only manifest links` | 73–79 | **实际组件**：`C.renderCapabilityPrompt`（192–198）与 `isAllowedCapabilityLink`（201）；检查输出文案/长度/链接。第79行 renderer 与同源常量相等仅为自洽，不证明模型遵守提示 |
| C08 `link allowlist and sanitizer` | 82–84 | **实际组件**：`C.isAllowedCapabilityLink`、`sanitizeCapabilityLinks`（201–203）；覆盖给定 URL 与 Markdown 清理，不证明 App 跳转或全输入安全性 |
| C09 `turn selection: revision/explain and image turns keep their own contracts` | 88–89 | **实际组件**：`C.capabilityPromptFor`；给定 revision/image 标志返回空串，普通 turn 返回提示。没有真实 revision/image pipeline，也没有独立 explain 对象调用 |
| C10 `turn-gated capabilities: web links only with publicSourcesEnabled, calendar only when calendar_create is offered` | 95、97–109 | **实际组件**：`C.unavailableCapabilities`（185–189）、`capabilityPromptFor` / renderer；检查传入 flag/tool 的文案矩阵，不证明运行时权限来源、网页读取或日历执行 |
| C11 `manifest wording: no hardcoded quiet hours; memory depends on the memory toggle and consent` | 113–115 | **静态文案**：manifest / `C.CAPABILITY_PROMPT` 不写固定静默时段并提及设置/同意；不证明静默时段、记忆开关或 consent 被执行 |
| C12 `chat turn system prompt carries consistent mimi / 小咪 identity to the provider` | 125–128 | **实际 API/runtime＋合成边界**：`test/fixtures/memory-http-fixture.mjs:11–19` → `api.mjs:createCloudRuntime` → `core/src/chat-service.mjs:executeHeld`（267，284组装、303调用provider）。断言提示词确实送到注入provider；Auth/sourceChecker/TestRepository/provider均为fixture。第128行预期子串来自同一 `capabilityPromptFor`，另有独立身份字面断言；不证明真实Auth/PG/模型/iOS |

### family-contract：4 项

断言文件为 `services/edge/test/family-contract.test.mjs`，均直接导入维护产品模块，不调用 HTTP、数据库或模型。

| ID / test 原名 | 断言行 | 实际产品代码与准确范围 |
|---|---:|---|
| F01 `strict JSON: duplicate keys, floats, exponents, unsafe ints rejected` | 6–7 | **实际组件**：`family/contract.mjs:parseStrict`（13–45）；5 类给定非法 JSON 拒绝及一个嵌套有效 JSON 的解析，不是完整输入空间证明 |
| F02 `canonical hash: key order independent, missing keys = null, actor ignored` | 11–16 | **实际组件**：`family/contract.mjs:canonical`（48）、`requestHash`（59）、`validateCommand`（65）；比较换键序/额外 actor 字段的 hash，检查 hash 形状与两个路径不匹配命令。标题中的“missing=null”未单独以显式 null/省略字段对照断言；也不证明真实 actor 身份鉴权 |
| F03 `text extractor keeps unknowns null` | 19–22 | **实际组件**：`family/extract-text.mjs:extractItemsFromText`（10），内部确定性日期/钟点/携带物规则；2 个合成中文句子，不调用 AI，没有儿童主体匹配或召回质量测试 |
| F04 `derived capture ids are stable UUIDs` | 25–26 | **实际组件**：`family/captures.mjs:derivedId`（11–16）；相同 capture/index 重算相等且 UUID 格式正确，不执行 capture route、写盘去重或跨不同 index 唯一性验证 |

### family-flag-gate：7 项

断言文件为 `services/edge/test/family-flag-gate.test.mjs`。所有用例运行实际 `config.mjs:readConfig`（51、87）/ `readFeatureGate`（92）和 `api.mjs:createCloudRuntime`（40、137、341、348）。开启时继续进入 `family/service.mjs:actorOf`（15–20）与 `/bootstrap`（45）；allowlist 使用实际 `config.mjs:featureAllows`（100）。测试第8行的 `familyStore.households` 固定返回空数组，第11–12行注入 `TestRepository` 与 token verifier，`autoKick:false`。因此它们是**实际路由/开关组合＋合成边界**，不是 SQL、RLS、JWT 或写入验收。

| ID / 展开后的 test | 断言行 | 准确覆盖 |
|---|---:|---|
| G01 `CATPAW_FAMILY_ENABLED=undefined: every family path 404` | 18–20 | 未设置时对第15行列举的 bootstrap/projection/recall 三条样本返回404；不是遍历所有家庭路由 |
| G02 `CATPAW_FAMILY_ENABLED="": every family path 404` | 18–20 | 空串，同一三条样本404 |
| G03 `CATPAW_FAMILY_ENABLED="off": every family path 404` | 18–20 | off，同一三条样本404 |
| G04 `CATPAW_FAMILY_ENABLED="false": every family path 404` | 18–20 | false，同一三条样本404 |
| G05 `CATPAW_FAMILY_ENABLED="0": every family path 404` | 18–20 | 0，同一三条样本404 |
| G06 `CATPAW_FAMILY_ENABLED=true: family served` | 25 | A/B 两个合成 subject 的 bootstrap 返回200；不读取真实家庭数据，不验证 projection/recall/写命令 |
| G07 `CATPAW_FAMILY_ENABLED=allowlist: only allowlisted subject is served, others 404; empty allowlist serves nobody` | 29–32 | A bootstrap200；B三条样本404；空allowlist时A bootstrap404。只证明注入身份下的入口gate，不证明数据库owner隔离 |

屏障为 `qa/family-cloud-verification/offline/offline-prelude.mjs:12–23`：禁止传输并把 `Deno.env` 置空；`capabilities.test.mjs:10` 又把 `fetch` 换成直接抛错的合成屏障，因此不能宣称这23项统一统计并断言“网络尝试数为0”。`node-strip-loader.mjs:14–20` 只转换 TypeScript 和解析现有 npm 包/惰性 stub，不模拟 Swift，也不提供真实 PostgreSQL、JWT 或依赖安装证据。

## 原位 controller 与密封恢复测试：25 项

同一 XCTest 文件新增下列方法，全部 **NOT RUN**。合成 backend actor 只提供 reply / observe / consent / cancel / delete 边界；真实 controller、会话服务、受限 backend、严格 parser、Repository 与密封文件逻辑均由产品代码执行。固定回复仅为 7 键协议 fixture，不复刻 parser/controller 算法。挂起请求用 expectation / continuation 决定交错，无 sleep。

| XCTest 方法 | 准确覆盖 | 执行状态 |
|---|---|---|
| `testInlineSuccessUsesPrivateSealedJournalAndOnlyProducesCandidate` | 真实私有 journal / 新 Repository 冷读；仅生成候选，不写安排账本 | NOT RUN |
| `testInlineAdmissionRefusalCreatesNoServiceAndSendsNothing` | admission 拒绝不创建 service、不发请求 | NOT RUN |
| `testInlineConsentIsRequiredBeforeSendAndOnlyMatchingReviewCanAllow` | 许可前 submit=0，只有当前 consentID 可授权 | NOT RUN |
| `testInlineDeferredOrSupersededConsentCannotAuthorizeLaterRequest` | 拒绝/过期许可不能授权下一次请求 | NOT RUN |
| `testInlineNotSentRetryUsesOriginalConversationTurnAndPrompt` | 明确 notSent 后显式重试保持 cid/op/prompt | NOT RUN |
| `testInlineUnknownRetryOnlyReadsOriginalRequestAndCanReconcile` | unknown 的 direct request 不新发；retry/reconcile 只读原 ID | NOT RUN |
| `testInlineCancellationTargetsOwnRequestAndLateReplyCannotRefill` | 取消原请求；受控迟到返回不能回填 | NOT RUN |
| `testInlineChangedSourceAndChildFenceEarlierLateCandidate` | 改原话/孩子并 invalidate 后，旧请求不能覆盖新候选 | NOT RUN |
| `testInlineEpochChangeRejectsLateCandidateAndInvalidationClearsIt` | epoch 变化后拒绝迟到候选并清理状态 | NOT RUN |
| `testInlineMalformedCompletedReplyIsNotAReadyCandidate` | 完成但非法 JSON 不成为候选 | NOT RUN |
| `testInlineRestrictedBackendRejectsMemorySideChannelInsteadOfImporting` | 真实受限 backend 拒绝 memory side channel | NOT RUN |
| `testInlineExplicitRetryAfterTerminalFailureUsesNewIdentity` | 确认终态失败才显式以新 cid/op/nonce 重试 | NOT RUN |
| `testInlineDuplicateTapWhileBusyDoesNotCreateAnotherRequest` | backend 挂起时重复点击只提交一次 | NOT RUN |
| `testInlineSealingFailurePreventsAnyBackendSendOrPlaintextFallback` | 真实持久层封装失败阻止发送，无明文回退 | NOT RUN |
| `testInlineCorruptSealedJournalCannotBeReopenedOrOverwrittenAsEmpty` | 损坏私有文件拒绝冷读，不按空态覆盖 | NOT RUN |
| `testInlineLiveRepositoryRefusesToOverwriteChangedOrRemovedJournal` | 运行中外部改/删文件阻止旧 Repository 覆写 | NOT RUN |
| `testInlineDeletionBeforeFirstWriteRevokesOldWriterAndAllowsFreshGeneration` | 首写前删除使旧 writer 永久失效；fresh generation 可保存 | NOT RUN |
| `testInlineDeletionDuringSealCannotRecreateFirstJournal` | seal 中重入删除后再校验路径代次，禁止复活首个文件 | NOT RUN |
| `testInlineRecoveryReferenceFreezesPromptAndContainsNoLoginToken` | 密封恢复引用保存原输入/身份/冻结时间，不保存登录 token | NOT RUN |
| `testInlineColdRecoverWithFreshEpochOnlyObservesOriginalRequest` | 新 Repository / 新 epoch 显式恢复，只 observe 原 cid/op | NOT RUN |
| `testInlineColdRecoverOfNotSentRequestNeverPostsImplicitly` | 冷恢复 notSent 也不自动 POST | NOT RUN |
| `testInlineExpiredRecoveryPurgesSourceAndQueuesIdentifiersOnly` | 24h 过期清原话，只保留待删除标识引用 | NOT RUN |
| `testInlineDeleteWhileWaitingPreventsLateReplyAndFileResurrection` | 等待时删除并围栏迟到结果和文件复活 | NOT RUN |
| `testInlineRemoteDeletionFailureStaysPendingUntilExplicitRetry` | 远端删除失败保留 pending，阻止新发，显式重试清除 | NOT RUN |
| `testInlineConsumeClearsTemporaryCopiesAndAllowsNewExplicitRequest` | 候选带回后清临时副本，metadata wrapper 可复用后续新请求 | NOT RUN |

恢复用例在受控的临时 journal URL 重新创建密封文件、Repository 和 service，并未验证生产默认路径发现；新 token 用注入 AccountEpoch.bump 模拟同账号重登，并非杀进程实测。测试 cipher 为合成掩码，不证明 Keychain / AES-GCM。取消基础用例验证精确原请求 cancel；生产清理分支另用真实 recovery / cleanup metadata 与远端 DELETE mock 验证。Swift actor、类型和 SDK 仍待编译。

## 新原位 HTTP 用例：13 项

`services/edge/test/parenting-intake-http.test.mjs` 通过实际 `memoryHTTPFixture` → `api.mjs:createCloudRuntime` → `parenting-intake.mjs:createParentingIntakeFetchHandler` → `chat-service.mjs:ChatService`，合同来自 `parenting-intake-contract.mjs`。全部是**真实 JS 产品模块＋合成 Auth/sourceChecker/provider/TestRepository**，不是静态字符串检查，也不是镜像算法。TestRepository snapshot 重建代表合成冷读，不代表真实 PostgreSQL、多实例或已部署服务。

| 用例（文件起始行） | 关键断言 / 实际范围 | 结果 |
|---|---|---|
| dedicated production handler…（28） | provider tools=[]；只含当前 user；memory/proactive/integration spy 为0；无 task/delegation；实际 marker 事件 | PASS，纳入70 |
| scope, subject, purpose and single-intent boundaries…（42） | 普通/原位 namespace、身份/分区、第二 intent、控制入口拒绝 | PASS，纳入70 |
| duplicate POST replays original receipt…（58） | 同ID重放原events；改体409；provider仅1次 | PASS，纳入70 |
| consent, source authority and existing daily quota…（64） | 无许可/来源撤销/敏感内容拒绝，daily limit 复用原 gate；provider调用计数 | PASS，纳入70 |
| tool calls cannot reach tool execution…（73） | tool、重复键、错nonce、额外child字段失败；executeTool=0，无完成事件/任务 | PASS，纳入70 |
| capability/context/attachment injection…（83） | 能力header/context/attachment/重复JSON在provider前拒绝 | PASS，纳入70 |
| cancel wins before model completion…（92） | deferred精确交错；取消先赢无迟到完成；完成先赢返回原终态 | PASS，纳入70 |
| unknown outcomes can only be read…（101） | unknown重放不再调模型；busy显式同IDretry仍受限 | PASS，纳入70 |
| normal namespace cannot bypass purpose fences…（108） | 两类重复斜杠、跨身份start/read/events/cancel/retry/DELETE及普通cid混入拒绝 | PASS，纳入70 |
| source, answer and reasoning canaries are live only…（119） | provider/事件有合成canary；durable snapshot及console.info无原话/输出/思考；冷读409且provider=0 | PASS，纳入70 |
| DELETE removes transient data…（133） | 清运行时/持久内容；只留identity/hash墓碑；迟到不复活；重复start410；delete幂等 | PASS，纳入70 |
| completed result deletion and fifteen-minute buffer expiry…（145） | 完成后删除、模拟16min缓存过期均不重生成 | PASS，纳入70 |
| untrusted provider failure details…（151） | 恶意provider错误code被白名单清理；snapshot及console.info无源canary | PASS，纳入70 |

此处只验证 fixture 快照与捕获的 console.info，不宣称已检查所有宿主/代理/供应商日志。测试 provider 没有真实模型调用，专用 NativeHTTP adapter 的 Swift 解析未运行。13 项属于前述 70 项回归，不能再相加成83。

## 源码观察与验收边界

- 认证后的实际维护入口接入育儿首页；DEBUG 历史 fixture 仍有独立分支。生产首页的判断来自 `catApp` 接线，不能用旧 `RootView` 或 fixture 界面抵扣。
- 本轮事实权威是账号/工作区分区内的本机加密账本。命令回执同封套持久化；最终持久化在 Repository actor 内由账号 epoch 围栏保护，写失败不发布候选快照。此为源码观察，未在当前主机运行 Swift 证明。
- 未确认安排为 draft；家长显式确认才进入 planned。完成是家长自报，生成独立完成记录；时间过去、AI 回复完成、外部聊天任务成功均不应自动完成孩子安排。
- 页面明确本机保存、未云同步、不发送提醒。生产密钥使用独立 Keychain namespace；其真机保留、签出/重登录、Data Protection、密钥损坏与卸载行为均未运行验证。匿名体验身份无法找回的风险须按最终页面如实说明。
- 未保存表单与已保存的待确认安排是不同对象。未保存表单仅在当前页面内，关闭或进程结束不能声称已持久保留；已经保存的 draft 才由上述冷盘测试覆盖。保存失败保留输入的 SwiftUI 行为尚未运行。
- 原位 controller 使用独立 cid/op/nonce、私有 service/journal、冻结原话与本机选择。现有模型许可绑定当前审阅ID；取消、改原话/孩子或账号代次变化使旧投影失效。候选只能显式带回可编辑表单，不自动确认/完成/保存安排。旧 ParentingAIIntake 聊天桥已删除；辅助聊天保留手动入口，不自动携带育儿原话。
- 专用 `/catpaw/parenting-intake/v1` 复用真实 Auth/source/consent/quota 与租约；tools=[]、不召回/写入记忆、不协商能力、不启动任务。普通 namespace 不能接管其请求；Native adapter 校验模式/ID/事件白名单，旧服务404/405关闭失败，不回退普通聊天。此为源码与JS fixture证据，尚非原生联网通过。
- 明确 notSent 重试原身份；unknown 禁止直接新发，只观察原请求；确认真实终态失败才可显式新attempt。服务本地 unknown 超时标记仍只读。恢复引用密封保存 source/child/goal/nonce/cid/冻结UTC时间与时区、不存登录token，冷恢复必须用户显式操作，只读原身份。
- 本机恢复引用按24h判定过期；带回候选、取消或显式删除时清临时副本；再次创建model/显式恢复发现过期后清理。应用关闭期间没有后台定时物理删除保证。远端删除失败仅保留密封标识队列并显示pending，阻止新整理直到显式清理成功；不删当前表单输入。路径代次在首写前及seal后检查，旧writer不能在删除后复活journal；metadata wrapper删除后可复用。composition仅弱引用Repository，不强留解密snapshot。
- 服务器durable快照不保存原话、输入history/model messages、输出或思考；仅进程内15min可回读内容。冷进程/过期返回content_unavailable，不静默再调用模型；DELETE保留最小identity/hash墓碑防重复复活。故本机24h恢复引用不保证15min后仍能拿回服务器回复，页面需如实呈现不可用。
- 时间依据检查只能证明候选时间附带原话中的日期/钟点片段，不能证明 `due_at` 与自然语言语义完全一致。最终 UI 保留原文及再次核对提示；真实模型提取准确性仍 NOT RUN。
- 最终 UI 已修复多孩子缺省选择：安排与观察仅在唯一孩子时自动选择；多孩子而调用方未选时保持 nil。失败表单可显式重新读回，保留输入后由用户重试；保存期间禁编辑，未保存关闭有范围说明。这些均为源码复核，实际交互仍 NOT RUN。

在已实现的本机账本与原位请求源码范围内，冻结字节独立审阅未发现仍需修改的高置信静态阻断；这不是原生产品验收通过。没有 Swift 编译器，所以类型检查、SDK 可用性与上述测试的真实编译结果仍未知；不能从“未发现”推导 App 能成功构建或运行。

## 尚未运行 / 环境阻塞

| 动作与目标 | 原因 | 状态 |
|---|---|---|
| 原位 AI 整理、许可/失败/重试/查询/精确取消、恢复与清理 | 源码已实现；Linux无法执行新原生controller/UI/HTTP adapter | NOT RUN；不能签收核心 AI 交互 |
| 编译 `cat`、执行上述 54 个 XCTest | 当前 Linux 无 Swift、Xcode、iOS SDK、Simulator | BLOCKED；未发起 SDK 编译或 XCTest |
| 实际首页点击、空/加载/失败/取消/重复/重进、浅深色、大字号、VoiceOver、键盘与截图 | 没有可运行原生宿主 | NOT RUN |
| 生产 AES/Keychain、真实 SwiftData、进程强杀与重登录、设备数据保全 | 未具备对应原生执行环境；测试采用临时 FilePersistence 与合成 codec | NOT RUN |
| 模型抽取、语音/图片、云同步、真实 PG/RLS/多实例、系统日历与通知 | 本轮仅本地合成资料，未调用这些服务 | NOT RUN；不以离线检查替代 |

没有操作被自动审批拒绝，也没有待批准的生产动作。本审查没有 push、PR、merge、deploy 或新增凭据。已有实现与测试可以继续由具备现有 Xcode 环境的执行端复验；这些缺口不能标为产品通过。

## Mac 接续命令

在已有 Xcode/iOS Simulator 环境中，从 `apps/ios-conversation` 目录执行。使用已经存在的合成模拟器，下面的 destination 需替换为实际已授权目标；不安装依赖、不调用生产服务，不覆盖版本和 build。

```sh
python3 Scripts/validate-project.py
python3 Scripts/check-localization.py
zsh Scripts/check-source.sh
xcodebuild -project cat.xcodeproj -scheme cat \
  -destination 'platform=iOS Simulator,id=<EXISTING_SIMULATOR_UDID>' \
  -only-testing:catTests/ParentingWorkspaceTests \
  -only-testing:catTests/ParentingIntakeTests \
  -only-testing:catTests/ParentingInlineIntakeTests test
```

`check-source.sh` 在 root 本轮实跑先被上述3处既有 Typography 阻断，尚未进入 Swift SDK typecheck；继续后还可能遇到完整 localization 的旧断言。应保存这些失败与对应字节，处置旧断言时保留安装/协议身份，再复跑，不跳过失败伪报整套通过。新 XCTest 只访问临时合成文件及注入 codec，不需真实家庭、Auth 或模型。

XCTest 通过后仍需用隔离的合成原生入口逐步验证首页空态、保存失败保留输入、取消、重复点击、进程重启、多个孩子切换、浅深色、大字号、读屏与键盘；本轮没有把原有聊天 fixture 当作育儿首页运行证据。

## 审查字节

下表记录当前本地审查快照；后续任何修改都需要更新对应 hash，不能沿用本报告为新字节背书。

<!-- REVIEW_SOURCE_HASHES -->

| 路径 | SHA-256 |
|---|---|
| `apps/ios-conversation/Tests/ParentingWorkspaceTests.swift` | `369127447625ce6dc101896d1a248dbcbf06752224fe77146af5a7c39564a204` |
| `apps/ios-conversation/Sources/Domain/ParentingWorkspace.swift` | `be88a50d8a20f5c0740b4836b0ffa768925bce6ad2b6621e19415a6035672f56` |
| `apps/ios-conversation/Sources/Domain/ParentingIntakeDraft.swift` | `b3f945d3653a7af1ab5ee5ba5f3062452becf55aaeb67cf34f20b887a3653a40` |
| `apps/ios-conversation/Sources/Domain/ParentingInlineIntake.swift` | `0b63e9003b7b3807b26682b6dd822cd17d9879a52314b52cad532300622c600a` |
| `apps/ios-conversation/Sources/Persistence/ParentingWorkspaceStore.swift` | `e4d27fbe72a1d97ee21b8846b99b8b0be3635358c1c9b2c9533f3332937cf4b1` |
| `apps/ios-conversation/Sources/Persistence/ParentingIntakePersistence.swift` | `9843f65e2bc8bf24cdb8fd0a494d6f3eb80a633e8f499b5ee66b6d3c8d3f41ea` |
| `apps/ios-conversation/Sources/Features/Parenting/ParentingWorkspaceModel.swift` | `c01aa09526011c070eda3bb5dc079285ef226aebda80a2dd35123e22a82bcab3` |
| `apps/ios-conversation/Sources/Features/Parenting/ParentingInlineIntakeModel.swift` | `ad2f66ec93e7a2866ef730d974376ec0d937f7cf3c83c422e969cdbd1a63ef50` |
| `apps/ios-conversation/Sources/Features/Parenting/ParentingHomeView.swift` | `f50db017486e24caeaec5696b406b3d0ed386a73c77054aebe73dc20024ac769` |
| `apps/ios-conversation/Sources/Providers/NativeParentingIntakeComposition.swift` | `b4c27cc2b9911cc067e482c153ec2c3657bc30df95e5c4b5c4b0155e2532236f` |
| `apps/ios-conversation/Sources/Providers/NativeChatHTTPBackend.swift` | `65b2d220c57eb13187870884c803408597f992d9c784cdc6324534459c9062f8` |
| `apps/ios-conversation/Sources/Features/ConversationSessionService.swift` | `eff443f925bc74e649f21e123aea7cbd93d73b686fecbae54d08078c3ab29806` |
| `apps/ios-conversation/Sources/App/ConversationFirstModel.swift` | `f36007e20a0b4ba7f4bc7a7cae0e368faff816446b0fc594b03cd5e0ae7376b1` |
| `apps/ios-conversation/Sources/App/NativeAuthApplicationModel.swift` | `33077b5c35212923aa96950371796c5a7d6068e9e8c30a41bd54f5870550fa9c` |
| `apps/ios-conversation/Sources/App/catApp.swift` | `01ebf06d16f17591a9d58a73bce194dbf28aebf84011728e10b73c42e42aebf2` |
| `apps/ios-conversation/cat.xcodeproj/project.pbxproj` | `ab7a2fc5099db5ccaa62917fbf04df8af0e8a3d0faef674da7324b0d7c72a846` |
| `apps/ios-conversation/Scripts/check-localization.py` | `bb2cc22e18487d806beeb4981143d3c34e7f1aea09c663283769f1a788e31463` |
| `apps/ios-conversation/Resources/UIStrings.json` | `a52dcf7a4f4f7728cdc907d09c1cfcefae1662a56d04ed7699730d30897d60f1` |
| `docs/product/capabilities/cat-capabilities.json` | `6e52003e41827873e7af93ccba528160021a87c71f2a24cb3981641f02272ca6` |
| `services/edge/supabase/functions/_shared/capabilities.mjs` | `4ed209b86d65c50df61a6b2703489665fbe8b1a9cb78d002b9c91d52a9f8daec` |
| `services/edge/supabase/functions/_shared/api.mjs` | `b9d277099a6c96472ea5da2f5e6b13f4331bdd478042cac38d6ff8f290af8821` |
| `services/edge/supabase/functions/_shared/core/src/chat-service.mjs` | `6665c6ed5b68d49fccfe27345bd4a8404348313f0a5920837fa4005611914520` |
| `services/edge/supabase/functions/_shared/core/src/parenting-intake-contract.mjs` | `220f7c0a7c730fdcb7bd2f26bc9c3b85eecea1da464c6ca0a0ec36ff41c27519` |
| `services/edge/supabase/functions/_shared/core/src/parenting-intake.mjs` | `315957b390677bc9071876693bfb7afbfecfbb3672c386a7650de5ec2f664df5` |
| `services/edge/test/parenting-intake-http.test.mjs` | `5bb2b80007bf22c91037d208bc906e35543f13fb76a8cd6d1a49567f125d3260` |
| `services/edge/test/capabilities.test.mjs` | `1de6aa8d53d9f433e5d083e7974795ab6ecfcec1512dad69c94c20ce49333046` |
| `services/edge/test/family-contract.test.mjs` | `d9fc3873c9906663fc4cbf014e91a1e9bb3566dba8b46072bf63209ad31b6b85` |
| `services/edge/test/family-flag-gate.test.mjs` | `02fabf0f2472c63ba8bf39efe3daf3d1e13c6e80c1922b43aa32b390889eaa0f` |
| `services/edge/test/support/node-strip-loader.mjs` | `412b9700506d18b4c8f39258febabf409515ef61c6a7414a7c3e9cbe8496e596` |
| `qa/family-cloud-verification/offline/offline-prelude.mjs` | `f7b45148c3508ecabc20387d939a589944358ca25b38913b2dba6926d41b3ae0` |
| `build/parenting-core/local-plist-validation.py` | `c6a1a5594f83dccca85b7faea724f1f9a3fc523aa4fc864086e5cf0be35c5d52` |
| `build/parenting-core/inline-node-regression.log` | `54f61ccd956733092b801bb456c7bcef9a7cad6ef1b152b5a37ea54680dfe217` |
| `build/parenting-core/parenting-intake-http-final.log` | `f04e7234d8d778ec59370228a901cb06230dd71422a5a5f560f9f216f2f11545` |
| `build/parenting-core/native-design.log` | `f7565abf4a1289c5b58cff3a740d903180e160bbb50688a555ad1124d02adb61` |
| `build/parenting-core/typography.log` | `b3839e52a32ef9976df561013eeae4845782566e75bf4efcb54a8a0db0580048` |
| `docs/design/family-companion/parenting-core.md` | `9569eb96a2ec360502911edb303c9bd300c452c981ac24498df627b3372dc830` |
