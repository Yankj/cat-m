# mimi 存量 PR 处置审计 · 2026-10-24

本文件是上海时间 2026-10-24 的固定版本审计，不是第二份实时状态。当前进度只在 [master-plan](../status/master-plan.md) 维护。依据是用户本次确认的 mimi M1–M6 Roadmap：默认“今天”，先完成 M1 的真实 iOS 构建、可编辑草稿、明确确认、调整/取消/完成/记录与恢复；同一时间只推进一个主里程碑。M2 的本机提醒、M3 成长回顾、M4 家庭记忆、M5 同步协作与主动通知、M6 家庭试用不提前宣称完成。

初次审计只读取 GitHub PR 元数据、diff、compare、CI 状态及本地 Git 对象。以下主体保留初次审计的“拟关闭”结论，后续处置回执见下段。执行前重新读取 PR head，若移动则重做差异审计。保留各源分支和固定提交，不删除来源，不用历史分支覆盖现有维护源。

2026-10-24 处置回执：重新读取 #113/#116/#120，head 均与下表一致。#120 已关闭、未合并，原描述完整保留在处置说明之后，源分支未删除。自动审批拒绝 #113/#116 的关闭与描述更新，原因是缺少明确关闭批准、担心原描述被覆盖；随后用户明确批准只关闭且保留原描述，已重读head与body无漂移，再仅更新state并读回closed/unmerged，原body完整相同；两条来源分支未删除。#123 后续推进到 `974dbb13db1113a49bd5b5cdc3c645663313b13a`，本地独立分支处理治理，用户已批准与云任务分工；下文 dd8661a 的源码/CI 仍是初次快照。

## 1. 固定版本与来源

GitHub 连接器 `get_pr_info` 返回的快照如下。审计比较主线固定为本地 `origin/main` 已有对象 `4ec8118b796f7c983ae4436268441c3c9d3d33db`，亦为 #123 的返回 base SHA。前三个 PR 的返回 base SHA 为较早的 `47e97f2`；本表保留原值，不能把它误写为本次比较用主线。

| PR | 读取时状态 | head ref / 完整 SHA | 连接器返回 base ref / 完整 SHA | PR 差异 |
|---|---|---|---|---|
| [#113 Test/family cloud verification](https://github.com/Yankj/mimi/pull/113) | open，非 draft，未合并 | `test/family-cloud-verification` / `543b62b569a970d717796dcd3a98d9c11274040b` | `main` / `47e97f206df2621e4137a8483ec40cc98e499c92` | 2 commits，43 文件，+6002/-0 |
| [#116 docs: family companion roadmap v1 (draft)](https://github.com/Yankj/mimi/pull/116) | open，非 draft，未合并；标题的 draft 不是 GitHub draft 状态 | `docs/family-roadmap` / `8b56f46e46d5e2770cf46b8194be9327e4322fb4` | `main` / `47e97f206df2621e4137a8483ec40cc98e499c92` | 1 commit，1 文件，+129/-0 |
| [#120 feat(ios-family): warm-style family SwiftUI client (unbuilt, needs Mac/BE5C verification)](https://github.com/Yankj/mimi/pull/120) | open，非 draft，未合并 | `feat/family-ios` / `e2703e5c28f9c27ca9dd729b2d632acda12c5d48` | `main` / `47e97f206df2621e4137a8483ec40cc98e499c92` | 4 commits，12 文件，+750/-1 |
| [#123 feat: 重定位小咪育儿核心并接入原位 AI 整理](https://github.com/Yankj/mimi/pull/123) | open，draft，未合并 | `feat/parenting-core` / `dd8661a4e3b703eb67184661b2a0a4f7ef5011d0` | `main` / `4ec8118b796f7c983ae4436268441c3c9d3d33db` | 3 commits，38 文件，+6847/-106 |

以上四个 head 与本地对应 `origin/*` 对象一致。GitHub `compare_commits` 对三个旧 head → #123 均返回 `diverged`：#113 为 ahead 68 / behind 2，#116 为 ahead 58 / behind 1，#120 为 ahead 58 / behind 4。**提交不在祖先链中不代表内容尚未取用**；处置依据是下文逐文件 blob 检查。

## 2. 处置结论

| PR | 拟处置 | 原因与资产去向 |
|---|---|---|
| #113 | 内容已取用，拟关闭；保留 `test/family-cloud-verification` 与固定 head | 43/43 个改动文件在主线 `4ec8118` 及 #123 `dd8661a` 都是相同 Git blob，没有剩余独有文件。无需再次合并历史。QA 原报告保持原字节，新运行放独立执行副本，按新候选另记证据。 |
| #116 | 被本次 M1–M6 路线替代，拟关闭；保留 `docs/family-roadmap` 与固定 head | 唯一独有文件是旧 `roadmap-v1.md`。其 v0.5–v1.0 分期、APNs/图片先行与具体试用阈值均为旧提案，不能与新路线并列成为执行权威；不把“已交付，待验收”导入新完成状态。 |
| #120 | 保留为未接线原生设计/协议候选，拟关闭；保留 `feat/family-ios` 与固定 head | 10 个新增 Swift 文件没有进入主线或 #123；其云端 projection 客户端和 DEBUG 示例入口与 #123 的账号隔离本机育儿账本是两条实现路径。现阶段不合并第二套事实源，不为演示路径继续补完整产品。可取用设计和协议经验，需按实际切片显式选择文件并重新验证。 |
| #123 | 保留 draft，作为唯一 M1 产品候选继续修复与验证 | 已接真实 App 组合点，包含本机账本和独立原位 AI 提取 namespace，符合当前方向。仍须关闭本版构建、宿主 XCTest、原生主流程与失败恢复问题；代码存在或便携回归通过都不是设备/线上验收。 |

关闭 #113 表示“资料已取用”，关闭 #116/#120 表示“当前实现路线已替代”；这三种处置都不表示它们的产品能力已验收，也不删除其历史证据。合并、部署和发版仍单独确认。本文件不授权远端写入。

## 3. #113：没有剩余独有字节，保留复验资产

主线提交 [`7cd39a36d325052c3dd0aaf2d2ea0fbfd008ee1c`](https://github.com/Yankj/mimi/commit/7cd39a36d325052c3dd0aaf2d2ea0fbfd008ee1c) 已导入该目录全部 43 文件。已有 [导入清单](../acceptance/family-companion/cloud-assets-provenance-2026-10-23.json) 固定来源 `a54d7f2b34db4bcda13fb1a22eaaf4b847dd9e17`；[接收记录](../acceptance/family-companion/product-contract-alignment-2026-10-23.md)明确原字节、原分母及未运行边界。本次进一步比较 PR 最终 head `543b62b`，确认 43 个文件依旧全部相同。

可继续使用的资产及边界：

- `offline/` 的 bootstrap、memory、reminder 故障探针、目标断言、禁网边界与显式 `--candidate <SHA>` runner。旧证据为 18 项目标断言 6 PASS / 12 FAIL；18 项现状复现不是另外 18 项独立产品测试。既有 223 项中的 222 PASS / 1 SKIP 另计，不可抵销目标失败。
- `security/` 的权限 fixture、来源 pin、日志 canary 与源代码探针。32 项家庭权限在真实权限层为 0/32 执行，全部 NOT_RUN；合成日志入口接收 canary 不是观察到生产泄漏。
- `product/` 的 12 个场景/36 条可观察断言、10 类交互状态、14 项 UI 要求。既有 crosswalk 的 72 行为接收映射，不是 72 项通过。它们可帮助编排 M1/M2/M4/M5 的相应门，不能借旧编号把后续阶段变成本轮全部实施。
- `BASELINE.json`、`ROOT-RECHECK.json`、`ASSERTION-MAP.json`、`FILES.json`、`HANDOFF.md` 等保留旧源码、契约、环境、hash 与局限。旧被测源 `789ad4feceb0680b8e2e5913083c5b834dc63db1` 的结果不用于判断当前修复候选。

## 4. #116：唯一旧路线文件的保留边界

独有资产为 [`docs/design/family-companion/roadmap-v1.md`](https://github.com/Yankj/mimi/blob/8b56f46e46d5e2770cf46b8194be9327e4322fb4/docs/design/family-companion/roadmap-v1.md)，Git blob `534acf7bf895ead305d76e96f76c4c13282b7063`。该文件未出现在主线或 #123。

“确认后才改”“记忆可纠正删除”“只用有来源的回顾”“第二照护者确认后才算接手”等原则与新路线相容，可以在未来阶段按原出处引用。旧文提出的 10 条通知、连续 7 天、5–10 户、95% 字段准确率、60% 留存、99% 提醒到达率等没有因本次整理获确认，不能自动变成 M6 指标。它把云通知与图片链路置于早期、成长放在 v0.8，且仍用 cat 展示名；保留为提案来源，不直接改成第二个当前路线文件。

## 5. #120：独有代码清单与不直接集成的原因

该候选基于 `catpaw.family.v1`，主要对象是 household、server projection、pending confirmation、memory 与 receipt。#123 使用 `ParentingWorkspace` 的 child/goal/arrangement/record 本机对象与受限原位 intake，不是同一个存储或命令合同。内部稳定协议名称保持；将来接云需要明确映射与版本化兼容，不用改名掩盖差异。

| 独有资产组 | 文件 | 可取用之处 / 当前边界 |
|---|---|---|
| 云合同 | `Domain/FamilyContracts.swift` | projection/revision/proposal/receipt 结构可作为后续接口审阅输入；不能替代当前 Parenting 领域或补出完成/目标合同 |
| 云适配器 | `Providers/FamilyHTTPBackend.swift` | 现有认证复用、固定 command_id、结果未知时 GET receipt 的思路；未接本轮 App 产品入口，仍需端到端验证 |
| 应用状态 | `Features/Family/FamilyStore.swift` | server projection 决定已安排、旧 revision 不覆盖新版本；pending command/capture 身份只在内存，不能证明进程退出恢复；不可替换现有持久化账本 |
| 界面候选 | `FamilyCaptureView.swift`、`FamilyConfirmCardView.swift`、`FamilyTodayView.swift`、`FamilyHomeView.swift`、`FamilyRootView.swift`、`FamilyWarmStyle.swift` | 待确认卡、需带物品、来源与记忆控制等布局可参考；需保持当前 mimi 品牌与原生 token，不能把展示候选算实际验收 |
| 示例后端 | `Providers/FamilyDemoBackend.swift` | DEBUG 演示数据，包含示例孩子、提醒与记忆；不得带入真实家庭列表或作为数据持久化证据 |
| 宿主修改 | `Features/ConversationFirstView.swift`、`cat.xcodeproj/project.pbxproj` | 原 PR 添加 DEBUG“我们家（示例数据）”及 `FamilyDemoBackend` fullScreenCover、工程成员；不导入该入口或覆盖 #123 工程文件 |

源代码还显示：`FamilyConfirmCardView` 只允许改标题和需带物品；`FamilyTodayView` 的已确认日程没有完成/调整/取消操作。这不满足当前 M1 全闭环。`FamilyStore` 各次 capture 新建 UUID、命令失败后刷新 projection，但没有持久未知命令队列；不能以 HTTP 层一次回查证明退出重进恢复。以上为静态范围判定，未在设备重现，不宣称已运行缺陷。

#120 与 #123 的 PR 改动路径交集仅为 `apps/ios-conversation/cat.xcodeproj/project.pbxproj`。路径冲突少并不等于产品可以同时集成；#120 会增加另一组候选领域/状态/界面与示例入口。本轮没有导入任何独有代码；固定 ref 足以保留后续选择性取用的来源。

## 6. CI 与验收证据边界

以下是连接器 `fetch_commit_workflow_runs` 返回的 PR 触发首屏 run，以及对应旧 PR jobs；不是所有历史运行的完整枚举。

| 固定 PR head | 读取到的 run | 实际状态 | 可得结论 |
|---|---|---|---|
| #113 `543b62b` | [39906073801](https://github.com/Yankj/mimi/actions/runs/39906073801)，run 165 | completed/failure；changes failure；ios/edge skipped | 没有当前 CI 通过证明；不说明被跳过的产品构建失败 |
| #116 `8b56f46` | [39906074559](https://github.com/Yankj/mimi/actions/runs/39906074559)，run 167 | completed/failure；changes failure；ios/edge skipped | 不能因为只有文档就称 CI 通过 |
| #120 `e2703e5` | [39906071404](https://github.com/Yankj/mimi/actions/runs/39906071404)，run 163 | completed/failure；changes failure；ios/edge skipped | 原 PR 明示未编译，本次也没有其 iOS 构建或原生验收证明 |
| #123 `dd8661a` | [39984692961](https://github.com/Yankj/mimi/actions/runs/39984692961)，run 201 | completed/cancelled | 取消不等于通过或失败；须对后续实际候选重新查验 |

#113 的 changes job 日志请求返回 GitHub 404 BlobNotFound；#120 的 steps 返回空数组，因此未推断旧三份 CI 的具体失败根因。#123 先前构建错误及证据层在 [2026-10-23 CI 记录](../acceptance/family-companion/parenting-ci-2026-10-23.md)；本日新修复与测试结果应另记，不覆盖旧记录。继续将代码、自动测试、设备验证、线上验收分开，旧 synthetic QA、Node 测试、静态工程检查都不关闭原生主流程验收。

## 7. 逐文件 Git blob 复核

下面的清单由本地固定 Git 对象生成。每个 PR 的文件集合使用 `git diff --name-only <git merge-base(main, head)> <head>`，逐文件以 `git rev-parse <ref>:<path>` 取 blob ID；相同 blob 表示字节相同，不依据提交标题或合并标志。比较目标分别为主线 `4ec8118b796f7c983ae4436268441c3c9d3d33db` 和 #123 `dd8661a4e3b703eb67184661b2a0a4f7ef5011d0`。`ABSENT` 表示目标树中没有路径。

本地复核没有执行 QA prepare/collect 或任何重写旧报告的脚本。没有做网络、模型、Auth、SQL、多实例、提醒、设备或线上验收。

清单摘要 hash 的算法：按 Git 输出顺序拼接 UTF-8 行 `path\tPR_blob\ttarget_blob_or_ABSENT\tresult\n`，其中 result 为 `same`、`different` 或 `absent`，再计算 SHA-256。表中 `=PR` 表示与该行 PR blob 完全相同。

### PR #113

Merge base（比较用主线与该 head）：`a2e9c43a61851d3f33f1c5713a144a219b044a5e`。

- 对 main：43 相同 / 0 不同 / 0 缺失；清单 SHA-256 `9bb2a046d56ad34f85d93b35294d5d6b282fcdc6673d252b23adf285aaf814f0`。
- 对 #123：43 相同 / 0 不同 / 0 缺失；清单 SHA-256 `9bb2a046d56ad34f85d93b35294d5d6b282fcdc6673d252b23adf285aaf814f0`。

| 文件 | PR blob | main blob | #123 blob |
|---|---|---|---|
| `qa/family-cloud-verification/ASSERTION-MAP.json` | `394cfa85ebabf0e53f659bfeab3c7c5b9daf5d33` | `=PR` | `=PR` |
| `qa/family-cloud-verification/BASELINE.json` | `0c7a18aed2c162ceab1ba64ad14731f39be5ffae` | `=PR` | `=PR` |
| `qa/family-cloud-verification/CAPABILITIES.json` | `7068c7fc604bd1415fab91e21023877509da82d6` | `=PR` | `=PR` |
| `qa/family-cloud-verification/DELIVERY-CHECKS.json` | `7250c288d55d926c86613908530258a2a3122539` | `=PR` | `=PR` |
| `qa/family-cloud-verification/FILES.json` | `bca33513bfdb56b4562498a203bd3b4f7d7b8284` | `=PR` | `=PR` |
| `qa/family-cloud-verification/HANDOFF.md` | `598219cfb8af5facd408c1090cc654bb9642dc6f` | `=PR` | `=PR` |
| `qa/family-cloud-verification/OWNERSHIP.md` | `0bbd899f278159e24a7d0ee158c061ef183c56d3` | `=PR` | `=PR` |
| `qa/family-cloud-verification/README.md` | `bf6dae8a8f88005eac22bd5897132e49b41aba89` | `=PR` | `=PR` |
| `qa/family-cloud-verification/ROOT-RECHECK.json` | `2b431d9ba7a3f6f9eb17d2f7d7f96db94a09b3d2` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline-guard.mjs` | `2ffd70919e275bfeb1820a57632c981d118c3ff9` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/ACCEPTANCE-MATRIX.md` | `9efdb77718c0d15cf0ea30cc43b2abe784d5ed83` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/AGENT-CONFIGURATION.json` | `ce14f78d8ad672aa6afe3d2796065778fb825e8d` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/EVIDENCE.json` | `87d34af7302648c9b34919eb7cbbd1988d86f248` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/REPORT.md` | `31ba36b317db2a868da64d52877eb422ced4ea11` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/bootstrap.test.mjs` | `2829efebce3e9ef4027d1b0f6a21f7753a6f6aa7` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/helpers.mjs` | `f4c3b91097bbe280a1eb871df171cebeeb1a9681` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/jose-boundary.mjs` | `c22035419bdc63763a91f8698fe473c10b757f06` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/memory.test.mjs` | `59ee4970fa21d73009709d8b25d824936b992e49` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/network-guard.test.mjs` | `360db8cfb56ef94c2e193e3643257aaa082d7d70` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/offline-loader.mjs` | `36467646b6e88dd33b03c1534b471c70aa7dc713` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/offline-prelude.mjs` | `598c6e6931142da7577bbc4d80ce4f3dc38a550b` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/postgres-boundary.mjs` | `dd5282a1b7ec95e85b9d43b457e81eb69315ca87` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/reminder.test.mjs` | `0d93b6e13abdedc55e6a628e0d2e89e00ffee3e1` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/run.mjs` | `c8d275c493c87c36da04c284a7df58476e7b8a23` | `=PR` | `=PR` |
| `qa/family-cloud-verification/offline/source-loader.mjs` | `a7ed98ab7e073e0034c1453ad9d8fe7aa5b070ec` | `=PR` | `=PR` |
| `qa/family-cloud-verification/product/interaction-state-contracts.md` | `6233ae84e7fe3f76733dfcd76e12778d6995c297` | `=PR` | `=PR` |
| `qa/family-cloud-verification/product/parenting-scenarios.json` | `1772f428eb6547682ad958e4dda131c135a64723` | `=PR` | `=PR` |
| `qa/family-cloud-verification/product/parenting-scenarios.md` | `4547957c279f3414556a0a02bf686207d0ffa50a` | `=PR` | `=PR` |
| `qa/family-cloud-verification/run-existing-offline.mjs` | `fbff7657425cde8803b499a7b85de64261296663` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/README.md` | `bc83b78494aa2f874076c27acfb47885d7d14e73` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/acceptance-checklist.json` | `2a0f396c80a48cda307b006e1b31d8cab53650b2` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/fixture-results.json` | `03bd93d8015d65037ef95b3dd9ac00881684919d` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/log-probe-results.json` | `29cdcfe3935cafa710564ce428b3a0df851bea00` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/permission-fixtures.mjs` | `95c64f2b61f3013bc754d36bbf5ba217a98a59cb` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/run-fixtures.mjs` | `0a53c13e5ff564421e3a24a4d4d3311e4a05594a` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/run-ledger.json` | `2e5a4aee9d70680c2b2685b9d06673f7acd13c26` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/run-log-probe.mjs` | `dfd0fa395b08117d547056eb41cce86d2131f5ac` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/run-source-probes.mjs` | `2c13db7e37140bb75c023993efca0cd9a08cf0d1` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/source-audit-results.json` | `2107967b8f092709613335c59930b7c2eb90934f` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/source-audit.mjs` | `ecb570d6fbf8cb15e0cd54bc5118d4b409b98230` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/source-pin.mjs` | `70cfb5e424ecad4c5a7876819007a982bdc74800` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/source-probe-results.json` | `f7b1cc91112f7a0885ab4a5e6d89386cabedba43` | `=PR` | `=PR` |
| `qa/family-cloud-verification/security/verification-results.json` | `68dde14309ae73c8996e9fc03d1c87221d7b6964` | `=PR` | `=PR` |

### PR #116

Merge base（比较用主线与该 head）：`285b0b63697cd425af2aad56fe972752dba1b6a6`。

- 对 main：0 相同 / 0 不同 / 1 缺失；清单 SHA-256 `5b938981c0656a29c3176f91e7df3761538415f7747e7997fec6b0f8fd88506d`。
- 对 #123：0 相同 / 0 不同 / 1 缺失；清单 SHA-256 `5b938981c0656a29c3176f91e7df3761538415f7747e7997fec6b0f8fd88506d`。

| 文件 | PR blob | main blob | #123 blob |
|---|---|---|---|
| `docs/design/family-companion/roadmap-v1.md` | `534acf7bf895ead305d76e96f76c4c13282b7063` | `ABSENT` | `ABSENT` |

### PR #120

Merge base（比较用主线与该 head）：`285b0b63697cd425af2aad56fe972752dba1b6a6`。

- 对 main：0 相同 / 2 不同 / 10 缺失；清单 SHA-256 `8a3c99032302a7519378132474f7db941242baf684c914f3f5b144c097098f56`。
- 对 #123：0 相同 / 2 不同 / 10 缺失；清单 SHA-256 `79f54b9bda12b26670e379e05ad9a0445cbbfd6bc02f8324ca47ad118bd227b5`。

| 文件 | PR blob | main blob | #123 blob |
|---|---|---|---|
| `apps/ios-conversation/Sources/Domain/FamilyContracts.swift` | `af37cc9258e88341e7d78d16e243f052b6f2bad3` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/ConversationFirstView.swift` | `94731991489b1c7351ddd14e97ada465398b250f` | `647e923449625422bfc580561e0b1e6713e9585b` | `647e923449625422bfc580561e0b1e6713e9585b` |
| `apps/ios-conversation/Sources/Features/Family/FamilyCaptureView.swift` | `93f3e2c38430741531172c3c3c531d7106ecd8a8` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/Family/FamilyConfirmCardView.swift` | `912fae4663a543d9afb6b6b0a1eb226f00f58652` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/Family/FamilyHomeView.swift` | `4139ea169c6e40d2c0bff93f12fa58e5c9581834` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/Family/FamilyRootView.swift` | `377b819c0f7ebe058df4d9e5df53ec36cb4b75f5` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/Family/FamilyStore.swift` | `009142ab52cdf5f325c0fa83821751c7cb13d272` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/Family/FamilyTodayView.swift` | `fd805caeaec63406a6642120b2e38f8fa086027f` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Features/Family/FamilyWarmStyle.swift` | `df801cc15af8084ea9ecc8516b6a5e163804571f` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Providers/FamilyDemoBackend.swift` | `1d1f45eb6ce8d39cf082180c8d7d99547b747a7b` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/Sources/Providers/FamilyHTTPBackend.swift` | `0714e0288dd2763b2c101847be05dbe8d667a7a7` | `ABSENT` | `ABSENT` |
| `apps/ios-conversation/cat.xcodeproj/project.pbxproj` | `223acce9b9d68d74bb24d9fecc8d8f3c58de3702` | `0210b8d21bab651c1cdad6ad9c8c0f0e82b2ccca` | `a464b8422e2f3ae579eeafd7b01d99ded1f780f4` |

### PR #123

Merge base（比较用主线与该 head）：`4ec8118b796f7c983ae4436268441c3c9d3d33db`。

- 对 main：0 相同 / 19 不同 / 19 缺失；清单 SHA-256 `13f80ae010aa37607896d8a200c0adc0cd7aa7eb2d5ba76b81d508f16761d78f`。
- 对 #123：38 相同 / 0 不同 / 0 缺失；清单 SHA-256 `13d25efda9115ee3e34e10beb882e3fe41c35a5dde240074daf9344c4c016db4`。

| 文件 | PR blob | main blob | #123 blob |
|---|---|---|---|
| `.github/workflows/ci.yml` | `8fcfdb1a4680bd380a682e6fabc811b555fd7f5a` | `a01969d2e32b1b5f2fbcc79f27d87859da7bf306` | `=PR` |
| `AGENTS.md` | `a02e3337991e3884174933faf3dfa20faed37482` | `d4d94bb5278321310a7e5e3e41e7e2617c2a2297` | `=PR` |
| `CHANGELOG.md` | `2be44320a21e7b4b63e38585e1b7887fd0e1a08c` | `53f925888fbd80b1d10331534db304caa1739afe` | `=PR` |
| `README.md` | `1de77be3957942fa0ef20ddec95978901d26fb05` | `07cf50427939a32404c672fdb1764053a8d29334` | `=PR` |
| `apps/ios-conversation/Resources/UIStrings.json` | `2398af69b70e167f2100fcf32b5486f59c69fd37` | `a798004ca07306244729509109042b86beb30375` | `=PR` |
| `apps/ios-conversation/Scripts/check-localization.py` | `d79ad1eeb114d6fca363b70e1de3cc10c3641676` | `a221d8c04c261e9a9a3ee9e14437de6546dadfee` | `=PR` |
| `apps/ios-conversation/Scripts/test-parenting-core-simulator.sh` | `46e0e6991ea2d8a2d278d8024c19086efb5cb57b` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/App/ConversationFirstModel.swift` | `858c317b5226073ede8ca638c9bb790f2e3f867d` | `1086182e363995dcc638341d32906bac65c3fb80` | `=PR` |
| `apps/ios-conversation/Sources/App/NativeAuthApplicationModel.swift` | `8886c033aab857f3ecbb51c603b3ba2ca000f267` | `ae72096f536088e676a4c641f78e8e7a48a9f97f` | `=PR` |
| `apps/ios-conversation/Sources/App/catApp.swift` | `2022ccee809e3614f6624dd446747fc0913517ad` | `e3058aeb6962b2364eef361c9b46fe15d5962ba2` | `=PR` |
| `apps/ios-conversation/Sources/Domain/ParentingInlineIntake.swift` | `79014c5343557a416baff1af4ea4b8403652a117` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Domain/ParentingIntakeDraft.swift` | `8772514a5d017cc535c94dc2f8b6865f2d331eff` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Domain/ParentingWorkspace.swift` | `776e713c4f76bfadbd553c1b23e2be6fae38503b` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Features/ConversationSessionService.swift` | `d65db10ba3b70f19d02d9a1e1fc068b6b4678cda` | `98789e1ca65d4431e9f87fb07e4ae77d8f4bbe3a` | `=PR` |
| `apps/ios-conversation/Sources/Features/NativeLoginView.swift` | `62b305f36f836561120c29381bc11f986508071a` | `8201679b0ffa18b8fd3824fea3f9707a9e266453` | `=PR` |
| `apps/ios-conversation/Sources/Features/Parenting/ParentingHomeView.swift` | `6386b94593165bba39f71bca6768258ed8663e6a` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Features/Parenting/ParentingInlineIntakeModel.swift` | `deb6c30dc9be4321e2ee194db565abae2d72d1e2` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Features/Parenting/ParentingWorkspaceModel.swift` | `806714c6d6b01fd9f19154d211dd0091e4e25d2a` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Persistence/ParentingIntakePersistence.swift` | `07e1bacbd9b8f92737b9e04df972d708727c8985` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Persistence/ParentingWorkspaceStore.swift` | `ed5d7f8961b8260c60b8e20dccc153ba86986a92` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Sources/Providers/NativeChatHTTPBackend.swift` | `b49306b0976232a646a21356170d8b2fc189d8ae` | `f717676e05a6336c78e399413e7396ddcba0e57a` | `=PR` |
| `apps/ios-conversation/Sources/Providers/NativeParentingIntakeComposition.swift` | `a2749af43b4fb6adaeb0eb134dc5b718f32c6c31` | `ABSENT` | `=PR` |
| `apps/ios-conversation/Tests/ParentingWorkspaceTests.swift` | `bc76ec8f1fa6afe660d2fd5cb52b285330fcfdda` | `ABSENT` | `=PR` |
| `apps/ios-conversation/cat.xcodeproj/project.pbxproj` | `a464b8422e2f3ae579eeafd7b01d99ded1f780f4` | `0210b8d21bab651c1cdad6ad9c8c0f0e82b2ccca` | `=PR` |
| `docs/README.md` | `7b1b76e31dcd3bcee63f62b359a60f6ee2f71c21` | `b3cab25dff791765a989f2c271ecb800e1e75813` | `=PR` |
| `docs/acceptance/family-companion/parenting-ci-2026-10-23.md` | `8f96bf31991e674bfaed01d5e93406df7b8078d3` | `ABSENT` | `=PR` |
| `docs/acceptance/family-companion/parenting-core-handoff.md` | `4ad540fff34a852c65e3ab54bc2f49d67e83b80d` | `ABSENT` | `=PR` |
| `docs/acceptance/family-companion/parenting-core-review.md` | `c428f7d5bf3468d6b9ee7d86f21c702eb60dd0e9` | `ABSENT` | `=PR` |
| `docs/design/family-companion/parenting-core.md` | `90665863b8cde57361e935c20a2f4e914ccedb5a` | `ABSENT` | `=PR` |
| `docs/design/family-companion/parenting-milestones.md` | `270ab6ab23e3e721c2f5d9d9a1bf9308fbe755aa` | `ABSENT` | `=PR` |
| `docs/product/capabilities/cat-capabilities.json` | `e8c0514e5f057515f8b63f8ebf6df4f7f8f1e598` | `5b70562d09e72cadfcc65c2fd126f507db800405` | `=PR` |
| `docs/status/master-plan.md` | `c161bbe6fcb7194335cf7b97b20843d3b274a9ca` | `649d8c4ed17cb43f5d8b6fceb30b0ca7241f502d` | `=PR` |
| `services/edge/supabase/functions/_shared/api.mjs` | `687b15cdb0a290f17ed390351b851fa98818e9d9` | `e6601e4d9baa37438295694bd717b6495c30048f` | `=PR` |
| `services/edge/supabase/functions/_shared/capabilities.mjs` | `71402b295f9e8e837739b62f434fb3c2085e5ada` | `dcf97616edbb6e11c796dbe4b6f98068364569fd` | `=PR` |
| `services/edge/supabase/functions/_shared/core/src/chat-service.mjs` | `23ae77117f6062bf7443c11efae61587db15dbaf` | `5811d6209cafd74ef4763e43acff5c048ffd412c` | `=PR` |
| `services/edge/supabase/functions/_shared/core/src/parenting-intake-contract.mjs` | `f76dd3cbe17de120be5233c91591bc66eebb0c82` | `ABSENT` | `=PR` |
| `services/edge/supabase/functions/_shared/core/src/parenting-intake.mjs` | `141daf84c2f31a9814da49e1df09bc1a5ca6f571` | `ABSENT` | `=PR` |
| `services/edge/test/parenting-intake-http.test.mjs` | `a2ee12aac73d6c676c9d2165fec3206cce586f23` | `ABSENT` | `=PR` |
