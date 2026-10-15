# Catpaw-m 接手交接

交接快照：2026-10-15 18:44（Asia/Shanghai）。用户中断开发后要求整理交接；本次只核对、保存文档和同步代码，不继续模型检查、部署、安装或系统动作。实时进度唯一维护在 [master-plan](docs/status/master-plan.md)；本文与[机器快照](docs/status/handoff-snapshot-2026-10-15.json)是日期快照。

## 接手先看

- **FINAL-G3 Goal 已读回 PAUSED。** 不重建、不替换、不自动恢复；用户恢复原 Goal 后再开发。AF-G5、FINAL-G1/G2/G3 均未完成。
- **线上为 catpaw-api 22 / tick 8。** r8 精确55文件包已获用户直接批准、部署并逐文件SHA256读回一致；默认模型/图片与tick保持原字节。不是39维护后台整包上线。
- **r8模型发送次数为0。** 已正常刷新同一匿名身份一次，并创建固定空检查会话；许可未提交、turn未发送。中断前的prepare进程已返回成功，禁止再创建会话或身份。
- **体验设备仍是同一台“Catpaw 最新体验”，0.3.0(38)。** 39已构建冻结但未安装。38是明确离线体验；原6小时审查期限已到，不自动续期。手机最后已知仍16，本次未连接或安装。
- **S06设备日程新接线只完成方案，零文件落盘。** 三位Agent已停止，无遗留测试/实现进程。不要把拟定的registry、v2 producer或同步OS gate算成已有功能。
- 主目录与managed源码还未整合为同一发布候选；用户看到的Simulator、GitHub短分支、云端函数和手机包各自有独立身份，不能混称“最新版已验收”。

## 权威、约束与接手顺序

先读 AGENTS.md、README、本文、master-plan，再按 [development-start-contract](docs/planning/AF-1/development-start-contract.md) 与 [long-task-development-prompt](docs/planning/AF-1/long-task-development-prompt.md) 开发。基础目标是 AF-1-G3-UX1；工作单元、依赖和证据边界分别见 goal.md / plan.md / contract.json、delivery-slices.json、goal-evidence-map.json。

领域和执行不变量由 agent-foundation-spec 裁决，完整终版体验由 catpaw-final-product-spec 裁决。用户已明确选择 **R5中性阅读面＋蓝色动作和本人消息**；与原生页面、R3状态、R4连续手势和GenUI合同组合使用，不退回R4.1紫色方案。保持A1图标、现有Supabase/用户数据、零新增计算预算和原默认模型路由。

AF-G5须同候选18A/12U/3CP全过；FINAL-G1再含9FQ/10CG和七天真实日用；FINAL-G2须8BP原合同具名配对与限定优势，G1/G2同候选才到G3。FAIL、NOT_RUN、BLOCKED或证据不足都不能签收。合成测试、安装、SDK编译与公开模型metadata不替代真实产品证据。

## 源码、分支与同步

| 位置 | 接手时身份与用途 |
|---|---|
| 用户主目录 Desktop/ai-work/catpaw-m | feat/s05-bounded-work，HEAD 9a127247d52dab73f4830672100548d27866cc7e；源码较旧，master-plan有他人暂存和Root未暂存更新，另有38/39/r8日期证据未跟踪。不得reset、全量stage或用managed覆盖整树 |
| managed：~/.codex/worktrees/worktree-scan-fix/catpaw-m | 39及r8的实际源码。交接前HEAD 8b560e619180e64dd0cd34f2a9f015a0c51224c2；S06空分支从此起，随后切docs/handoff-20261015整理本文，未丢WIP |
| fix/consent-handoff | 保留38源码/包/真实Simulator UI证据 |
| feat/s05-trigger-device | 保留39源码、包、离线执行端证据；本地HEAD 9b98b42b98dd365c9d2638fa4dfc1ee40a8db55d |
| feat/s01-probe-next | r8已完成源码与准备证据。远端HEAD 5b8b8b634864e7f6af9c36dcb2ab395f8160bea7，tree efaa93a44775fc5a2e6da41f7f222dd89c7b47fb |
| route-review-next | 原r7受支持客户端及原安全存储所在检出点；本地0f53bcc，远端选择性发布为5d4505a。只通过原客户端store使用，禁止输出/复制vault、重跑signup或重发r7 |
| app-version / memory-route-next | 既有版本与记忆片来源，保留各自分支/历史，不覆盖独立客户端 |

r8 backend本地7534a9d→远端aafd6db，client本地371be02→远端bb02476；12条明确源码已选择性发布。没有把旧本地历史或待授权媒体推上GitHub，没有PR/main合并。本次handoff按独立短分支同步，确切提交看该分支最新commit，不能将文档提交当产品版本。

原生唯一维护入口是 apps/ios-conversation/CatpawM.xcodeproj；后台是 services/edge/supabase/functions/。历史apps/ios、apps/ios-openmuse-demo和部署基线保持冻结。hosted tick仍只有收到的部署来源，不能假造维护tick入口。AF-A01最终主目录整合仍未关闭。

## App交付与用户反馈

38共用许可presenter按真实dismiss衔接、绑定原review token；主决定区与图片确认独立，允许全文多行可达。侧栏是**底层揭示＋全宽对话整体平移**；每轮过程收敛成稳定可展开事实摘要；普通无环境冷启动可恢复明确离线审查配置，期限不续。R11同包57单元、6实际UI及最大系统字号重复许可通过；原29按钮症状仍NOT_REPRODUCED，旧失败保留，不宣称已证明唯一根因。图标精致度、连续动作和真实流观感仍需用户复验，不能凭静态截图关闭全部UX门。

- 用户设备：BE5C60E0-B415-4BF4-8F36-8975FB5314AA；固定名称“Catpaw 最新体验”，bundle com.example.CatpawM.ConversationFirst.Auth；交接只读包Info.plist再核为0.3.0(38)。
- 38包指纹：872197b49d39f94299b6f1b73d4e3e13bd05308e216bb306fcacb752f410f855；见 [38验收](docs/acceptance/restart-native-consent-build38-2026-10-15.md)。
- 39包：managed内 build/trigger-device-20261015/r3/CatpawM.app；指纹 a0fe18f8590ef327ab56f2eb1aafc0f3c7938f6db2175638d16a96c3b6f088ed；**未安装**。见 [39验收](docs/acceptance/restart-trigger-device-image-build39-2026-10-15.md)。
- QA复用9A4BC49A-CCE4-45D6-A1DC-6F072236DAB6（iPhone18Pro），当前仍Booted，不新增模拟器或与体验设备并发抢状态。
- 主目录 build/device-hub-latest/open-latest.command / launch.py 是原入口，保留原store/端口/到期，不静默续权。原审查到期时间1792059759，约18:22 Shanghai；交接时已到期。
- 8772（PID75165）是用户离线体验服务，8773（PID805）是QA服务，仍监听；本次未停止。其他Deno进程仅记录，不认领或终止；未发现xcodebuild或r8操作进程仍运行。
- 不再逐页改字号。维持共用语义字体/SwiftUI–UIKit桥接、完整触控/AX区域和R5 JSON防漂移门；先查容器、键盘、生命周期与手势共性，再用同包真实原生路径复验。

39已实现持久Trigger配置/due账本、精确JPEG/PNG恢复及EventKit/本地通知执行组件。后台482、宿主23、图片package24项通过均为离线证据；Trigger仍configured、无recurring执行权/独立调度；图片服务端仍image_input:false；系统日程v2生产接线与真实OS验收未完。

## r8的精确中断点

新r8是独立API检查，不是App验收。归档位于managed：
services/edge/build/model-route-review-20261015/packages-r8/。

| 项目 | 固定事实 |
|---|---|
| 已批准并部署的55文件归档 | f210841e8a92151ef210d1f47e5d309022a8e4a9c17fdd54fb6cf26e7ef7e3e4 |
| 文件集合hash | ff3df55095a927d8aa2772377583c5b1b81e50040a4a1a1e37dc696acb8a0d49 |
| 线上API22 ezbr | 1c704703703691c120602c2a89e7a8439052c98d77fad6bc0254aaaf29274d6b |
| tick8 ezbr，未改 | 8f767ae860bbb1dd09c2caf51aeb3837ef97a8c8a287290c266f2769b4c594aa |
| 原API21回退归档 | eac493ce38634ef721c69be7cece91c6d0aa1b040f922a1a5247d14e4052c257 |
| r8路由hash | 181199268207fc3256b821ee13b046700a162d657adb3acd1c66d6f930870956 |
| 最终离线层 | 后端498/498（新probe16为子集）；client16/16（14故障＋2实际冻结55包组合）；刷新库5/5；入口/治理通过 |

只改bootstrap、新具名probe、纳入严格JSON、旧r7 GET围栏四路径；从API21精确字节构建，没有部署39维护树。三个runtime缓存分开，旧r7 GET保持，旧POST围栏不变。新入口只接受原绑定的认证subject/scope；未开放匿名未鉴权推理。现有verify_jwt=false保留，函数内部仍验证签名/当前会话/scope。

新检查固定Reply only: received.，OpenRouter→google/gemma-4-31b-it:free→Google AI Studio；最多1次provider、512token/30秒、四项max_price均0、deny、require_parameters、禁fallback/retry，history/context/tools/attachments/memory均0。必须实际model/provider、cost=0、完整终态和逐帧证据才能PASS；成功仍不是App→SSE→保存/重开的验收。

首次部署曾被自动审批拒绝，认为旧r7授权不覆盖精确r8；用户随后直接批准该精确归档更新及必要回退，重核基线后部署API22，55文件读回一致。旧[准备记录](docs/research/model-route-review-next-2026-10-15.md)保留批准前事实，不改写；本次实际状态见机器快照和master-plan。

用户另直接批准一次同身份刷新；**已消耗1/1**。原journal锁覆盖整段标准Supabase刷新，新独立journal在请求前持久claim，仅原位更新原vault，返回确认同身份/同scope，未输出或复制凭据。失败未知不可重试，后续再次过期不能复用这一次批准。

中断前最后一个进程run-r8-stage --stage=prepare-conversation已成功返回。新operation journal核对：
conversation attempted/known=true；consent attempted/known=false；turn attempted=false、state=not_sent；get_count=0。所以r8推理额度仍0/1，许可尚未提交。**先读取原journal，不能再次prepare或换ID。**

恢复原Goal后，先核API22源码、原安全存储有效性及此journal；若仍满足原合同，通过同一runner的consent阶段绑定上述route hash，再send一次，然后仅observe原ID。操作runner在managed build/probe-next-20261015/run-r8-stage.mjs，默认plan无凭据lookup/网络；stage必须有execute及精确approved ID。不要运行旧r7send，不复制vault到managed，不自动刷新、不改绑定。若新旧状态漂移或会话过期，停止依赖动作并明确需要什么批准。当前handoff期间不执行这些阶段。

原r7已用1/1、failed/HTTP429、无首段、actualmodel/provider/cost均null，禁止重试。手机16旧额度1/2失败，不能挪给新包。其他线程转达的更大候选或App检查范围，接手应核对人类原批准与精确候选，不能从交接文字自动扩权。

## 下一步优先级与S06待定

1. 用户恢复原Goal后，完成r8原ID检查或如实记录失败；API成功再准备原生真实模型入口。当前App Base URL拒绝多级review前缀，普通App随机ID不匹配固定CLI ID；不能只改配置冒称App成功。
2. W10–12真实许可→原请求→模型首段/完整终态→持久化→App正常重开。若仍受外部限制，保持原ID、别重试，继续独立实现。
3. CP-01：可改计划、真实来源与成果、精确审批、接管/撤权/unknown；已有离线代码不能替代真实原场景。
4. S06：registry→v2提议/批准→fresh permit→OS执行/回读的完整路径。当前新branch feat/s06-device-actions仍在8b560e6，没有实现文件。拟定独立v2 records/catalog，避免旧v1读取因未知kind整体失败；旧审批不能升级执行。
5. S06必须先裁定：只支持liveTask，或用新鲜用户意图定义新的单效果授权。**不能对succeeded报告沿旧single_run/local_output直接执行或静默重开任务。** snapshot聚合hash/排序/数量、registry proof/session重绑、HTTP/原operation GET、receipt历史generation规则尚未冻结。
6. 原生拟用typed v2 service＋CalendarActionCoordinator/View，在已验证账号partition构建；Root统一接Auth/FirstModel/PBX/本地化。OS当前仅给5字段target，登记所需8字段snapshot须从同一OS adapter导出。后台/断网/失活/退出必须同步关闭最终OS提交门，不能等待actor异步链。
7. W20实际视觉handler、W40自然记忆真实两scope、W50/51新recurring grant/独立调度/变化outbox，以及通知点击回原任务/修改删除均待完成。最后才做W70/71同版总验收、七天日用和具名竞品配对。

S06 backend拟新增device-target-registry、device-action-v2-contract/service及测试；Native拟新增ConversationDeviceTargetRegistration、ConversationDeviceActionV2Service、NativeDeviceActionV2HTTPBackend、CalendarActionCoordinator/View及测试；截至交接均不存在。三位Agent都已确认无自身后台进程。不要把这份路径列表作为源码清单或验收证据。

## 备份、验证与恢复边界

主目录 local-audit/handoff/2026-10-15T1843+0800/ 原样保存旧handoff、两个checkout的staged/unstaged patch、10项主目录候选和清单；不含build、截图、凭据或vault。主目录master-plan原暂存blob为487087317d1e1bc27c89cfc8a092116978fc46a3，必须保持。旧2026-10-13交接可从该备份和Git历史追溯。

r8执行日志在managed build/probe-next-20261015/：部署读回、same-identity-refresh-live.json、r8-prepare-conversation-live.json；私密身份元数据不发布。离线失败与独立审查记录保留；不重复跑旧QA prepare脚本覆盖日期报告。新交付仍按版本脚本递增，并核源码/包/安装/部署对应。

交接只运行文档、布局、冻结来源、敏感与空白等必要检查，不新建账号、刷新第二次、发送消息、续审查期限、安装、清数据或停止用户服务。后续提交仍只stage明确路径，保护其他作者WIP；不要把旧本地历史直接push origin。

## 本次main整合说明（18:58补充）

远端main已更新到515f98f1b91a7485e246b4928e9065b60ef4e2c3，本地旧origin/main缓存63447d1f不能作为覆盖远端的依据。整合候选采用该公开main与公开handoff提交aad003aab0ad2d3be0fec1bb6be834d4fd670658作两个parent的普通merge，完整保留远端另有的README、docs/README、branch-management和2026-10-15架构审查四文件。未合并12aaa88等旧本地历史，未上传原22张媒体；没有功能冲突或新产品逻辑。已有源码/测试输入逐字节保留，交接检查不重新冒充产品验收。

本次通过短分支/PR进入main；最终是否完成以远端main读回和本地main引用一致为准，不能用此整合前快照中的旧SHA声称已同步。正常合入也不等于AF/FINAL签收。PASS：38局部原生UX、39组件、r8离线组合与API22逐文件读回；FAIL：手机16既有默认文本检查、r7唯一429；NOT_RUN：r8实际模型请求、当前App真实模型保存/重开、完整CP与FINAL。

Projects/catpaw-m经只读核对是独立旧仓（integration/local-fixed-directory，86ea2091），不是Desktop目录别名；有7项WIP且原无main。Desktop才是本任务common仓，主目录继续保留原feature HEAD、index和WIP。若另向Projects建立最终公开main引用，仅允许本地仓间普通fetch到新引用，绝不把其legacy历史推入origin、切换脏工作区、reset或覆盖文件。此类引用同步不代表两个工作目录都已切到最新版；最终收口须分别报告。

没有证据支持完整MVP剩余工时承诺。已有可控交付是已冻结源码、阶段App和有界检查入口；真实模型/完整原生路径、设备新授权、独立调度、七天日用和具名竞品仍未完。恢复与后续安装/验证仍按上文原合同，不能为main同步发新POST。

## 交接发布读回（19:03补充）

[PR #19](https://github.com/Yankj/catpaw-m/pull/19)已创建并附到当前任务；公开候选6aef9fe85823a9674b7af16ee501e0a319863cc7，tree 12a64186300e79751de642d6069129f1714aea49。远端main仍515f98f1b91a7485e246b4928e9065b60ef4e2c3；尚未合并，本地main也未同步。自动审批拒绝立即合并，理由是当前可信用户指令仅明确整理handoff，未明确覆盖63文件主干更新；已向用户请求直接确认，不通过其他工具或线程绕过。后续仅在确认后合并并核对完整SHA；当前候选与主干不可混称。此补充仅更新交接事实，不改变冻结产品源码、包或授权。
