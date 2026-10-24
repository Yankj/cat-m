# mimi 仓库角色与冻结资产审计（2026-10-24）

本记录是日期审计，当前执行顺序见 [M1–M6 Roadmap](../product/mimi-roadmap.md)，实时进展只在 [主计划](../status/master-plan.md)。审计区分远端缓存 `origin/main@4ec8118b796f7c983ae4436268441c3c9d3d33db` 与 PR #123 候选；恢复包准备时本地候选 HEAD 为 `974dbb13db1113a49bd5b5cdc3c645663313b13a`。main 的默认入口仍为对话，今天首页是 #123 的候选行为，不能提前写成已合入或已验收。

## 资产角色与处理

| 资产 | 角色 | 本轮处理与边界 |
|---|---|---|
| `apps/ios-conversation` | 唯一原生维护宿主 | 沿现有 App、Domain、Providers、Persistence 分层推进 M1；不新建 App 壳 |
| `services/edge/supabase/functions` | 唯一后端维护源码 | 目录清单列出实际存在的 API、proactive 两入口；tick 不能由部署快照冒充维护入口 |
| `Sources/Features/Parenting`、`ParentingWorkspaceStore` | #123 的今天、安排、记录与本机账本候选 | 明确本机事实、模型草稿与系统提醒分别成立；尚不等于云同步 |
| `_shared/family` 与既有迁移 | 家庭 Postgres 合同及实现资产 | 保留协议与来源；与本机 Parenting 的映射、迁移和同步属于后续设计，不能默认双写 |
| `packages/ios-navigation`、`packages/ios-image-composer` | 已接入宿主的共享组件 | 保留，不拥有账号、网络准入或执行授权；包测试不能替代宿主验证 |
| `apps/website` | 官网迁出说明 | 本地只保留入口；维护仓库为 `Yankj/heydusk-site` 的 `apps/mimi`，无原生和后端执行权 |
| `docs/brand`、原生资源与 design tokens | 品牌来源与产品视觉资产 | 保留用户选择的图标与品牌几何；历史源图不批量改字、重压缩或覆盖 |
| `apps/ios`、`apps/ios-openmuse-demo` | 冻结历史来源 | 不继续开发、不删除；发现的 24 处品牌漂移只准备恢复包，尚未应用 |
| `services/facade`、`services/offline`、`vendor/openmuse` | 历史适配、固定上游和精确 patch | 保留 MIT、合同、来源清单与可重建关系，不作为另一维护线 |
| `services/edge/deployed-baselines` | 收到的部署快照 | 保留日期与 hash，不覆盖或推断为当前生产状态 |
| 日期验收、`qa` 与家庭记忆语料 | 各自输入版本的证据与复用用例 | 保存原失败、分母和来源；不重跑 prepare 脚本覆盖原报告，不把语料通过数当产品验收 |
| `docs/design`、`docs/research`、根 `design/research` | 现行设计入口与保留研究来源 | 当前入口按新 Roadmap 分流；旧原型、M0–M5 和 AF/FINAL 文档保留历史身份 |
| ignored `build`、`local-audit` | 执行日志、恢复候选和私人证据 | 不提交原始运行输出、凭据、设备截图或家庭数据 |

## 目录治理修复

旧 `repository-layout.json.website` 是远端仓库描述字符串，检查器却把它当本地路径并强制要求 `package.json`，因此官网迁出后布局检查必然失败。本轮恢复本地 `apps/website` 路径，分开记录 `external_repository_stub` 角色、远端仓库、源码子路径和本地 README。检查器验证迁出说明与精确外部来源一致，并拒绝本地重新出现站点构建 manifest 或原生工程。

清单补入实际存在的 `catpaw-proactive/index.ts`，检查器将实际一级函数入口与清单做集合比较，避免漏报或假造 tick。`current_goal` 指向最新 Roadmap，旧 AF 与家庭执行文件列为历史合同。原有单 App、包不拥有网络、Domain 不依赖 UI、路径不得越界等检查保留。

## 冻结漂移与未应用恢复包

24 个文件与现有冻结清单不一致，全部能从固定导入提交 `7d2fba28c0fd5e40093c9cc8c59b6a9d86d9c17a` 恢复到原 SHA-256。不是新增产品逻辑丢失：16 个源码／资源文件的漂移来自 `a811ac2e6fb9bcb69542e85ee177a854daead9c4` 的历史 Demo 品牌替换；8 份冻结 spec 来自 `92a5a1e47fde07b98eb722024f7217d7d21051fd` 与 `1e7989e73020a729bf2dc51f2bda92422f2228df` 的批量文案替换。

`apps/ios` 与 `apps/ios-openmuse-demo` 各涉及以下 12 个相对路径：

| 类别 | 相对路径 |
|---|---|
| 领域 | `Sources/Domain/ReadoutPolicy.swift` |
| 界面／服务 | `Sources/Features/AssistantService.swift`、`ConversationView.swift`、`RootView.swift`、`SettingsView.swift` |
| 夹具 | `Sources/Providers/FixtureProvider.swift` |
| 资源 | `Resources/Info.plist`、`Resources/UIStrings.json` |
| 冻结规格 | `docs/spec/catpaw-ios-implementation-plan.md`、`catpaw-ios-start-review.md`、`catpaw-product-spec.md`、`catpaw-technical-spec.md` |

恢复候选只包含这 24 个文件，位于 ignored `build/mimi-roadmap-20261024/frozen-source-restore.patch`；配套 `frozen-source-restore-manifest.json` 固定当前／原始完整 SHA-256、字节数、原提交、漂移提交与清单要求。patch SHA-256 为 `1a86eeb5e14f77d49b0bdf6e1c843162b18fb7ecfabe43b6ba4c2d3a071fbf3f`。`git apply --check` 通过；**尚未应用，两个冻结目录原字节未改**。应用前须再次核对 manifest 的当前 hash，不能覆盖其他改动。

广扫来源 manifest 另出现 7 项原始归档与导入差异：4 个 r3 脚本在导入 provenance 中已标记 `transformed=true`，3 个打包／对比脚本从未导入。这些不属于漂移恢复清单，不能为了凑齐原始归档而额外导入。原有检查按受控导入范围比较，日期 manifest 不重写。

## 精确敏感项复核

扫描器规则未修改，仅增加两条受 hash 约束的既有审阅记录：

- `NativeOAuthTests.swift:106` 是注入 `OAuthFakeRemote` 的合成 token 标记。`7e45e902` 只改另一处品牌锚点，触发行字节与既有审阅一致；当前文件 SHA-256 为 `c139dd8533e1e693d3d7846a0680b8237d3f10c6c60a4f1ef9d6db25b71e0d78`。
- `docs/brand/png/source-logo.jpg` 来自 `a1ce541e`，19,589 字节；目视为橙底奶油猫标与历史产品字样。JPEG 的 Exif／IPTC 已解析，描述和 UserComment 为 `Screenshot`，其余为截图日期时间、方向、分辨率、尺寸与色彩信息，无 GPS、相机序列、owner、账户或儿童资料。原始 SHA-256 为 `b4928d8d8e63ee00cc17714ef0bb482dcf7b8caea432628dc8934cb13966fdcb`，保留来源字节，不全局允许 JPEG。

旧日期报告中的扫描失败继续保留。新字节、不同路径或不同触发行不能复用本轮审阅记录。

## 本轮验证

| 检查 | 结果 | 范围 |
|---|---|---|
| `python3 scripts/check-repository-layout.py` | PASS | 当前工作区目录、单宿主、两函数入口、迁出官网与组件边界 |
| `python3 scripts/scan-repository.py` | PASS | 0 阻断、0 待人工复核；仅本轮精确文件 hash 受审，规则未放宽 |
| 实际检查器的隔离夹具 | 16/16 PASS | 2 个正例、14 个拒绝例；真实运行现有脚本，不复制检查逻辑 |
| 恢复 patch `git apply --check` | PASS | 只证明 24 文件候选可应用，没有修改冻结文件 |
| `python3 scripts/check-repository.py` | 仍有已知 FAIL | 冻结来源恢复尚未执行；不改 hash 或跳过门来制造 PASS |

隔离夹具覆盖缺迁出说明、外部来源变更、站点重新成为维护源码、网站原生工程、漏列／多列后端入口、新 App、第二 `@main`、Domain 引入 UI、包拥有网络、路径越界，以及 JPEG／OAuth 审阅记录遇到不同字节或路径后重新拒绝。执行脚本和逐例输出保存在 ignored `build/mimi-roadmap-20261024/`。此处没有执行 App、模型、设备、云端、通知或部署验收。

## 附录：AF Goal 输入的历史身份漂移

`goal-evidence-map.json` 的 72 项输入中，41 项当前字节匹配，22 项不匹配，另 9 项声明为 `local_only` 且本检出点未提供；没有缺失的 versioned 输入。9 项不可用符合原检查合同，不应伪造文件或放宽门。

22 项均在本仓历史找到与既有 pin 完全一致的原字节。逐字符差异仅为 `Catpaw`／`Catpaw-m`／`cat` 到 `mimi`／`小咪` 的称谓、相邻空格与 `Yankj` 仓库 URL 改名；未发现 pin 之后的需求、交互、验收阈值、性能数字或实现语义更新。此前 R4／R5 和交付合同的实质更新已经包含在对应 pin 内，不能用更早统一基线覆盖。

最小修复是按下面逐文件原提交恢复历史身份，保持 evidence map 的 SHA-256 和日期证据不变。原文件不追加“已归档”横幅；由当前 Roadmap、文档索引和历史合同分类说明其地位，恢复旧字节不恢复旧产品执行方向。无需新增重复的冻结副本，也无需把 map 批量改成现状 hash。

| ID | 文件 | 原 pin 字节提交 |
|---|---|---|
| E03 | `design/catpaw-restart-review-and-plan-2026-10-13.md` | A |
| E09 | `research/openmuse-opendots-copilotkit-assessment-2026-10-13.md` | A |
| E12 | `docs/design/ios-codex-reference-review-2026-10-13.md` | B |
| E13 | `docs/design/ios-codex-experience-spec.md` | C |
| E17 | `docs/research/copilotkit-four-repo-decision-update-2026-10-13.md` | D |
| E19 | `docs/research/openmuse-code-gap-review-2026-10-13.md` | D |
| E20 | `docs/research/opendots-code-review-2026-10-13.md` | D |
| E21 | `docs/research/openbot-code-review-2026-10-13.md` | D |
| E22 | `docs/research/openintelligentui-code-review-2026-10-13.md` | D |
| E23 | `docs/research/grok-companion-integration-review-2026-10-13.md` | D |
| E25 | `docs/product/catpaw-final-product-spec.md` | C |
| E26 | `docs/acceptance/catpaw-final-product-acceptance.md` | D |
| E29 | `docs/research/copilotkit-conversation-ui-onboarding-review-2026-10-13.md` | D |
| E35 | `docs/planning/AF-1/long-task-development-prompt.md` | C |
| E36 | `docs/design/product-experience-review-2026-10-13.md` | D |
| E37 | `docs/design/taste-visual-motion-r2.md` | C |
| E44 | `docs/design/prototypes/catpaw-interaction-r3/README.md` | C |
| E50 | `docs/design/native-interaction-motion-r4.md` | C |
| E52 | `docs/design/prototypes/catpaw-motion-study-r4/README.md` | C |
| E54 | `docs/design/prototypes/catpaw-motion-study-r4/assets/concept-generation-prompts-r4.md` | D |
| E67 | `docs/design/mobile-conversation-reference-r5.md` | C |
| E69 | `docs/design/prototypes/catpaw-mobile-reference-r5/README.md` | C |

来源 A：`290115f37a7348fd3659c405f4aa79b223b841e7`；B：`77fa779b54cb5e13e0c1a2b8e9fa031141093de8`；C：`181b298e34197e48d2b8c062ffc07cba0a3e3b34`；D：`75c1a20de3df0879f8cbf2b2dec166d0d78f495c`。

只读验证将这 22 份候选字节临时映射到 Python 进程的文件读取，运行未修改的 `check-agent-foundation-goals.py` 完整通过（72 输入、9 local_only 不可用），同样的内存状态运行原敏感扫描为 0 阻断、0 待人工项。**这是未应用恢复候选的内存验证，不是当前磁盘检查通过。** 没有改 map、22 份源文件或 24 个冻结 App 文件。

可复核候选在 ignored `build/mimi-roadmap-20261024/goal-input-restore.patch` 及 `goal-input-restore-manifest.json`。patch SHA-256 为 `736c7339a2da3453183483d3dbda8c41befd960964ad84778a3b347f448affa5`；manifest SHA-256 为 `86d931458d52dc958b4cdda6141978077a0d400595626c5dbe8b5137c9088ad2`。manifest 固定逐文件当前／原 pin hash、完整来源提交及未应用状态；`git apply --check` 通过。候选不含本轮 README／当前 Roadmap／master-plan／家庭执行入口改动，也不含两个冻结 App 目录。


## 22 项历史输入实际恢复回执

2026-10-24，Root 在应用前重新核对 patch、全部22个当前hash及原 evidence-map hash，随后仅应用上述历史输入补丁。逐文件恢复hash全部匹配，未改 evidence map；原 `check-agent-foundation-goals.py` 实跑 PASS（72项hash绑定输入，9项local-only不可用按原合同保留）。这次只恢复历史品牌/仓库引用字节，不给旧合同新增产品权威；24个冻结App文件仍未应用，等待用户对冻结目录的明确恢复确认。


## 已批准的 24 项冻结来源恢复回执

用户在本聊天明确批准上述24文件补丁作为冻结目录的恢复例外。Root重新核对所有当前hash与patch hash后应用，并逐一确认恢复hash；原manifest与旧品牌变更提交均保留。原 `check-repository.py` 实跑全通过：44份固定上游、MIT、精确patch、188项导入来源、v1源码/10规格/3截图、121项r3来源/43源码/101项manifest/4截图。当前原生宿主、后端产品、用户数据与生产配置没有被该恢复改动。上文“尚未应用”是准备时快照，本段记录实际完成。


## 本地推送规则迁移

首次携带 `.githooks` 的治理分支推送被本地规则拒绝：白名单仍只有旧 `Yankj/cat-m` 地址，已核实的 `Yankj/mimi` 地址未列入。该拒绝没有更新远端；已精确加入新仓库的 HTTPS/SSH 地址，保留旧地址兼容及 origin/main、非快进、无关历史和私有路径屏障。新增 `scripts/test-git-policy.py` 通过真实临时Git对象与原hook执行5组/38场景，全部通过，零网络/实际推送。不是绕过hook，也不表示GitHub服务器保护已启用。

四项新hash的SSH URL人工命中已逐行确认仅为公共GitHub传输语法，按路径/行/hash追加既有审阅记录；未改扫描器或放宽全局规则。
