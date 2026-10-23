# 小咪产品交付基线与主计划

更新：2026-10-12；本文件是唯一实时状态页。[对应spec](../product/conversation-first-delivery-spec.md)定义页面、4条用户故事、状态和API；[验收清单](../acceptance/README.md)定义测试，[一页用户说明](../product/Catpaw-m_Product_Delivery_Baseline_2026-10-12.md)是此次快照。

**最新真机产品验收FAIL，暂停R1放行。** 用户build13反馈连接待验证、发送慢、流式卡顿、后台回来断会话、图片输入缺失；天气问题得到重复任务进展和技术恢复提示。P0补为[连续多模态对话问题单MM01–MM05](../acceptance/r1-continuous-multimodal-issues.md)：即时本地响应、真实流式、前后台自动同turn续接、真图片送视觉模型、实时查询/不可用诚实说明。短CATPAW_OK不代表可用；既有一页是反馈前快照，不作为当前通过声明。

**交付目标：对话唯一主入口 → 自然形成目标/任务 → 可追踪执行 → 成果回到对话与收件箱 → 记忆可查看、更正、删除。** 不用手填委托表单替代自然任务，不新增独立执行状态机，保留现有黑灰/顶部入口/任务卡/阅读器设计。

## 当前已交与未交

| 范围 | 最新证据与验收 |
|---|---|
| 真实聊天/历史 | 真机连续对话产品FAIL；v13/v14短受控聊天/历史、CATPAW_OK及单次重开仅保留技术冒烟范围PASS。不能扩大为自然长对话、流畅续接、图片或实时查询通过；旧unknown不倒填 |
| 自然任务形成 | v14一次自然委派chat completed，唯一持久binding通过；原task仍running、step0、lease已过期、artifact引用0。已确认30s预算在授权/checkpoint耗尽，过期guard连结算CAS也拒绝，留下running；DB us-east-1/API本次us-west-1跨区，出现两次55P03。worker四文件候选独立离线20/20、无新增候选阻塞；未部署，真实恢复未执行。后端撤权收尾修复14495be已获[独立QA小批](../../qa/backend-finalization-p0/REPORT.md)合成review：来源撤权用例0过1失败复现，修复20/20，未发现该补丁合成层blocker；lease/权限/终态/unknown/幂等覆盖，真实PG与部署未验。受理PASS，执行/成果BLOCKED |
| 受控历史计数 | v12＋v13合计2；此前自然任务阶段新增1、累计provider准入3，当时未重发/手动tick/新建身份。用户新真机试用调用数未在本任务核验，不把旧3当实时总数/剩额度；后续复验按协调明确预算 |
| 手机 | 协调转交原生owner：build14已安装并启动，同bundle保数据，原生源码仅d9a897cc；本次文档任务未独立验机。保留build13真实产品FAIL，build14性能/图片/侧栏及后端P0未放行；安装不抵扣产品验收 |
| 体验修复 | 三补丁及9原生/50便携通过保留原测试范围，不覆盖新5个P0。原build13许可挂起缺稳定等待反馈已独立复现FAIL；冻结pending补丁独立便携7/7＋旧8场景8/8、最终Simulator XCTest 9/9（内含一个旧8场景聚合测试）、慢许可反馈UI 1/1，均为合成离线。详见[QA小批](../../qa/ios-dialogue-p0/REPORT.md)。生产scene/实际IME/即时savingLocal桥尚未接齐；设备100ms/主线程/后台5s与30s/真实弱网未验，手机build13产品FAIL与图片链阻塞不变；旧4/0/0记录不改 |
| 记忆/收件箱 | capture/基础端口存在；cloud-foundation-next新增20/20、合并83/83仅离线PASS，memory-port/slice/outbox未接入生产/原生，产品链NOT RUN |
| 持续执行 | tick更新此前取消，用户恢复tick批准仍待回复；worker候选20/20不表示获批或部署。恢复POST会推进原task且可能发模型，不能用GET/新chat绕过。无pg_cron/pg_net或独立云调用方，长期调度NOT RUN；session到期限制需单独可撤销任务授权 |
| 系统扩展 | APNs缺Apple能力/发送链路；语音、朗读、桌面/锁屏、Live Activity后置，不抵扣核心验收 |

手机安装/用户试用均已发生，当前阻塞是产品体验失败。不重复索取已有匿名/Auth/API/Deno设置许可，不以安装/9＋50或短标记抵扣真机反馈。

## 用户将看到的产品

| 页面/故事 | 交付形态 |
|---|---|
| 首页：对话（US1/R1） | 文字＋图片连续输入，即时本地回显、真实云流式和前后台自动续接同turn；恢复最后会话。普通问题直接回答，实时能力不足诚实说明，不用重复任务观测替代 |
| 自然短任务（US2/R1） | 用普通话提出目标，必要条件在对话补齐；持久binding后显示“已受理/进展”，真实成果后才能显示“已完成” |
| 持续跟进/收件箱（US3/R2） | 离开App后云端按授权继续，需我回答/结果回原对话及App内收件箱；未验可靠调度前不承诺无限后台 |
| 记忆管理（US4/R2） | 能看来源并记住、更正、删除；旧值/迟到job不复活。成果从对话或收件箱进入同版本阅读器 |

核心状态：消息draft→sending→streaming→completed，已发不确定→unknown→只读核验；任务受理→排队/运行→真实成果/succeeded，或等待我/暂停/失败/unknown；记忆候选→确认→更正/forget。消息完成不等于任务完成，暂停本机队列不等于撤销服务端任务。详见spec的状态/API表。

## R1–R3与具体下一步

owner沿用现有线程：API＝“验证 OpenMuse 原生接入契约”；原生＝“开发小咪 iOS 应用”；存储＝“建设服务端持久化与记忆”；QA＝“验收小咪原生功能”；协调负责批准/预算及产品签收。

| 顺序/切片 | 负责人和马上做什么 | 放行门槛 / 当前 |
|---|---|---|
| R1-P0 连续多模态（MM01–05） | 原生负责响应/选图/渲染/自动续接，API负责流式/snapshot/视觉传输与查询能力，QA按协调已重设计三线跑同真机连续场景 | 当前FAIL；先关5个P0并保留旧失败，再谈R1放行。不把图片推到R3扩展 |
| R1-1 原task执行恢复（A3） | 四文件候选独立离线20/20已交接；API/协调等用户回复tick更新/恢复POST及预算批准，批准后按同ID/撤权/过期/unknown与真实PG回归，不重发原chat | 未部署/未执行真实恢复；原task须有真实step→artifact version/hash→权威succeeded，不以跳过guard或假结算制造完成，保留原IDs/失败。当前BLOCKED |
| R1-2 成果落回产品（A3/B3） | 原生接权威任务卡/成果阅读器＋最小App收件箱，API提供同引用投影；QA验双入口/重开/失败 | 对话和收件箱打开同一已提交成果；不造假回复/进度。成果0时不开放假阅读器；当前未验 |
| R1-3 体验与手机（C1/C2） | 安装已过，原生/API/QA先关MM01–05；保留草稿/IME/主题/退出等旧回归，新增真实图片/长文/前后台自动同turn恢复和实时能力边界 | 用户真机产品FAIL；旧9/50不能抵扣新门槛，不能用技术恢复提示要求用户反复手动补救 |
| R2-1 调度与任务授权（B1） | 存储/API准备独立云HMAC/nonce调用方、可撤销任务授权及恢复/取消语义；批准前只做离线/只读准备 | App/Mac离线任务仍推进，重复tick不双执行；不得绕过过期session认证。当前NOT RUN |
| R2-2 记忆与原子收件箱（B2/B3） | 存储把已交候选接认证HTTP、有限重试抽取、buildContext与两个onCommit；原生接记忆管理/收件箱，QA验来源/更正/forget/迟到job | 真实PG隔离/恢复、删除屏障/outbox原子性、跨会话context通过；20/83离线不替代接线。当前NOT RUN |
| R3 系统入口/语音 | 原生在R1/R2后交桌面/锁屏、语音/朗读、APNs；先确认能力和发送链路 | 权限/中断/无障碍、恢复同task、不泄露正文；当前后置 |

三线按协调新分工推进，当前P0以MM01–05为产品门槛；原task执行/成果仍保留阻塞，存储R2离线准备不替代前台连续性。真实模型/视觉复验与恢复由协调指定执行者/额度，不重发旧unknown或改历史。

**R1产品FAIL，暂停通过判断：连续多模态5个P0、短任务成果/收件箱和最后体验须合并放行。** 技术冒烟/唯一binding/安装不能代替。R2/D01仍NOT RUN；R1前后台自动续接不等于iOS常驻后台或可靠长程调度，R3不先行。

## 复用与记录

复用[产品资产](../product/README.md)、[原生设计/截图](../design/README.md)、[tokens](../design/design-tokens.json)、[图标语义](../design/icon-semantics.json)、[成果/恢复样式](../design/openmuse-r3.md)；[旧整体设计](../architecture/server-first-delivery-design.md)及[记忆brief](../architecture/memory-brief-v1.md)保留原文，不再增写泛架构。冻结v1/r2/r3及LICENSE/固定commit/patch不变，活跃源码不导入。

此次当前事实来自原生/协调终态、NATURAL-TASK-V14-CHECKPOINT.json、experience-merge/PHONE-BASELINE-INSTALLED.json、云端基础审计及QA的dialogue-p0/worker-stall-acceptance报告；路径/IDs/报告与源码hash只在local-audit。spec是需求，用户页是带日期快照，当前进度仅更新这里。格式validator/succeeded不认证事实可靠性；新结果附部署/build、环境、精确case、调用计数、原IDs/hash及未验范围。本轮仅补充问题单和主计划，不导出附件，不执行模型、tick、安装或push。

## Native P0 isolated branch import (2026-10-12)

Branch `fix/ios-p0-conversation` starts at `b7fa4ee`; active frozen native P0 code imported under `apps/ios-conversation`, preserving historical v1/r3. Source provenance: `ios-p0-import-provenance.json`. Runtime public config and personal signing values excluded. Prior 14 native/9 queue/7 conversation tests belong to the frozen source task; this worktree has not yet run native UI/performance acceptance. Next batch wires immediate echo, scene recovery and local startup; no sidebar/model/phone install. Current product FAIL and physical performance/background/network/media gates remain.

## Native P0 bridge small batch (2026-10-12, isolated branch)

`fix/ios-p0-conversation` / `apps/ios-conversation`: frozen import `b733ec7`, local preview from prior verified workspace receipt while Auth waits (no HTTP admission), stable local message echo and atomic queue, native marked-text/CmdReturn guard, scene bridge wired. Final local26 native XCTest and4 actual offline Simulator UI tests PASS;9 queue/7 conversation Foundation checks PASS. Unsigned Keychain probe earlier failed -34018 and is excluded/blocked, not a passed test.

Measured20 Simulator action-to-visible-geometry callback proxies: p95 93.999ms, max113.349ms;1500 active callback intervals p95 40.895ms, max218.388ms,12 over100ms. Largest font case callback max899.943ms. These are real collected proxy values, not presented-frame proof; performance remains FAIL/NOT_MEASURED and product FAIL retained. Physical first-frame/Instruments, actual Chinese IME/VO, cloud continuation30s/network/media and reading anchor remain unverified. Actual Simulator Home5s recovered same synthetic turn with reply1/observe3, not cloud worker acceptance. Curated raw traces/source hashes: `../acceptance/evidence/ios-p0-native-bridge/RESULT.json`. Sidebars deferred to next batch; no phone/model/credential/signing/global selection changes.

Final safety guards also close admission before logout await, preserve pre-admission cancelled intents, and block conversation switch/new while marked draft active. They passed final26 native tests and final non-DEBUG iOS compile. The4 UI cases predate these final Model-only guards; same View/composer/probe hashes, accurate boundary recorded in RESULT.json. No performance acceptance inferred. Independent QA dc655574 old frozen gaps compared: current production scene/outgoing/marked-text bridges added, real IME/VO/savingLocal forced-delay rendering and physical gates still open.

## 独立 backend P0 来源快照

`fix/backend-p0-finalization` 从已提交 `b7fa4ee5f8d144208d51f6d0dcdee9259c4315b7` 建立独立工作树；导入冻结 dialogue P0 的6个修改生产文件、1个新增指标模块、test repository、lock 与8个合成测试文件。精确来源见 `services/edge/P0-PROVENANCE.json`；v14 source manifest、发布用本地config、上游及原worker字节保留。未纳入 worker-stall、长授权或新模型工具。

来源复现：本工作树离线 Deno、缓存依赖、禁网络下，dialogue P0 12 PASS / 1 FAIL；FAIL 是撤权后失败收尾再次触发 grant_conflict。仅记录合成回归；修复、真实PG竞态、云部署、真模型及MM01–05产品验收尚未执行。主工作区和原冻结包未修改；没有push/merge/tick。

本批次修复完成（独立工作树，未部署）：独立 `beforeFailure` 只对白名单中的已失效source/consent允许静态失败回执，运行租约/turn代际/scope检查仍强制执行；`fail` 在conversation锁后读取当前行，并在await写入后、事务提交前重新检查。terminal/已脱敏/已删除行不重写、不重复通知；原timeout/dispatched unknown不被改成成功或自动重发。

离线终态：完整8文件62 PASS / 0 FAIL，其中dialogue P0为30/30（原13项＋17项新增竞态）；Deno入口导入检查PASS。仅合成TestRepository/注入transport/离线driver serializers，未证明真实PG或多实例并发、部署、tick、真模型和产品MM01–05通过。修复及日志hash见 `services/edge/P0-FINALIZATION-MANIFEST.json`，复现及集成边界见[后端P0失败收尾验收](../acceptance/backend-p0-finalization.md)。


## 独立侧栏接入候选（2026-10-12）

`feat/ios-sidebar-navigation` 基于 `b7fa4ee` 新增零依赖 [CatpawNavigation](../../packages/ios-navigation/README.md)：根页汉堡/边缘打开、面板左滑/遮罩关闭、搜索/历史与任务成果入口、底部记忆设置、能力禁用和无障碍/Reduce Motion 代码。未写冻结客户端或活跃原生主线；由原生 owner 按现有路由接入。当前 12/12 SwiftPM 合成测试、全部源码 iOS SDK 编译和模拟器无安装策略检查 10/10 PASS，详见 [绑定源码 hash 的验收快照](../acceptance/ios-sidebar-navigation.md)。真实手势/VoiceOver/最大字号截图/延迟/触觉及主线接入 NOT RUN；不改变 R1 产品 FAIL 或任何云链路结论。

## 固定本地目录整合小批（2026-10-12）

`integration/local-fixed-directory` 从已提交canonical基线独立clone，指定iOS/后端/侧栏/QA七项提交均已本地整合；来源映射见[local-integration-source.json](local-integration-source.json)，实际入口见[根README](../../README.md)和[文档索引](../README.md)。未导入未跟踪候选/资产/tooling，不移动或改写owner源目录；侧栏仍未接宿主。主iOS generic Simulator无签名build PASS，当前固定目录对话7/7、队列9/9、侧栏12/12＋SDK library、后端禁网62/62 PASS；原生检查脚本的iOS编译/项目成员PASS，但现有本地化门槛99条命中、overall FAIL，保留待复核，不改生产文案掩盖。细节/源码tree/日志SHA见[固定目录验收](../acceptance/local-fixed-directory.md)。本批无装机、模型/云调用、部署或push；既有QA/设备结果保留输入边界，R1产品FAIL不变。

## 运行时研究归档（2026-10-12，文档小批）

固定目录来源HEAD52ee352。已保存[OpenMuse源码核验](../research/openmuse-runtime-source-review.md)和[OpenDot暂定评估](../research/opendot-runtime-assessment.md)，补[ADR-005](../architecture/adr-005-runtime-reuse-and-hosting.md)与[现状快照](../architecture/runtime-state-2026-10-12.md)。当前实际为vendored OpenMuse TaskWorker＋自研适配，保留SwiftUI＋Supabase；常驻worker vs Edge分步与框架迁移为Proposed，未Accepted。OpenDot身份尚未用户确认、composio候选许可未核验、未采纳代码。手机build14仅d9a897cc，不含侧栏/图片能力；后端P0未部署。代码/版本/用户可用性分别记账，测试数量不替代产品放行。本批只归档已完成研究和本地源码对照，不运行大测试、引入资产、改应用或push。

## 图片输入独立组件小批（2026-10-12）

`feat/ios-image-composer` 从文档commit a1fd7e8另建worktree，只新增[单图PhotosPicker/附件状态/安全编码组件](../../packages/ios-image-composer/README.md)，不改宿主/主Model/网络/生命周期。默认PNG、支持JPEG，异步缩图至v2字节/像素上限、方向变换/去元数据、缩略图/移除/失败保留/显式本地重试，发送gate默认关闭。16/16 SwiftPM合成、含PhotosPicker的iOS SDK library编译/链接、无安装Simulator codec和Git8ce固定v2纯validator两格式联调PASS，详见[验收与hash](../acceptance/ios-image-composer.md)。原生owner尚待实际接线；相册交互/VoiceOver/大字/实机codec/性能/真实图片路线MM04 NOT RUN，不改R1产品FAIL或后端部署状态。没有私人相册、真实模型、装机、部署或push。

## Native performance small batch (2026-10-12)

Original900ms callback gap reproduced before Send, independent main heartbeat661ms; XCTest AX startup contributes and unsymbolicated stack limits retained. No-XCTest same large4k autoplay confirms real App frame146ms/main163ms. Incremental TextKit/cache+50ms display/100ms scroll+token journal history filtering reduces standalone frame max58ms and main p950.81ms (baseline46.51ms), though max136ms remains. A per-character AX snapshot regression was fixed with single complete-text host AX. Final28 actual native tests and4 independent serial UI PASS; complete4096char label/Unicode/selection checked, nonDEBUG iOS build PASS. Overlap-induced earlierUI failure retained/excluded. No phone install/model/canonical write. Raw before/after, test identities, limitations: `../acceptance/evidence/ios-p0-performance/RESULT.json`. UI20 echo proxy max82ms/p9580ms; proxy is not GPU. Physical/GPU/realChineseIME/VO remain unverified; not an install candidate until sidebar/media/serverP0 integrated and QA gates passed. Sidebar host not yet integrated; image ownership/network boundary4343a4e ready.

## 2026-10-12 原生宿主集成阶段候选

独立分支 `integration/ios-composer-navigation` 基于固定目录 cc10a72；原性能 6e77d4e 导入为 be3605d，保留双方主计划记录。主宿主已接本地侧栏、实际历史/搜索、任务/成果/设置路由、系统返回和系统 PhotosPicker 的本地选择/预览/移除。范围与结果见[阶段验收](../acceptance/ios-host-integration-20261012.md)，逐文件/产物身份另存 RESULT.json。

实际 iOS 构建与原生 31 项、独立组件 12/16 项、可移植 7/9 项通过；最终 UI 与合成代理数据按阶段报告记录，真实发布仍未通过。v15 四项 GET 冒烟来源为 QA bd72ecc，实际 image_input=false；本批不请求模型或凭据。独立图片许可/v2发送/receipt、真实视觉与 terminal/cursor、真机呈现/IME/VO、30s/弱网/冷启动、阅读锚点仍待完成。本地化实际门槛 FAIL97 保留。阶段候选没有新装手机；按四项集成与六组验收放行后再安排安装。

协调随后提供视觉候选 bdb938df07aee583c7999a26b5517e5ae471aecd（基于 ae3b9c0，契约2758c6d）。原生已实际读取 contract 与50文件 manifest，后续批次按独立图片同意、非敏感确认和55天/人工审核披露接 v2；本检查点仍是 v15 关闭能力下的本地图片成果，历史验收不改写。

### 原生检查点交接回执

功能代码已提交 `b4850ebd71995253afbefec1229254cf8749e8e2`，前置性能提交为 `be3605dfcd11bd14b185bfe3ea61ed2ba4890d22`；worktree 保持独立。Library 工程包 `catpaw-m-ios-host-b4850eb.zip` / `libfile_a5df65db9828819187786bc8a3aca0a9`，ZIP SHA256 `11a5160361f2471847e1715a8f44a86b108c2147a1ea5ededd984d00a1aaa934`，5,621,842 bytes，153 文件源字节校验通过，本地 Library 身份已保存。

最终8项Simulator UI全部通过；仅DEBUG诊断面板后续隐藏在侧栏打开时，四项受影响用例复验通过，补验实际关闭按钮。非DEBUG源码行为相同，实际重新构建产物身份记录在阶段 RESULT。31项原生逻辑、12/16包策略/编码、7/9可移植回归通过；97条本地化门槛与排除1项Keychain用例保留。无新手机安装。

新视觉候选已通过Git对象字节核对：bdb938df07aee583c7999a26b5517e5ae471aecd 的50文件图 SHA `db57d9e2bbc1d90c51fbcfe36c2c2f220d8390e33ffb773ef18afe24a33579c2`。协调随后告知已部署v16、live开关待用户设置；本线程未请求现网或读取凭据。原生下一批仍需独立图片同意/非敏感确认、v2不可变附件、严格admission/provider回执、accepted/unknown只读恢复与失败保留图；当前检查点仍关闭图片发送，不能声称真实视觉完成。源码检查点不等于六组真实发布放行。

## 2026-10-12 Native vision chain 30-minute checkpoint

Based on b6ad8d6: independent image approval/non-sensitive checkbox, exact preview/caption/scene fencing, local image byte queue, v2 HTTP preflight/body and strict admission/provider terminal receipt, original-turn unknown recovery. Actual latest iOS XCTest 40/40 PASS (9 new boundary cases), explicitly injected offline backend. New image UI resources added; localization remains FAIL97 owned literals. See [source checkpoint](../acceptance/ios-vision-chain-checkpoint-20261012.md).

Coordinator latest deployment is v18 (Buffer runtime fix, QA3170f2f), vision disabled pending flag. Native reads live capability and refuses unavailable images. HTTP synthetic wire, actual image consent/Send UI, Home5s/30s/full App restart, localization/reading anchor, physical presentation/IME/VO and real synthetic-image provider receipts remain required. No phone build14 overwrite; full installation acceptance remains BLOCKED.

## 2026-10-12 Nested vision readiness protocol fix

QA URLSession/TCP report 56879b6 confirms root vision_contract lookup blocks the published nested shape. Native now decodes chat_capabilities.vision_contract only, requires ready/image_input/v2/available together, and fails closed for missing/malformed/unsupported fields. No server root alias is used. Foundation production-shape regression 8/8 PASS without Simulator use. One direct public readyz observation independently confirms the nested path and disabled image state at its recorded UTC; no credentials/model request. Evidence: [RESULT](../acceptance/evidence/ios-readiness-nested-contract/RESULT.json).


## 2026-10-12 Native build15 frozen candidate

Final feature source frozen at `4750142e9999bcf39a2231bd321169fe73e5e014`; nested contract-only fix `be60f24aaf8ebfb34666c8e3d5a5226fe04ee83f` is independently ready for QA. Main login/conversation/settings, image disclosure and shared native widgets now bind locale; strict gate630 lookups/653 bilingual entries/zero owned gaps, portable8/14/7/9 checks PASS. Same-commit nonDEBUG generic iOS device build15 plus source/project check PASS. Actual final iOS43 native PASS,3 explicit harness skips and1 separately excluded Keychain; actual main UI4/4 PASS, including system PhotosPicker owned synthetic preview/cancel/remove/closed gate. Details and identities: [dated acceptance](../acceptance/ios-final15-20261012.md).

Public readyz at recorded UTC remains image_input=false/vision schema2 available=false state=disabled: live flag is the explicit external blocker. Normal image approval/Send/real provider semantics are NOT_RUN. Independent QA bde470dc e5 unknown text Home5/30/cold3/3 retained, not final-source or active-stream proof. Final wire/lifecycle confirmation and physical/weak-network/IME/VO/reading-anchor gates remain. Original iPhone13 connected, same valid signing/profile verified; build14/data untouched, no new identity or installation. Product release/phone overwrite BLOCKED; candidate/source frozen, no further design expansion.


## 2026-10-12 Signed build15 and v19 capability update

Frozen4750142 source was built from a fresh Git archive and signed with the same original cached certificate/profile/entitlements; no new signing account, profile, permission or provisioning update. NonDEBUG DeviceTrial0.3.0(15) build and strict codesign pass. IPA22 App files/CRC verified; Library `libfile_5266b37675588191830e1fad1c867046`. Identity, hashes and preserved setting failures: [signed handoff](../acceptance/ios-signed15-v19-20261012.md).

Public readyz at2026-10-12T15:58:55Z now confirms image_input=true/schema2 available=true/live_configured; coordinator/backend attributionv19. Older disabled evidence is historical, superseded; no live-flag external blocker remains. Validation stillcatalog_only_until_real_fixture. Phone remainsbuild14/data/login untouched: latest instruction defers overwrite until real-chain release. Normal existing-login App independent image consent/explicit Send and actual provider/receipt/pixel semantics remainNOT_RUN. No model/Auth/tick/token export or new identity in signing preparation. Package ready; product acceptance not claimed.


## 2026-10-12 Physical build15 test-candidate installed

Latest user explicitly authorized installation for testing to remove the install-before-test cycle. Same signed frozen4750142 App actually installed over iPhone13 and normal launch succeeded; physical inventory now0.3.0(15). No uninstall/data reset/account/profile/permission change. Private screenshot verifies prior conversation restored and text consent alert waiting; no grant/Send action performed, no private screenshot published. [Installation receipt and exact remaining scope](../acceptance/ios-build15-install-20261012.md).

QA5485aa31 fixed475 actualTCP/URLSession wire8/8 PASS is now committed; its model/Auth0 boundary retained. v19 capabilitylive_configured; live flag no longer blocked. Normal physical App real synthetic-image E2E remainsNOT_RUN: current tools lack reliable physical tap/type/photo interaction, no existing device test runner and only original App profile cached. Existing AX trust inspected without prompt; no new system permission/profile to bypass constraints. Phone candidate installed and running; model calls0; live provider/receipt/pixel semantics and broader product gates still unverified.
