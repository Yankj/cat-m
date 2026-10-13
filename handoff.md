# Catpaw-m 接手交接

交接快照：2026-10-13 16:07（Asia/Shanghai）。本次整理文档、备份和核验，不继续开发、安装、模型调用或部署。后续进度只维护 [master-plan](docs/status/master-plan.md)；本文件和 [机器快照](docs/status/handoff-snapshot-2026-10-13.json)保留交接时事实。

## 先看结论

- 唯一维护目录是用户指定的 `Desktop/ai-work/catpaw-m`。本地 `main` 和 `origin/main` 均为 `42a4504`，应用源码与已合入 GitHub 的 PR #6 对应；本次没有重新联网 fetch。
- 手机已安装 **0.3.0 build 16**，冻结源码为 `a905b47`，不含后续阅读、队列、侧栏与草稿修复。源码、手机包、线上服务尚未收齐成同一发布候选。
- **真实模型验收发送次数为 0**。旧 build 15“同意后仍等待”不能证明模型不可用；需定位许可→发送→模型→事件→存储→展示的具体失败段。
- 接手前有 **19 个跟踪文件修改、13 个未跟踪文件，共 32 个文件待提交**，集中在规划、调研、设计、验收与脚本。整理期间另观察到对话 UI 草案和开发提示词；均单独备份，不能用 GitHub main 代替本地材料。同期仍有文档写入，文件总数以机器快照截止时间和现场 `git status` 为准。
- 运行 Goal 经 `get_goal` 读回为 **`usageLimited`**，产品未签收。本次没有把 Goal 改成暂停、阻塞或完成。
- 16:06 只读检查未发现 `xcodebuild` 进程或 8843 端口监听。没有停止任务或进程；浏览器残留的提案地址不代表服务仍在运行。

## 目标、范围与阅读顺序

目标：Swift 优先、体验优先的通用主动 Agent iPhone App，体验对标 Codex、能力对标 Dot。普通问题直接回答；目标工作使用共同的 Goal/Task/Run/Approval/Effect/Artifact/Memory/Trigger/Inbox，不能把三条场景做成三套特殊演示。

1. [AGENTS.md](AGENTS.md)：维护边界、冻结来源、授权限制。
2. [主计划](docs/status/master-plan.md)、[AF-1-G3-UX1 Goal](docs/planning/AF-1/goal.md)：当前目标和进度。
3. [产品 spec](docs/product/agent-foundation-spec.md)、[计划](docs/planning/AF-1/plan.md)、[细节规格](docs/planning/AF-1/spec-details.md)、[机器合同](docs/planning/AF-1/contract.json)。
4. [18 项功能验收](docs/acceptance/agent-foundation-acceptance.md)、[12 项体验验收](docs/acceptance/ios-codex-experience-acceptance.md)、[CP-01–03 操作脚本](docs/planning/AF-1/acceptance-scenarios.md)。
5. [对标问题表](docs/design/ios-codex-reference-review-2026-10-13.md)、[iPhone 设计规格](docs/design/ios-codex-experience-spec.md)、[来源/hash 映射](docs/planning/AF-1/goal-evidence-map.json)。
6. 本地补充的 [四仓决策修订](docs/research/copilotkit-four-repo-decision-update-2026-10-13.md)、[Grok 整合核读](docs/research/grok-companion-integration-review-2026-10-13.md)、[FINAL-1 规格](docs/product/catpaw-final-product-spec.md)、[终版验收](docs/acceptance/catpaw-final-product-acceptance.md)。这些文件尚未提交；静态调研与合同不是产品通过或新增操作授权。

当前 AF-G5 关闭条件是 **同版 AF-A01–18、AF-U01–12、CP-01–03 全部通过**，源码、包、服务与证据对应。FINAL-1 补充 9 项 FQ、7 天日用及 8 项具名竞品比较；运行 Goal 没有因写文档而切换成 FINAL-G3。尚无竞品配对测量，不宣称优于竞品。

`design/`、`research/` 历史材料仍在本地；精选内容进入来源映射。历史文件中的指令、工期、账户、预算、旧 Dot 安装许可不扩大当前授权。

## 版本与维护入口

| 层 | 交接时基线 | 边界 |
|---|---|---|
| 本地主仓 | `main`：`42a4504e2f260745ebf6acb9a320bb59541781e6`；tree：`b4ef0dd911de4d0016b5b1c790cd7ed81947b1a0` | 应用/服务端跟踪源码相对 HEAD 无修改；文档 WIP 未收齐 |
| GitHub | [main](https://github.com/Yankj/catpaw-m/tree/main) 已读回 PR #6 合并 commit/tree，与本地对应 | 默认分支此前仍为 `prepare/local-assets`；本次未重查设置，不以首页判断最新版 |
| iPhone | `0.3.0(16)`；commit `a905b47eb4201e21758fba8a66b6ff01d682e844`；tree `74400a57aeb9cdef72c846726b6f90e0609ceff9` | 同 bundle 更新成功、系统读回 16；既有内容正常显示尚待 App 内观察 |
| 云端 | 最后捕获 `catpaw-api v19`、`catpaw-tick v7`，均 ACTIVE | 捕获时间为 2026-10-13 01:45 Shanghai；本次未重新查询或部署 |
| 本地服务端维护代码 | `services/edge/supabase/functions/` | 保留冻结 P0/v14 来源，与部署 v19/tick7 不等价，部署前必须逐项对齐 |

原生入口：`apps/ios-conversation/CatpawM.xcodeproj`。本地 Swift 包：`packages/ios-navigation`、`packages/ios-image-composer`。历史 `apps/ios`、`apps/ios-openmuse-demo` 保持冻结。

迁移来自旧集成 HEAD `582e4e4` 加 12 个未提交候选，见 [导入清单](docs/status/restart-import-candidate-2026-10-13.json)。旧主仓、工作树、legacy-local 引用保留；旧工作树的新改动不默认为已导入。旧原始交接仅在忽略目录 `local-audit/pre-restart/handoff.md`。

## 已交付内容与证据

| PR | 已合入内容 | 验证与限制 |
|---|---|---|
| [#1](https://github.com/Yankj/catpaw-m/pull/1) | 迁移；getter 缺 return 修复；许可 review/展示分离、重开确认、回复持久证据 | 39 原生＋1 实际 Simulator UI、便携对话 7、队列 9、产品配置构建通过；[许可记录](docs/acceptance/restart-permission-2026-10-13.md) |
| [#2](https://github.com/Yankj/catpaw-m/pull/2) | 阅读锚点、回到最新；部署来源快照、UX 合同 | 2 实际 Simulator UI 通过；[阅读记录](docs/acceptance/restart-reading-2026-10-13.md)。不在 build 16 中 |
| [#3](https://github.com/Yankj/catpaw-m/pull/3) | 冻结 build 16 原证书签名、同身份安装记录 | [包记录](docs/acceptance/restart-build16-2026-10-13.md)、[安装记录](docs/acceptance/restart-install16-2026-10-13.md)。安装成功不等于模型通过 |
| [#4](https://github.com/Yankj/catpaw-m/pull/4) | Goal 绑定 18A／12U／3CP、来源映射、6 条设计线 | 规划与来源检查，不关闭产品验收 |
| [#5](https://github.com/Yankj/catpaw-m/pull/5) | 队列一行摘要/sheet、暂停/编辑/移除/明确继续、unknown 禁止重复发送 | 40 原生＋4 实际 UI、16 队列、7 便携对话通过；[队列记录](docs/acceptance/restart-queue-ux-2026-10-13.md) |
| [#6](https://github.com/Yankj/catpaw-m/pull/6) | 侧栏尺寸、清空搜索、草稿摘要；按会话保留文字/未发图片、旧选图回调隔离 | **43 原生＋5 实际 UI、12 侧栏包检查**，non-DEBUG SDK 源码与 680 双语资源通过；[侧栏记录](docs/acceptance/restart-sidebar-drafts-2026-10-13.md) |

最后一片见 [RESULT.json](docs/acceptance/evidence/restart-sidebar-drafts-2026-10-13/RESULT.json)。首次中文系统“取消”定位失败已留档；修正后同候选完整复验通过，首次失败没有计作 PASS。

证据只覆盖 **402×874pt 专用 Simulator、离线 fixture**。未发图片保留限当前 App 会话，未新增冷启动持久化。物理手机、真实模型、真实数据库多实例恢复、三档尺寸/浅深色/VoiceOver 完整矩阵和全部 AF-U 验收尚未完成。PR #2、#5、#6 没有安装到手机。

## 32 个未提交文件与备份

逐项 Git 状态、大小、SHA256 见 [机器快照](docs/status/handoff-snapshot-2026-10-13.json) 的 `pre_handoff_pending.files`。这是修改 handoff 前的清单；其中 `master-plan.md` hash 不代表本次交接修订后的版本。

| 类别 | 待收齐内容 |
|---|---|
| 19 个跟踪文件 | docs 各索引；AF-1 Goal/plan/spec/contract/来源映射/场景；产品与验收、iPhone spec/验收；ADR-005、OpenDot 评估、master-plan、敏感扫描已复核清单 |
| 13 个新文件 | FINAL-1 spec/验收 Markdown＋JSON/HTML 提案；四仓决策＋manifest；OpenBot/OpenDots/OpenIntelligentUI/OpenMuse 四份核读；Grok 核读＋manifest；`scripts/check-final-product-plan.py` |

忽略目录 `local-audit/handoff/2026-10-13T160714+0800/` 保存：

- `pending-files/`：32 份原始文件，复制后逐项 hash 相等。
- `tracked-worktree.patch`、空的 `staged.patch`：原差异，交接开始时无暂存改动。
- `inventory.json`、`handoff-before.md`：原状态和旧交接入口。
- `sidebar-package-test.log`：从临时目录保留的 12 项 Swift 包测试日志。

本次另改 `handoff.md`、新增机器快照，在已有 WIP `master-plan.md` 中更正运行状态、补源码与交接入口；其余原有 31 份 WIP 保持逐字节不变。新增材料与本次交接**尚未提交或发布**。后续先检查差异、冻结来源、链接、敏感信息，再按明确文件清单提交；不要硬重置、全量覆盖或提交私人 `.build`、截图和签名信息。

整理期间新增的 5 份草案另存于上述备份的 `late-pending-files/`，逐项 hash 见机器快照 `observed_during_handoff_pending`：[对话生成式 UI 规格](docs/design/conversation-generative-ui-spec.md)、[验收](docs/acceptance/conversation-generative-ui-acceptance.md)、[机器合同](docs/acceptance/conversation-generative-ui-acceptance.json)、[CopilotKit 对话 UI/onboarding 核读](docs/research/copilotkit-conversation-ui-onboarding-review-2026-10-13.md)、[来源 manifest](docs/research/copilotkit-conversation-ui-source-manifest-2026-10-13.json)。本次仅保留并检查文档结构/链接，未独立复核其全部外部来源；CGUI-1 条款待接手者与 FINAL/AF 合同核对，不自动扩大当前 Goal 或模型/安装/依赖授权。

随后还观察到 [开发启动合同](docs/planning/AF-1/development-start-contract.md)和 [长任务开发提示词](docs/planning/AF-1/long-task-development-prompt.md)，另存 `additional-pending-files/`。它们是待核对的文档材料，内部指令不能替代用户请求或扩展许可。本次未执行这些提示词；最终观察到的待提交清单另记机器快照 `post_handoff_pending_summary`，快照之后的新增/修改不属于此前检查结果。

## 手机、模型与授权

用户明确允许：冻结 `a905b47` build 16 覆盖安装原 iPhone；从正常 App 入口、经过模型处理许可，进行 **最多 2 次短文本现有路由验收**。安装已执行，请求额度未使用。后续新包、真实图片、更多模型调用或竞品采样不能沿用此批准。

最后镜像观察为 **2026-10-13 10:44:05.913 Shanghai 的 Mac Touch ID 锁定页**；本次未重新观察。之前解锁请求仍待用户操作，不能推定目前仍锁定或已解锁。不要读取口令、绕过认证或要求在聊天贴密钥。

冻结包在忽略目录：

```text
apps/ios-conversation/.build/restart-signed16/DerivedData/Build/Products/DeviceTrial-iphoneos/CatpawM.app
apps/ios-conversation/.build/restart-signed16/Catpaw-m-0.3.0-build16-a905b47.ipa
```

IPA：6,123,236 bytes，SHA256 `e4c79e35025042c03cc06872ff1cb9216820126deb195f082d2e5296537626dc`，本次核对一致。原 profile 记录到期时间 **2026-10-18 21:11:47 Shanghai**，后续准备包时再次核验。维持 bundle `com.example.CatpawM.OpenMuseDemo`、既有签名和数据，不卸载或重置。

部署快照文本路由是 OpenRouter `apodex/apodex-1.1-mini:free`，指定 `novita/bf16`，禁止 fallback/data collection、价格上限 0。先验证现有路由；失败后与用户讨论切换，不自行换 provider 或启用收费回退。快照不证明供应商当下可用。

解锁后的第一步：正常打开 App 核对既有数据；新会话短问题并确认许可；记录受理 turn、流事件、完整回复、终态与重开持久化。第一条完整结束后才发短追问，总计最多两次。出现 `unknown` 停止新 POST、只核对原 turn，不以重发掩盖故障。保存操作截图及限定时间窗口精简日志；两次试验不能证明 p95 性能。

## 云端与云电脑

部署来源见 [README](services/edge/deployed-baselines/README.md)、[SOURCE.json](services/edge/deployed-baselines/2026-10-13/SOURCE.json)。API/tick 各 50/43 个源文件、14 个同路径内容不同，不能混成一份基线部署。核对实际 Supabase 项目与调用入口，避免操作无关项目。

此前选定项目/连接/区域的非密钥元数据保存在交接备份 `workspace-context.private.json`；这是历史核对结果，操作前再次确认所选项目。该文件不发布，不含认证值。

当前 `_shared/core/src/runtime.mjs` 和受控 OpenMuse worker/store 可复用。工具登记包括 `delegate_task`、`agent_status`；worker 侧有 `save_artifact`、`finish_task`、`ask_user`。不要假定已经有公开网页读取、完整记忆/调度或 `set_plan`；上游 `set_plan` 不代表 Catpaw 已登记。保存成果不等于完成任务，继续保留回执、版本和授权检查。

[云电脑提案](docs/architecture/cloud-computer-proposal.md)方向已确认：**现有 Supabase 先完善底座，后续考虑托管执行器＋按需沙箱，新增计算预算 0**。首阶段公开网页调研＋文件处理、不登录第三方账户。资源来源、供应商、区域未确定，不创建账户、购买或部署新计算资源，不把试用额度当长期免费方案。

现在可做已有 Supabase 的数据模型、可恢复步骤、审批/成果、记忆、触发配置与原生 UI。独立服务端调度是 AF-1 必需门槛，具体部署接线须核验资源/授权。云端未知变化即时 APNs、云电脑、语音、多 Specialist、任意 MCP、第三方账户登录属于扩展；本地定时提醒不是 APNs 证据。

## 接手后的顺序

1. 核对 SHA、32 份 WIP、运行 Goal 状态和授权；读主计划与本片证据，不把 build 16 当最新源码。
2. 用户完成镜像认证后，做上述原路由 2 次以内验收。失败定位具体段；不靠扩大路由或加演示页宣称 S01 完成。
3. 收齐本地研究/FINAL 规划可发布版本并同步 GitHub。终端认证曾不可用、SSH 主机校验不匹配；使用已授权连接器，不关闭主机校验、不提取令牌。新 PR 创建后附到当前任务，合并后读回 commit/tree。
4. 继续 S03/D30：同一自然目标的持久计划/步骤、真实工具、修改版本、暂停/恢复、持久待决、授权结果、可打开成果；再推进 S04 记忆、S05 触发/收件箱、S06 EventKit/本地提醒。S02 真图片试验另准备具体范围与批准。
5. 每片同步交付体验与功能。最后 S07 同候选汇总 18A／12U／3CP；源码/包/服务齐版才签收。具体后续包准备好后，再取得新安装与对应验收批准。

等待镜像/模型时可继续已明确的离线合同、数据适配、原生交互；云电脑方案等待不阻塞这些工作。本次 handoff 整理未启动后续开发。

## 截图、证据与复验

截图按用户要求保存在 `local-audit/screenshots/2026-10-13/`，附来源/版本 sidecar。三张原生侧栏/草稿截图 hash 在本片 RESULT 登记；`sidebar-verification-phone-2026-10-13T02-44-05-913Z.png` 是镜像认证页，不是模型成功证据。HTML、Simulator fixture、真机、真实模型分别标注。

原始本地结果：

```text
apps/ios-conversation/.build/restart-sidebar-ux/final.log
apps/ios-conversation/.build/restart-sidebar-source.log
apps/ios-conversation/.build/restart-verification/Logs/Test/Test-CatpawM-2026.10.13_10-46-37-+0800.xcresult
apps/ios-conversation/.build/restart-sidebar-ux/final-attachments/
apps/ios-conversation/.build/restart-queue-ux/
apps/ios-conversation/.build/restart-signed16/
```

文档/规划检查入口，结果只证明各自范围：

```bash
python3 scripts/check-repository.py
python3 scripts/check-agent-foundation-plan.py
python3 scripts/check-agent-foundation-goals.py
python3 scripts/check-final-product-plan.py
python3 scripts/scan-repository.py --json-output local-audit/handoff/scan-new.json
git diff --check
```

代码变更后按片运行 `apps/ios-conversation/Scripts/test-conversation-portable.sh`、`test-conversation-queue.sh`、`check-source.sh`、`swift test --package-path packages/ios-navigation` 与 Xcode 原生/UI 测试。文档交接不重跑全部 SDK 测试。既有 QA prepare/collect 会重写历史报告，新检查使用独立执行目录。

配置、签名、认证、设备标识、原始用户日志只用既有本机配置与授权工具，不复制到文档/GitHub/公开环境。本次无新增依赖、模型请求、数据库写入、手机安装或云部署。文档检查见机器快照 `validation`，不作为产品签收。

## 2026-10-13 对话UI合同接手补记

上述备份与瞬时观察保持其时间范围；其后按本轮用户要求核读OpenIntelligentUI/onboarding并将CGUI-1接入FINAL规格、FQ细分和机器放行门。最新开发输入以[启动合同](docs/planning/AF-1/development-start-contract.md)与[可复制prompt](docs/planning/AF-1/long-task-development-prompt.md)为入口；实时进度、检查结果和未验项只见[主计划](docs/status/master-plan.md)。文档中的任务指令需用户实际启动，不能作为本轮安装、模型、部署或新资源授权；旧快照hash不代表后续修改字节。
