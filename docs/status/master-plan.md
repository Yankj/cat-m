# Catpaw-m 重启 Goal 与交付计划

更新：2026-10-15；唯一实时状态页。旧主计划完整保存在[2026-10-12快照](master-plan-2026-10-12.md)，旧失败与证据边界不改写。16:07交接事实与待提交文件见[handoff](../../handoff.md)和[快照](handoff-snapshot-2026-10-13.json)；快照不另维护实时进度。

**当前长期Goal：FINAL-G3；2026-10-15 12:15 Shanghai最新读回控制器ACTIVE，基础执行合同保持AF-1-G3-UX1。** 控制器updatedAt=1792037734；10:52的usageLimited保留为当时事实。用户恢复后Root与三个内部Agent继续独立片，没有重复建Goal、擅自暂停、替换或标记完成。build24/25已分版本交付；26/27已完成新源码与Release模拟器构建，均未覆盖用户25。长期目标、零新增计算预算和全部验收门保持。长期目标是可日常使用的Swift优先、iPhone体验优先通用主动Agent：自然对话交代目标，查看/修改计划，找回审批，离开后继续已受理工作，回来查收有来源版本、可修改成果，并管理记忆、持续跟进和本地日程。[基础定义](../planning/AF-1/goal.md)与[开发入口](../planning/AF-1/development-start-contract.md)／[长期prompt](../planning/AF-1/long-task-development-prompt.md)共同约束执行。

2026-10-14本聊天先读回运行Goal为空，核对既有合同与交接后按用户本次明确指令建立一个FINAL-G3长期Goal；未重复创建或替换现存运行Goal。2026-10-13 16:06的`usageLimited`保留为交接日期事实，不作为当前运行状态。AF-G5须同候选18A/12U/3CP全部通过；FINAL-G1再含9FQ/10CG与七天真实日用；FINAL-G2依8BP原合同完成具名配对并证明限定优势，两者同候选成立才签收FINAL-G3。必需FAIL/NOT_RUN/BLOCKED或证据不足不能算完成。现有Supabase、模型路由、A1和用户数据沿用，新增计算预算0；云电脑仅公开网页调研＋文件处理提案，托管实施待资源/区域/供应商确认。

需求：[AF-1 spec](../product/agent-foundation-spec.md)；验收：[AF-A01–18与AF-C01–03](../acceptance/agent-foundation-acceptance.md)；执行切片：[delivery-slices.json](delivery-slices.json)；云电脑提案：[Proposed](../architecture/cloud-computer-proposal.md)；接手：[handoff](../../handoff.md)。

终版产品方向与验收已整合为[FINAL-1规格](../product/catpaw-final-product-spec.md)、[质量／具名优势验收](../acceptance/catpaw-final-product-acceptance.md)及[交互状态提案](../design/prototypes/catpaw-final/index.html)。本次运行Goal按用户明确指令追求FINAL-G3；AF-1-G3-UX1继续裁决基础交付，文档更新或合成片交付不关闭运行Goal。

| 终版目标 | 当前证据与判定 |
|---|---|
| FINAL-G1 日常可信体验 | 合同已制定；原18A／12U／3CP＋9项FQ＋10项CG对话细分需同版真实证据与7天日用；NOT_RUN |
| FINAL-G2 限定竞争优势 | 8BP固定具名版本、输入与配对规则；尚无竞品配对测量，NOT_RUN，不能称优于 |
| FINAL-G3 终版产品签收 | 依赖G1/G2同候选；NOT_RUN，设计/静态检查不关闭产品目标 |

## 当前执行片与下一步

2026-10-15 12:15三路并行完成[build27同任务有限改稿片](https://github.com/Yankj/catpaw-m/blob/feat/s03-revision-work/docs/acceptance/restart-revision-work-2026-10-15.md)：修复通过“离开后继续”受理的报告完成后不能交给Agent改稿的CP-01缺口。每次明确新确认绑定原Task/run/成果版本、原文、来源目录、期限与预算；新计划、操作、grant/due和回执同事务，复用既有TaskWorker/records/许可算法。当前授权selector统一模型/来源/结算/控制，新session自动有界唤醒和恢复接回原操作；旧请求、额度、成果及回执不改。新上下文和记忆快照进worker；unknown只GET，不续期、不重发。来源任务的确认范围锁定服务端catalog，旧manual.editable与新的明确授权不混用。

维护后端最终444/444离线PASS（20新HTTP、19合同、12grant、8来源授权），Swift合同86／3组含字母UUID维护golden、8组应用服务、实际URLSession/SSE23断言／3次明确POST=3POST通过。旧对话52、队列16、wire94／36明确POST回归通过；最终完整SDK、114成员、1086双语、Release 0.3.0(27)编译链接PASS。20文件包指纹7c9895377b619466a365cf39a60fe826286ac3fee717dc4f739ec82e5d4b595c；402输入SHA与独立远端Git索引逐项一致。本地源码261729d890e9c349e1ed6b71b3357c2c8849acaa；46文本路径已推4c7a6b87d9a7173c911a9073a351e081fa2ac457，remote tree d6b3e782d9988fa9ad70c8eaa95ec8c3287a54b1独立一致并读回；日期证据同分支收口。复用worktree-scan-fix检出点，短分支feat/s03-revision-work；primary仍24源码，memory-route-next仍用户25。

独立审查与actualwire修复能力字段不一致、来源范围默认错误、新上下文丢失、fallback少冻结intent、新session唤醒，以及Swift两个UUID大写导致outer哈希拒绝。含字母UUID与实际维护回放补盲；过期/撤权/删除源统一归执行围栏，损坏不吞。SDK r1仅末scanner不识别ui(ternary)（两文案已catalog），改分支显式ui；廉价project/资源门前置编译，不再散改字号。所有失败、修复前wire和冻结清单保留。此片未动Simulator/8769/8770/用户数据、无Auth/真实模型或PG/部署/安装/媒体上传；build25继续可点测，API21仍旧批准包，r7唯一429请求不重试。尚无本片原生UI/大字号/VO/运动实测，不关闭CP-01或AF/FINAL。

下一片优先补跨会话收件箱：原会话已自动读取原任务，切到另一会话或冷启动后仍需全局查收入口。并行推进W33现有授权接管/unknown边界及可独立离线的GenUI、调度与日程合同；独立调度/变化跟进、真实系统日程、同版模型/PG/手机、七天日用和具名竞品门继续未完成。部署/扩大真实检查/手机安装先固定具体候选与清单，再按既有授权执行；Goal保持ACTIVE。

2026-10-15 11:28三路并行完成[build26对话记忆接线片](https://github.com/Yankj/catpaw-m/blob/feat/s04-conversation-memory/docs/acceptance/restart-conversation-memory-2026-10-15.md)：在已有source/job/candidate/guard/generation与聊天事务内，把当前可信用户消息精确job接到现有模型工具。仅inferred/proposed，确认沿原记忆页；受理只冻ref，不占普通回答lease。完整模型终态后精确claim、候选/job结果/回执同tx，最后再核许可/源/代次。显式header仅协商客户端能力，旧工具与admission hash不变；重复候选在Foundation共有集合去重，修复两项独立审查P1。

维护后台385/385离线PASS（10新HTTP＋14新seam）；Swift便携对话52断言、记忆typed合同/22负例、原生HTTP/SSE94断言/36次明确POST、113宿主成员与1077双语PASS。Release 0.3.0(26)实际编译链接PASS，20文件包指纹21eb66692f329d1c361b01a59b2c309497bd7c9da626bc3e5bdbcc538a6e1f97；387输入与独立远端索引逐项一致。源码本地bd06a2f551d27c6cfe23d2ba63f1e7b9b532351e，24条文本已推83466ffa83f5b024cee27ded631decb5294bcb0b，远端head/路径读回；日期证据在同分支收口。

本片复用worktree-scan-fix检出点，分支feat/s04-conversation-memory；主目录仍24，memory-route-next仍交付25。用户继续在已有Catpaw-r5-conversation-qa体验25，本片未安装/启动/重置模拟器、改8769/8770会话或用户数据，无新增Auth/模型/部署/媒体上传。原HTTP缺接线、重复回执、SQL顺序断言、wire缺Node路径和Root误加文案到AppIntent表的失败均保留，修复后分项/最终结果按日期记录，不再散改字号。

自然语义、真实PG多实例、AF-A11两会话/两scope与原生完整UI仍未验，不关闭AF/FINAL门。r7唯一真实请求429已耗尽授权，API21/默认路由及隔离绑定保持，不重试或混入W40数据合同。接下来收用户25反馈、继续W10–12真实阻断审查和CP-01；调度/跟进、系统日程按依赖推进独立片。新部署/真实检查/手机包先冻结具体候选与清单，再按已有授权执行。

2026-10-15 10:49交付[build25原生记忆阶段版](https://github.com/Yankj/catpaw-m/blob/feat/s04-memory-lifecycle/docs/acceptance/restart-native-memory-2026-10-15.md)：候选`AF-W40-NATIVE-20261015-25-R6`，0.3.0(25)已在已有`Catpaw-r5-conversation-qa`（BE5C60E0-B415-4BF4-8F36-8975FB5314AA）安装/启动并恢复系统large，Device Hub已选中该设备供用户点测；左上菜单→记忆可明确开启、审阅保存、看原来源、更正、忘记及恢复草稿/原命令。原build24设备/包和8767/8768保持，W40仅用8769/8770。按用户复用要求，固定这两台已有设备，不按每次测试新建；Xcode关闭并行测试，复用DerivedData与test-without-building；25启动脚本默认resume保留同客户端、完整包一致则跳过重复安装。实际work/resume同客户端，启动前后命令POST 7→7、provider 0→0，不自动填发或续原会话。脚本位于已附着的独立`memory-route-next`维护工作树内`apps/ios-conversation/Scripts/run-simulator-review25.sh`，主目录仍保留24输入，不能误称主目录已切到25源码。

同一30文件产品包hash=`7bbf2741c12ddf7753f665d210513c3efd009af75bb6b6ba1422b4300a92138b`；7项新记忆宿主、6类35项受影响服务宿主、默认/实际最大辅助字号与可见稳定软键盘/unknown原ID恢复3条原生UI分轮PASS，后台361/361离线、non-DEBUG SDK、113宿主源成员与1071双语PASS。384固定源/辅助输入与包清单、分轮日志hash和8张本地PNG/1份几何文本见该分支日期RESULT；没有把混合r2整轮中断或r3默认失败标为PASS。r1声明编译失败、r3编译中输入被改、r2夹具transaction重载遗漏/state500/143、预测条ScrollView误选、r5键盘未入图与弹层过渡均保留；最终修测试视口/键盘遮挡与稳定捕捉，未再散改字号。Swift/JS数字与Unicode哈希统一使用系统固定canonical函数；跨actor准入、draftEpoch、同scope外actor和畸形4xx反例均收口。自然语言记忆抽取尚未接线，检索仍词法，真实PG并发/两会话利用与纯时间中途到期边界未验，不关闭AF-A11。源码本地`0fc8c6958c4ffba6f88ca31d0cd565a9f439f59b`、证据`c86b68c3f14683039381ad2c7fbb9dc4ed064136`；47条明确文本路径推送远端`2d12c55d4caa2c4343a379b1058b48fa6f854075`，tree=`0fb76845dce37ec7ef3311ee6b9a49dbc61e2221`与独立计算一致，远端head/路径逐项读回。8项治理检查PASS；新增包图标名仅精确误报复核，最终1131候选0阻断/0待审；原22张待授权媒体0补传、没有合main或推旧本地历史。

同轮完成默认停用的Gemma r7候选、严格逐帧model/provider/response-id/cost校验与一次POST持久探针；独立审查先复现早帧错误可被正确末帧覆盖的P1，再仅修命名review分支并复核实际包，原默认/vision行为保留。候选维护363/363、客户端13/13、双包18/18与两入口静态PASS，12条源码/研究路径已推送`5d4505a4bab9852b28bdd1af3eac232246d30d9b`，tree=`4aa8b6f609837318faac12e240103a207c789234`、精确路径读回。治理扫描父目录`.codex`误判已在`fix/worktree-scan`以仓库相对路径根治，独立RED/GREEN及8种内部禁入/凭据反例通过，远端`f0074799d43758ed10042fbfa584993efed1ed5a`；本轮两候选采用相同字节，原主目录24代码未被覆盖。

用户明确批准r7新隔离匿名身份/空scope、精确API包及一次32token/20秒/四零价/单供应商/禁fallback/无上下文工具短文本后，已执行该唯一检查。项目Secrets保存三项非敏感绑定首次被自动审批拒绝，用户随后逐项明确批准后才保存；原密钥/数据库配置未读写。配置传播使API19→20、tick7→8，读回原50/43文件与原ezbr hash均未变；随后仅部署批准的API r7 tar `eac493ce38634ef721c69be7cece91c6d0aa1b040f922a1a5247d14e4052c257`为API21，53文件逐字节读回一致，ezbr=`eafb3d119783fba86bf97e6523992df70619ccdf49196a2a37661e60ffda1886`；没有部署tick候选，tick8仍原43文件。正常App默认路由仍apodex/Novita，只有具名review前缀绑定新subject/scope，W40扩大后的数据合同不能混入此包。

固定`Reply only: received.`唯一POST初次读取流未完整，客户端保持unknown且不重发；独立冷进程仅GET同一原JSON/SSE/provider receipt找回**failed / HTTP429 rate_limited**，事件只有started→failed，无首段，actual_model/provider/cost均null、terminal_validated=false、provider_attempts=1，故真实检查FAIL，不能宣称0费用回执或模型成功。去敏结果与原快照/回执hash留隔离树ignored `services/edge/build/model-route-review-20261015/LIVE-RESULT-r7.json`；0600私有vault/journal未发布，未刷新授权/新建第二身份/重试/放宽策略或改供应商。审查API与三绑定暂保留供原结果读取，原回滚包保留，未执行回滚或删除。手机build16原1/2失败/剩余额度不受本次独立授权影响。长期Goal未完成，最新运行状态见页首；中午前原生阶段版已可点测，但真实W10–12、CP-01–03、独立托管调度、系统日程、七天日用及具名竞品门全部按原合同继续，未签收AF/FINAL。

2026-10-15 09:35继续同一ACTIVE Goal：已交付build24的主目录、固定包、8767/8768服务和949DAB72用户点测Simulator均保留。后续隔离为`feat/s04-memory-lifecycle`与`fix/model-route-review`两条候选，另开治理修复树处理扫描器误把工作树父目录`.codex`当仓库内禁入目录的共性问题。W40已贯通维护API的明确开启、保存/确认/更正/忘记、来源与原操作读取，以及新会话/原任务的refs-only记忆快照和provider前/提交屏障；原生侧栏、账号分区和前后台生命周期已接线，build25首次test build通过，但尚未签收。交叉审查实际发现并修复刷新覆盖未落盘输入、完成后迟到草稿写回、页面重开网络权、更正回执过宽；同scope异actor能忘记他人记忆的HTTP反例和畸形4xx误判未发送的反例正在收口，首次FAIL保留，最终同包host/UI尚待运行。记忆检索沿既有词法机制，未接真实自然语言抽取，不关闭AF-A11。独立Gemma/Google AI Studio候选维持默认停用、单一服务商/四零价/no fallback，基于线上API19与tick7原字节分别准备最小审查副本，避免整树覆盖线上登录/图片或静默改道旧工作；未部署、未调用真实模型或Auth。新的本机记忆QA仅占8769/8770，现有另一台QA Simulator原build9二进制已保留，未删除容器。所有源码仍须最终审查、治理检查及显式路径提交/连接器读回；源码阶段进展和合成回归不能替代真实PG/模型/手机、独立调度、系统日程、七天日用及竞品配对门。

2026-10-15 09:00交付[build24原生有限工作阶段版](../acceptance/restart-native-accepted-work-2026-10-15.md)：候选`AF-W50-NATIVE-20261015-24-R8`，0.3.0(24)已安装并启动到现有Catpaw-AF-start-20261014 Simulator，系统恢复large。实际安装读回24，主程序/Debug dylib与固定包hash一致，work/resume保留同客户端，启动前后POST计数2→2，未自动填发。新入口为`zsh apps/ios-conversation/Scripts/run-simulator-review24.sh work`，恢复用`resume`。原生typed服务/持久队列/实际HTTP到本机维护API和worker贯通，支持原文/范围/期限/预算确认、未确认保稿、实际打开v1成果、返回及冷恢复；身份/模型/序列化数据库明确合成。最终同包2项宿主方法（8合同＋5应用服务组）、4项实际UI（正常成果/丢响应/真实最大字号/受影响编辑）全PASS；unknown仅1次POST，GET找回原成功终态。最大字号53pt、无QA覆盖，完整条款/固定确认可达；工作确认与成果编辑共用适宽完整/紧凑动作标题，完整AX保留，不减字号。r1大字号大步滚动过冲FAIL及旧QA种子/AX角色/会话冲突/首次宿主导入失败保留。349/349后台离线、non-DEBUG SDK、106宿主成员/3target/1009双语通过；284冻结输入、完整27文件包指纹`f5166d5615eded551bd64d900b163ad0c787df5fb69006fbb76efd37150536a1`与14张原像素本地合成截图见日期RESULT，媒体上传0。build24包与该Simulator预留用户点测，后续候选使用独立输出，不能覆盖点测包或在该设备同时跑测试。本片36条明确路径已本地提交`1d39aa83b31866a681b02e3370cd0343b2c914f2`，连接器同步远端`3c1984ea810d91d18c361686e06e94459054fb25`并读回精确路径；发布tree=`63bc3d754dfb7e63924b550e4f5cbdd005835634`与独立计算一致，见[发布身份](../acceptance/evidence/native-accepted-work-20261015/PUBLICATION.json)。两侧完整tree仅差原待授权22张PNG，0补传、未合main。真实Auth/PG/模型/来源/独立调度/OS/同版手机与全部AF/FINAL门继续未签收，手机16及1/2失败/未用额度保留，Goal ACTIVE。下一片优先用户反馈与真实W10–12/CP-01，不因阶段版交付停止长期工作。

2026-10-15 08:39恢复执行：上一轮完成目标合同、输入hash和六条明确路径的检查/提交/推送，远端`bedfc8a4c2d69b04f1d543564a03b84e7e95e890`精确读回，属于实质进展；当前Goal恢复ACTIVE。三路只读审查未发现本片P0/P1，维护全集更新为349/349离线PASS；没有把合成接线当真实产品签收。Root保留旧server/失败证据，在两个未占用loopback端口建立新的r3合成快照，旧工作授权不续期；build24产品源码冻结，仅加强UI测试为实际打开v1成果正文并返回。Build24-r6测试包构建通过，开始默认同包UI路径；随后系统最大字号、丢响应冷恢复，再准备可复现启动入口和版本证据。中午硬交付范围与所有长期门保持，不扩大生产模型/Auth/SQL、部署或手机安装授权。

2026-10-15 08:35用户要求“加速并行，今天必须完成，中午前交付一个版本”，并指定先更新终极目标、由用户启动。已更新同一个[FINAL-G3执行定义](../planning/AF-1/goal.md#2026-10-15交付优先级与启动规则)、启动合同和可复制prompt；基础合同ID与全部验收门保持。最近硬节点为2026-10-15 12:00 Asia/Shanghai前交付可在已有Simulator完整点测的原生阶段版，优先build24当前路径；10:30冻结候选、11:30交付准备，中午后按反馈与W10–12/CP-01优先修订，23:59前交当日修订候选和剩余阻断。此为计划，不是已按时交付或已验收事实；七天日用和BP配对不在一天内预签收。启动后Root独占构建/Simulator与集成，A原生合同/HTTP/恢复、B维护API/有限执行、C共享布局/可达性审查三路并行；中午前只修本片阻断，禁止并发改同文件、边测边改或继续散改字号。当前控制器仍blocked、子Agent未运行；本次只更新合同与文档，等待用户启动，不重复建Goal、不宣称已自动执行。原有build24源码WIP及失败记录均保留，代码发布授权沿用；实际完成/版本/提交身份随后只在本页更新。

2026-10-15 07:42用户查询进度：build24（0.3.0）实际App与测试包已在`Build24-r5.xcresult`对应输入上TEST BUILD SUCCEEDED，包Info.plist读回24；仍是未签收、未提交的工作区候选，不能称已交付版本。新增有限工作原文/范围/期限/预算确认、未确认草稿冷恢复、原队列与typed HTTP接线；真实原生宿主经本机维护API已产生1次受理、计划和本地成果，但模型/身份/数据库均为明确合成夹具。默认完整UI回归先后暴露旧QA种子、AX查询及不同合成客户端初始会话冲突；修复已进入r5编译，完整UI尚未复验通过。距本片Simulator点测交付尚需：默认确认→成果→冷恢复、系统最大字号可达性、丢响应后原ID只读恢复三条同包路径；再固定源码/包hash、可复现启动入口、限制和文字证据，经检查提交推送。本机服务会话窗口修正专项11/11通过，不变更生产Auth、原工作期限或旧快照授权；不作为真实模型/PG/调度证据。上一片已推送的源码仍为`1735d6ed1e82213ca604fc37c37da39dc41872d7`，不能把本轮WIP说成已同步。可点测稳定候选仍build23，手机仍build16；真实对话上次`free_model_unavailable`失败保留，新增版本上线需先准备同版服务/路由修复与安装验证清单。长期后续仍为真实W10–12、CP-01、图片/记忆、独立调度CP-02、真实日程/提醒CP-03、基础同版总验收及FINAL日用/竞品门。本次仅核对与纠正实时状态，未恢复控制器，未新增构建、UI运行、安装、Auth/模型、部署或推送。

2026-10-15交付[有限工作执行与原生日程服务接线片](../acceptance/restart-bounded-work-integration-2026-10-15.md)：候选`AF-W50-W60-INTEGRATION-20261015-02`，基于本地`bfaea758`和远端`a7ad5d78`。原versioned work-intent、同事务run/plan/grant/receipt、实际bounded claim/dispatch/received/本地收尾/原attempt终态ack已贯通；普通model consent不自动创建有限授权，whole有限任务显式拒绝。原工具回放仅校验不可变绑定，新受理另检查剩余窗口；恢复核对原grant和原due中较早期限，最后await跨截止回滚，closed/unknown原任务不能重开或退款。strict fresh viewer与有限原工作事实分开，logout/consent撤权同事务停止后续dispatch；共享source/grant锁前序贯穿计划/审批/成果服务，真实PG竞争未证明。最终维护338/338、实际Cloud HTTP受理12/12、执行11/11、lifecycle16/16（邻接24/24含重叠）PASS。原生typed HTTP/持久original-op journal复用已有session，service10＋HTTP7＋contract8组PASS，41编译输入冻结；2生产与3测试文件已登记，non-DEBUG SDK/102 App成员/3target/969双语PASS。旧RED与首次整合失败保留；治理/语义字体/敏感扫描通过，未新增零散字号值。readiness只声明维护bounded single_run能力，native_producer:false/independent_scheduler:false/live_verification:not_verified；无有限意图App生产入口或系统动作，25便携组与SDK不是宿主UI/真实OS验收。当前可点测仍build23；新包/生产Auth/真实SQL/模型/调度/安装/部署均未执行，原模型route与1/2失败/未用额度保留。此片未关闭W50/W60、CP或总产品门，Goal ACTIVE；下一片优先原生明确范围/期限/预算受理入口与可找回确认，同版Simulator交互交付，原生日程可信target/receipt/API lifecycle按依赖并行。本片44条明确路径已本地提交`82c549443b4e43fce8ffc3bfd300c87c69465e87`，连接器同步远端`1735d6ed1e82213ca604fc37c37da39dc41872d7`并读回44条精确差异；发布tree=`05bebb3d3b7e91e7a088ee0de76b1c2df87b9e33`与独立计算一致，见[本片发布身份](../acceptance/evidence/bounded-work-integration-20261015/PUBLICATION.json)。远端沿原历史快进，本地来源保留；本地完整tree与发布tree仅相差原待授权22张PNG，0媒体补传、main未合并。

2026-10-15交付[有限已受理工作与设备效果合同准备片](../acceptance/restart-bounded-work-contracts-2026-10-15.md)：候选`AF-W50-W60-CONTRACTS-20261015-01`，15项明确审阅source/test/config加日期证据。Root、execution_fences、native_controls实现，native_layout独立反例审查；冻结请求/run绑定提炼同一纯校验，来源与执行规则不再分别维护，许可时钟同一次观察满足上下界并拒绝回拨。严格新命令expiry语义保留；独立accepted-work source端口只读原有限授权与当前撤权事实，不续session、不生成dispatch许可、尚无API/tick调用。W50拆新dispatch、原attempt终态ack与durable received本地收尾，两种实际维护Store测试级CAS组合PASS，unknown不退款/补发，公开来源单次回执验证缺失继续拒绝。最终维护303/303含W50 37、设备原语34、来源7全部PASS；独立最终11/11、同10项旧来源对照1/10（9项真实拒绝缺失FAIL）、共享helper 6组/59拒绝变体/2有效基线PASS，旧RED保留。W60 v2 strict原生DTO/codec的15个实际Node合成响应与8组portable PASS，旧v1 28项PASS；登记当前宿主后non-DEBUG SDK/100 App成员/3target/968双语PASS，99默认语义source/10具名legacy保持。初次SDK宏IPC失败、初次29个合成设备标识扫描命中均保留，Root按fixture精确hash/行号复核，最终扫描无阻断或待审。原生HTTP/service journal/producer/OS、API/worker/purge/独立调度及真实Auth/PG仍未接线，W50/W60与CP/总Goal未签收；没有新包安装或生产请求。当前可点测仍build23，下一片接明确用户有限意图与初始run/grant同事务受理，再贯通worker/原回执/撤权清理，原生日程接线按依赖并行。三条具名模型只读审阅无已证完全兼容替代，不修改provider或消耗第二额度；截图授权待答，0补传。本片已按18条明确路径本地提交`f86fff48691cc6762dfd13b6879b0148cda74c5b`，连接器同步远端`7da7ad98c9303e101e33777d48e433de92239e20`并读回18条差异；发布tree=`5d04d2d0e04f2a86341cbd89ec57f306831dab30`与独立本地计算一致，见[本片发布身份](../acceptance/evidence/bounded-work-contracts-20261015/PUBLICATION.json)。原本地历史保留，连接器commit metadata不同；源码、日期证据与发布对应，main未合并，媒体0补传。

2026-10-15代码同步：用户已明确授权“及时提交、推送代码”，后续每片完成适用检查后，在原短功能分支本地提交明确路径并及时同步origin，不等待终版；main仍按PR整合，不能借此合并、部署或扩大手机/模型测试。现有私有`Yankj/catpaw-m`与push权限已连接器核对；HTTPS缺CLI身份、严格SSH主机校验失败，均未绕过或提取凭据。已通过既有GitHub连接器发布[当前源码分支](https://github.com/Yankj/catpaw-m/tree/feat/s05-bounded-work)，源码快照远端`db1cf680c54eaf6062320f645dcfc8daaeb3a53b`读回正确，获授权180个源码/测试/文字证据文件的tree=`d88d72ce8441272319c29e05064df62f51c495a6`与独立本地计算一致。连接器提交metadata不同，原十个本地commit/tree与build23源码身份保留，见[日期发布记录](../acceptance/evidence/source-publication-20261014/RESULT.json)。自动审批拒绝首次合成截图blob上传，认为代码推送未明确包含截图披露；22张新PNG保持本地、0上传，已按具名清单单独询问。文字报告/原hash仍保留，但不能称完整媒体证据发布或产品签收；六个未集成WIP未混入发布。本轮布局/冻结/部署快照/AF/FINAL/CG规划/语义字体/敏感/空白通过，未重复跑产品测试。

2026-10-14自主续行计划：build23源码`7ac5518`与日期读回`c24901d`已固定，后续不因未标字号的截图再零散改值。新问题先复现并检查共同角色/容器/状态触发，在稳定候选上一次运行适用回归，默认档先展示，压力档显式标注；构建、真实UI与性能测量由Root独占Simulator，避免源码边改边测和重编译干扰长文测量。本轮三路内部Agent已完成只读并行评审：原模型route/请求格式与错误映射、W50持久有限grant的admission/source/worker/settlement/purge接线、W60设备执行permit与原生应用服务/unknown恢复。输出留忽略build，Root统一选择最小可交付路径；不先把六个WIP整体接入或宣称已有能力。关键路径仍先解决现有真实会话W10–12再同版CP-01；模型外部条件不足时继续独立离线实现，W50/W60准备工作并行。阶段23用于明确离线原生交互点测；下一候选优先真实许可→原请求→流式终态→持久恢复，再按依赖交持续跟进/记忆/日程。新模型供应商、付费fallback、扩大真实调用、生产部署和新手机安装仍保持具体候选授权边界。

23:37原模型只读核对：12项API19/tick7部署基线输入hash匹配，实际route仍是`apodex/apodex-1.1-mini:free`＋`novita/bf16`，配置中的其他常量不是实际所选模型。原请求已完成许可与受理，adapter把供应商HTTP404映射为`free_model_unavailable`；已经返回200的turn受理通过流终态记失败，不能误判为Supabase函数缺失或启动503。本轮现有项目管理接口读回API19/tick7均ACTIVE、部署包hash仍分别`3fee61c0…`／`8f767ae8…`，没有部署。23:37公开原model endpoint GET200、`endpoints=[]`，原响应SHA256=`13c38b2b6e9e31801c8de397e7d610abb9bf6cb8c615c75d3af249e06d754818`；只证明该时刻未带凭据的公开目录为空，原provider正文与账号级可用性仍不足，不声称永久停服。[OpenRouter原生路由文档](https://openrouter.ai/docs/guides/routing/provider-selection)说明完整供应商slug锁定具体variant、零价和隐私/参数过滤仍是各自独立约束，现无证据支持猜测别名或放宽过滤。本轮Supabase changelog与状态码只读核对、公开元数据均无Auth/推理/SQL操作，手机第二条仍未用；先保留原失败，准备具体可兼容route的证据和同版部署清单后才提出必要变更批准。

本轮底层接线审查收口：六个WIP字节保留，未直接集成。W50先拆开“当前grant/来源校验”“新dispatch租约”“原attempt终态结算”，避免两种维护worker在写入终态并清lease后被通用execution门回滚；再拆网络收据≤30秒期限与已持久received结果的后续slice期限，后者取原grant/due与当前slice/lease共同上限，零新增dispatch、额度或续权。W60先保持旧v1只审阅，建立独立v2精确决定、可信设备目标/原OS回执来源、root与calendar/notification两child持久身份，再接typed原生端口；日历ID变动或0/多匹配及通知unknown只读核对，不补创建/重加提醒。上述是源码组合审查，8项W50/8组W60故障验证均NOT_RUN；原15/34孤立测试不等于接线PASS。Root读回W50三WIP＋16维护输入、W60三WIP在内33仓库输入＋4本机SDK header hash一致；布局、冻结、部署快照、AF/FINAL/CG规划、敏感和空白检查通过。本轮业务源码、测试运行、Simulator操作、Auth/模型/SQL、手机安装、部署/推送、新依赖/凭据/compute均0；模型公开目录和现有函数元数据只读核对不作真实产品验收。

2026-10-14当前前台片已交付[build23原生阶段版](../acceptance/restart-typography-stage23-2026-10-14.md)：分支`feat/s05-bounded-work`，候选`AF-UX-TYPOGRAPHY-20261014-23-R2`、0.3.0(23)已安装/启动到已有iPhone17专用Simulator，读回23并恢复系统large，没有自动发文本。Device Hub打开命令成功，Mac锁屏仍挡窗口人工观察。Root负责宿主/包/证据，native_layout负责共享语义字号、完整header、实际UIKit内外视口与pending恢复，native_controls独立源审查/反例复核。98默认受检source的静态门已补Font别名/注入、DEBUG逻辑和旧页面.init负例；10具名旧presenter排除，SF/QA仅按精确表达式豁免。初始弱断言默认13/XXXL2/AX5五项虽PASS，截图发现默认输入遮挡，严格同原包RED复现19.33pt可见区FAIL，原包/日志/截图保留。修复后最终同包8单元＋9次UI共17次执行、14个不重复方法全PASS；真实系统large/XXXL/accessibility5无QA覆盖见证为17/23/53pt，当前光标和稳定编辑区129.67/172.67/121.67pt，三组稳定整组AX与UIKit观测、当前EDIT-END选区通过。非DEBUG SDK、99宿主成员/968双语、布局/冻结/规划/部署快照/敏感检查通过；234项native输入、完整26文件App（含Debug dylib/签名）指纹与六张未改截图固定。完整包指纹`d5b6781047ac71e4fc8d913ebc93e30b40c1fa482b541ea5253455d9ad57bd38`。本版先测原生输入、计划、成果改稿、审批/控制和试算的明确离线流程；计划/审批在前一文字revision通过，最终编辑恢复revision未重跑，不冒充总回归。真实Agent/来源/PG/独立调度/日程/完整VO动效/日用/竞品门均未关闭；六个后台WIP仍未集成。手机保持16，真实模型第一条FAIL、第二条未用；本轮Auth/模型请求、手机安装、配置复制、部署/推送和新增compute均0。下一版本先打通现有真实会话→CP-01同版验证，新手机安装/扩大真实测试仍按候选批准。

2026-10-14暂停收口：在本地从已固定W33建立`feat/s05-bounded-work`后，`get_goal`返回PAUSED（系统updatedAt=1791984313）。停止后续接线、实现和验证；三个内部Agent均已完成，没有运行中的Simulator/后台测试。W33源码与日期证据提交`cb63a3a`及状态提交`004c8a5`保留。下一片仅六个未提交后台文件：有限work grant原语15/15、设备效果原语34/34离线专项由各Agent完成，仍未接API/实际authority/worker/purge/native，未经root独立集成评审，不能签收W50/W60或CP。原生语义角色/自适应header/静态门只完成核读方案，没有启动后续修改。原手机16第一条FAIL、第二条未用，未新增安装/部署/推送。暂停后仅记录准确状态，不重复创建/替换Goal，不自行恢复。

2026-10-14固定[W33离线交付记录](../acceptance/restart-authority-recovery-2026-10-14.md)，候选`AF-W33-CONTROL-20261014-06`、0.3.0(22)，已按69条明确审阅路径本地提交为`cb63a3afda2abeedc603d5d1b77d95a977cc8dcd`；提交读回49项source/test/config hash及69路径对应。最终80单元r4＋20实际Simulator UI r3全PASS、100不重复方法；生产源码相同，r4唯一输入变更是旧队列测试加强原UUID/原文、producer持久队列/自然UI及fresh磁盘重开等待。r3整轮99/100 FAIL保留，没有改写。225维护后台/17控制专项、22恢复场景/8URLSession场景、图片包18项、非DEBUG SDK、99宿主成员/968双语与Release22通过；232原生/84维护输入、八张同生产源码合成截图与日志/包hash固定。旧caret/AX/异步等待失败与真正lease/dispatch RED均留证；不替代真实PG、模型、同版手机、VO/动效/日用或总验收。截图发现最大字号工作卡长标题/状态同排过窄，caption绕行及preview环境/extent重复提交仍待统一收敛；长文p95的隔离10.75/10.89ms与并行Release时519.69ms均保留，归因未证，物理性能NOT_RUN。

暂停前过程记录（三路）：后台Agent实际新建W50有限work grant合同/服务/专项测试；设备Agent实际新建设备效果合同/服务/专项测试，旧review-only不能获得执行权；原生语义角色/自适应header/源码检查门准备齐备，22候选已固定，将接着实现。两组后台新文件属下一候选WIP，未接API/worker/purge/native或真实系统，不计W50/W60 PASS，也未纳入本次W33提交。手机保持16；第一条正常App请求在provider_stream失败，第二条未用，原route/API19/tick7和数据保留。当时未新增安装、部署、推送、依赖/凭据或计算支出；Goal当时ACTIVE，当前控制器状态见页首。

2026-10-14 19:48当前W33离线候选尚未提交，Simulator版本为0.3.0(22)，手机仍为冻结0.3.0(16)。维护后台同Task控制、不可变原operation读取、两worker共用执行屏障与来源会话撤权已实现；暂停保留原许可，恢复核对原Task，撤权退休租约，已dispatch/unknown不得重新发送。225全后台离线、17控制专项、22原生恢复场景和8实际HTTP适配场景PASS。首轮整合原生92方法中4个控制UI均PASS，但实际UIKit caret单元方法产生15个断言失败，续聊UI两项与旧计划UI两项失败；此轮不计PASS。共享TextKit2布局/光标滚动、键盘viewport单次扣除和自适应输入详情正在修复；原日志与230项固定r1输入保留。真实PG竞争/重启、同候选部署与手机完整矩阵仍未验，W33不关闭。

2026-10-14手机真实路径：经只读系统清单确认当前App为0.3.0(16)，用户明确允许恢复或创建一个匿名体验身份后，从“开始体验”进入对话；无法从UI判定身份是恢复还是新建。第一条原文“Reply only: received.”经正常App许可后已显示“已发送”，19:42观察终态“此轮回复未完成”与`free_model_unavailable`，未观察助手回复。此前自动审批因镜像无法定位手机内许可控件阻止点击，交由用户手动允许；本轮用户确认后只读观察原请求，没有重复发送。两条短文本额度已用1条，第二条未用。W10–12已有真实失败证据，不能继续写发送0次或模型NOT_RUN；现有provider adapter将上游404映射为该错误，实际原因继续只读核对。现有API19/tick7已再次连接器读回ACTIVE；不切provider、不启用付费回退。未退出、重置或删除手机数据，未安装22、部署或推送。

19:50–52只读核对进一步定位：Supabase脱敏聚合日志显示API19本时间窗只有一次正常model-consent POST 200、一次turn POST 200；`accept_commit`、`dispatch_admission`、`provider_admission`均出现一次，`catpaw_chat_interrupted`一次，phase=`provider_stream`、code=`free_model_unavailable`，无first_delta记录。OpenRouter现有free model公开endpoint元数据GET 200，但`endpoints=[]`；这是未带凭据的元数据查询，不是额外模型推理，不消耗第二次手机额度。由日志与部署adapter映射推断失败在原路由上游404，与当前无公开可用endpoint一致；未取得原provider错误正文，不能证明永久停服或所有账号的可用性。不切换、不放宽零价/隐私/固定供应商限制；第二条暂不发送，继续独立离线工作。自然调用中发生的生产数据库操作不算PG竞争/重启验收。

20:52本地整合更新：r2同源100方法为97 PASS/3 FAIL（78单元/19 UI通过，2个共享caret方法及1个最大字号原操作AX标识方法失败），不得记为整轮PASS。续聊、改稿、来源阅读、账号恢复、五项真实宿主控制回执投影和另外三项控制UI均通过；两种维护worker的225离线仍通过。共享修复已把TextKit字形布局缓存与UIKit视口/滚动尺寸提交分离，取消系统自动滚动动画与精确caret恢复的竞争，保留IME及用户拖动门；focused r5六项实际UIKit宿主方法全部PASS，包括40KB连续编辑的两个真实显示帧。原操作Disclosure的容器与每行AX身份分开，完整SHA和未确认状态仍须独立可读，专项待本机UI复验；当前232项源码快照冻结，下一轮同源100整合尚未完成。图片Draft包18项和原生22场景/8实际URLSession场景通过均属离线层，不替代真机验收。只读现有零价替代endpoint核对没有证明兼容当前隐私限制，仍保留原路由和第二次额度；W50并行只读设计先解决有限持久授权，未创建Cron或放宽session expiry。

21:08最大字号原操作AX定向1/1已PASS；最终生产源码的Release Simulator 22、非DEBUG SDK、99宿主成员/968双语通过，当前整合r3 UI仍运行。r3单元出现一个旧账号本地入队检查FAIL：`!enqueueing`不能承诺并发repository订阅已完成页面队列投影；原日志不足以证明持久队列丢失。仅修改测试等待，保留原断言并增加原UUID/原文、producer的实际队列、自然UI投影和拒绝登录前后fresh SwiftData重开验证，不调用强制refresh；产品源码零变化，待80项同范围单元复验。232项r3/r4输入差异仅此测试文件，失败轮次完整保留。只读布局审查另记录现有部分caption绕过13pt policy、完整图片preview环境未验与extent亚像素舍入造成重复viewport commit；不宣称全App字体/弹层已根治。

下一片合同核读已收齐：W50先新增持久有限work grant（明确原subject/scope/operation、工具与来源、route/consent、绝对期限和跨tick/due累计预算），新命令JWT exp继续严格验证；unknown消费额度但只读核对，最后合法调用的有界收尾不能仅因剩余调用数0被禁止。当前App logout事务可阻止后写，外部Auth撤销/删除的实时信号仍待接线，不能延长session expiry冒充离线授权。W60/W61先版本化设备执行合同，旧review-only批准不因安装新版而得到效果权；日历与本地通知固定子effectID和独立回执，冷unknown零重建，精确时区/DST/跨日、账号返回和系统权限另验。两路目前仅只读计划，不当代码或产品PASS；没有创建Cron或访问系统日历/通知。

W00入口/版本/冻结来源/部署快照/授权核对已完成，保留API19/tick7日期快照的14项共享差异；没有把maintenance断言为已部署同版。W30a已在`feat/s03-plan-persistence`提交为`1c3bb15`，42个明确审阅路径与39项受测source hash对应，工作区提交后干净。来源片已在`feat/s03-sourced-results`提交为`483f7ad`，42个明确路径、38项source/test与日期证据一致，提交后工作区干净。改稿与审批恢复片在`feat/s03-result-amendments`提交为`d02f1e7`，54个明确路径与日期证据对应；选定报告自然语言跟进片已在`feat/s03-report-continuations`提交为`a444e4f`，51个明确审阅路径与日期证据对应；当前分支为`feat/s03-authority-recovery`，保留未提交W33工作。`feat/conversation-genui`、同期文档作者的R5与PR #8整合、旧checkout、legacy-local及冻结资产保留。本片没有推送或新PR。

[2026-10-14首片](../acceptance/restart-agent-start-2026-10-14.md)：W11修复委派空正文续聊历史；后台补COMMIT前租约/授权检查。D20/D30同步交原生固定registry、表图/精确试算、复制分享引用保稿以及不覆盖输入的回到底部。21续聊/16队列/64算法schema/67后台离线与最终6原生测试通过；Release模拟器17构建成功。这是合成/离线维护源码候选，真实许可→原请求→现有模型→持久化→App恢复及CG真实路径仍NOT_RUN。

[W30a与原生持久恢复片](../acceptance/restart-plan-recovery-2026-10-14.md)已固定离线候选：计划v1/同任务CAS v2、accepted/applied分离、安全checkpoint与实际步骤回执接入维护后台和原生sheet。新修改commit后复用原许可有界唤醒，waiting_input经实际维护API到同任务v2无需手动tick；GET/原operation重放/unknown不重发。原生关闭重开保留修改与聊天两份草稿，修复本地/服务端空间误比较及合法长计划响应拒绝；GenUI筛选/选择/无效原始输入冷启动恢复、完整表共享状态与精确负值提示已交付。87后台、25原生（18单元方法＋7实际UI）PASS，Release模拟器18可构建。范围仍是合成/离线维护候选，AF-A07/CP-01及所有真实产品门不关闭。

[W31a/W32a来源与精确决定片](../acceptance/restart-sourced-results-2026-10-14.md)已固定同源码离线候选：给定公开URL→实际读取端口→原始dispatch/字节回执→可核对引用→同任务有来源成果；计划v2不能消费v1证据，unknown不重新读取，撤权/取消/截止回滚写入。新的精确动作合同接入维护API，approved保留事实而停在waiting_device，不假称系统效果。原生独立成果阅读、来源单sheet/详情、exact版本历史与返回保稿同步交付；修复合法NEL的SSE字节分帧与来源sheet辅助字号继承。156后台、6独立恢复审查、37续聊、74本机HTTP/SSE、15来源解析及最终7原生（5单元＋2UI）PASS；79宿主成员/777双语，Release模拟器0.3.0(19)成功。源码/日志/八张合成截图的hash见日期证据。实际Supabase TCP/TLS、模型/PG、终态成果改稿、原生可找回审批/执行、独立调度与全部产品门仍未完成。

2026-10-14（Shanghai）重新选择iPhone镜像，本片再次只读观察仍明确显示Mac认证锁定页，需用户自行触控ID或输入Mac登录信息；未进入App、未操作认证、未发送请求。build16两次短文本额度仍未消耗，W10–12真实路径等待解锁。三路内部Agent已交W31a受控给定URL读取/来源回执、同成果版本/历史原生阅读和W32a精确动作合同；下一片优先补终态成果CAS改稿与原生可找回待决，再接W33；旧r2仅合成preview，不当作产品审批。W20/W40、设计线和GenUI producer/同工作跟进可按文件/依赖分工。真实模型/PG、同版手机包/部署、独立调度/日程、七天日用与竞品配对仍未完成；外部条件不足继续独立代码与离线验证。本片不扩展手机16授权，实际安装/部署/推送/付费资源均0。


[改稿与审批恢复片](../acceptance/restart-artifact-decisions-2026-10-14.md)已固定同版离线候选 `AF-W31-REVIEW-20261014-04`：同成果三字段人工CAS改稿、不可变版本/原operation读取、原生可找回精确审批与同scope草稿排空已接入维护后台和实际宿主。184后台、37续聊、86本机HTTP/SSE、28审批便携/8适配器、10改稿/7计划草稿、4负向来源投影回归及最终67原生（53单元/14实际UI）PASS；严格JSON、90宿主成员/895双语及治理检查通过。Release模拟器0.3.0(20)成功，168项固定输入和九张同版合成截图hash见日期RESULT。保留61/64的无签名Keychain失败、实际-34018探针、视觉失败、中断与编译失败；现有Simulator模板的Xcode ad-hoc包通过真实Keychain与账号隔离，不是手机签名。最大字号末行/光标可见，unknown原修改/原决定只核对不重发；负向来源不可被晚到投影恢复，logout先关闭HTTP authority再排空草稿。人工改稿不调用模型或重读来源，新增论述待重新核对；approved仅waiting_device、无EventKit效果。持续磁盘失败后forced logout仍不能保证最后内存稿恢复。下一片优先补选定报告的自然语言修改：新turn/exact target/完整模型round/同task续接与CAS；静态9GAP及8条待运行设计不算功能PASS。W10–12真实路径、W33、GenUI producer、记忆、独立调度/日程、同版真机和全部release门仍未完成；本片安装/部署/推送/付费计算及build16短文本均0，Goal保持ACTIVE。


[选定报告自然语言跟进片](../acceptance/restart-report-continuations-2026-10-14.md)已固定同源码离线候选 `AF-W31-CONTINUE-20261014-05`（`feat/s03-report-continuations`，0.3.0(21)）：新turn/exact target/完整原文与body/原许可和新会话权威，完整模型round受理后重开原Task；原frozen request、旧版本和旧回执保持。只读追问tools为空，GET/重放零kick；新计划compose/save/verify、每个发布版本和实际结算分开，普通计划修改不能替换进行中的冻结改稿。原生修改/追问/普通聊天三份原文、typed持久队列、组合输入、可信subject、严格回执与冷恢复已接入宿主。实际维护运行时的离线两次改稿JSON进入原生HTTP，当前v3下按原operation找回v2、同Task、全GET；Node与Swift原文字节hash差异已修正。206后台、37续聊/86本机wire/16队列与最终81原生（65单元/16实际UI，零失败/跳过）PASS；Release模拟器21、93宿主成员/910双语、187固定SDK输入/41改动输入和六张同版合成截图hash见日期RESULT。保留响应样例缺字段、私有类型编译失败、请求体stream夹具崩溃、手势定位失败、截图发现版本号挤掉后的修复与两次主动中断整合轮次；最大字号版本、末行、光标、44pt发送和退出入口可见。三个内部Agent因额度停止，主线接管并完成本片，不另创建聊天或替换Goal。新来源会话撤权已阻止dispatch/publication及旧完成复用，但pending Task可能仍scheduled，W33需清楚的恢复状态。治理/合同/敏感/空白PASS；API19/tick7快照、原route、A1与数据保持。16:54–55只读镜像显示iPhone使用中、镜像结束，需锁定iPhone以连接；未进入App/点击连接。早前Mac认证锁定仅保留为日期事实。本片生产Auth/模型/公开GET/SQL、手机包/安装/部署/推送/依赖凭据/计算支出与build16短文本均0，全部产品门与FINAL-G3继续未关闭；下一片W33及原生GenUI producer并行推进。

2026-10-14暂停时的W33工作：typed同Task暂停/恢复/撤权及不可变原operation读取已在维护API形成未提交候选；离线用例已覆盖两种既有worker的同Task恢复。最新专项运行7/8通过，故障注入发现旧worker在模型入口拒绝后，错误收尾仍把持久paused覆盖为failed；日志保留在忽略目录`services/edge/build/authority-recovery-20261014/control-r3.log`。该失败未修复，未签收W33；原生控制入口、真实PG双执行者/重启与撤权验收仍未完成。系统Goal现为PAUSED，本次仅核对、记录进展和体验问题，不继续实现、安装或部署；早前段落的ACTIVE保持为对应日期事实。

2026-10-14体验问题审查：近期最大字号返工涉及来源sheet字号传递、编辑区/键盘/固定操作区空间分配，以及长标题挤掉版本号。现有语义字体、44pt操作区和局部字体桥接已使用，但共享层没有覆盖这些布局约束；各页面的局部修复及单场景几何断言未形成同类页面统一回归。后续恢复开发时，优先沿现有DesignSystem收敛文字角色、弹层环境、版本标题、键盘下可编辑区域与决定区组件；默认/最大辅助字号、375/390/430pt、中英长文、键盘与浅深色按适用组件组织矩阵，检查实际末行/光标、版本、动作可达性并审阅截图。先迁移已有失败页面并复验，再用于新页面；这些是待执行纠正措施，不是已完成或真实产品PASS。

## 当前基线与证据

| 项目 | 实际状态 |
|---|---|
| 维护目录 | 用户指定的Desktop/ai-work/catpaw-m；应用入口 `apps/ios-conversation/CatpawM.xcodeproj`，服务端入口 `services/edge/supabase/functions/` |
| 代码迁移 | 已复制原生集成HEAD `582e4e4`、663个跟踪文件与12个未提交候选；候选hash逐项核对，旧源目录不修改；本地原始分支历史保留为legacy-local引用 |
| 最终handoff | 已读旧主仓handoff；用户确认相关任务停止。原文保存在忽略的local-audit；12项WIP与编译阻塞均相符 |
| 首个修复 | 新仓已复现并修复getter缺return；候选包含许可review与弹窗分离、稳定确认入口、队列折叠、持久回复证据；新增拒绝重开/旧revision回归，最终合成验证通过 |
| 首个本地检查（日期证据） | 冻结合同/上游/历史来源完整性PASS；便携对话7/7、队列9/9 PASS；最终39/39原生＋1/1实际弹窗UI PASS，DeviceTrial无签名产品配置build PASS；证据限合成/Simulator，物理手机与provider未验；最新追加候选见下行 |
| GitHub | 产品规划、源码调研、R1–R5设计与日期合成证据统一经[PR #8](https://github.com/Yankj/catpaw-m/pull/8)整合；实际合并提交以PR与main读回为准。main保持唯一主干；功能开发使用短分支，既有feat/conversation-genui及同期改动保留。默认main、合并后自动删head、本地hooks与PR核验沿用；当前私有仓库服务器保护不执行。legacy-local来源与旧工作树保留，详见[分支规范](../development/branch-management.md) |
| 手机/API | 手机仍为0.3.0(16)，用户已断开手机并授权使用已有Simulator；没有卸载/重置数据。第一条正常App许可请求已发送并失败，第二条保留。2026-10-14 23时管理接口重新读回API19/tick7 ACTIVE及原部署包hash；日期快照的50/43文件与14项共享差异仍须在下一部署候选对齐，本轮无部署。私人原图仍仅在忽略目录 |
| 已获批手机包 | 0.3.0(16)，独立Git archive绑定原main `a905b47`；非DEBUG、严格签名、原证书/profile/entitlements及IPA逐字节PASS。既有许可最多2次原路由短文本，已用1次FAIL；新包不沿用旧安装批准。见[包证据](../acceptance/restart-build16-2026-10-13.md)、[安装证据](../acceptance/restart-install16-2026-10-13.md) |
| 当前离线候选 | [AF-UX-TYPOGRAPHY-20261014-23-R2](../acceptance/restart-typography-stage23-2026-10-14.md)，源`7ac5518`、日期读回`c24901d`，0.3.0(23)在已有Simulator安装读回；最终同包17次执行/14不重复方法PASS，完整包与234原生输入hash固定。原生离线点测清单、源和包可用，未签名手机包/部署；旧17–22日期证据保留，23不替代真实Agent或总产品验收 |
| 真实链路 | build16第一条正常许可后已受理，供应商阶段`free_model_unavailable`、无首段/助手回复，FAIL；1/2短文本已用。23:37原公开model目录GET200仍无endpoint；既有路由保留，不自动重发或切换 |

旧仓不删除、用户数据不重置、签名凭据不发布。原始机器记录和大型旧性能采样保留本机/legacy历史，发布经扫描的spec、源码、合成摘要与原始trace hash。远端既有参数化签名模板与治理文档保留。

## 执行顺序与退出门槛

| 切片 | 用户可见交付 | 依赖 | 门槛 / 当前 |
|---|---|---|---|
| S00 维护入口与同步 | 单一维护目录、GitHub源码、plan/spec/验收/handoff齐备 | 无 | PASS：PR #1/2源码tree与本地引用核对，部署来源和体验合同已同步；包/源码版本区分明确 |
| S01 真对话与稳定许可 | 允许后能回答/追问/重开；许可可找回，队列轻量，状态诚实 | S00 | IN_PROGRESS：许可、队列、阅读、侧栏与草稿已有日期离线证据。冻结build16第一条正常许可后已发送，回复失败`free_model_unavailable`；第二条未用，现有路由只读核对中。手机不含后续候选；真实链路FAIL，尚未签收 |
| S02 真图片与连续体验 | 合成图真实理解；长文/前后台可用 | S01 | AF-A06与A04/05；NOT_RUN，不自行放宽视觉路由 |
| S03 执行审批成果 | 自然形成计划，可改/停/恢复；等待有入口；成果回对话/活动 | S01 | IN_PROGRESS：W30a同任务计划/安全点/原operation/保稿与续跑已交；W31a来源回执/版本阅读、W31b人工CAS改稿、W32a精确合同/原生审批恢复离线已交。选定报告自然语言同Task修改/只读追问及原操作恢复离线已交；系统effect、真实来源/model/PG及W33仍待；AF-A07–10/CP-01真实NOT_RUN |
| S04 记忆闭环 | 保存/来源/更正/删除，新会话生效 | S01 | AF-A11；接既有端口与真实PG，NOT_RUN |
| S05 主动跟进 | 时间/公开变化触发；无变化静默，暂停与退避 | S03 | AF-A12/13；调度托管部署先确认，产品配置代码可先做。NOT_RUN |
| S06 原生动作触达 | 本地日程确认写入，提醒返回同事项 | S03 | AF-A14/15；已知时间本地提醒先做，APNs独立接线。NOT_RUN |
| S07 智能UI与整体签收 | 六类卡、侧栏/输入/阅读；三条组合路径 | S02,S03,S04,S05,S06 | IN_PROGRESS：固定registry/精确试算/表图/消息动作、64核心、26状态边界与原生流中/冷启动/完整表共享状态PASS；仅显式offline fixture，HTTP producer与同工作跟进未完成。AF-A01/16/17/18、CG与全部必需项同版真实门NOT_RUN |
| S08 云电脑扩展 | 无登录网页＋文件处理；进展、恢复、停止和成果 | S03＋方案确认 | AF-C01–03；方向已选、新增计算预算0；资源/区域/供应商待确认，NOT_RUN |

S01通过后S02/S03/S04代码可在合同明确时独立推进；同一文件/设备由本任务统一整合。未经人类授权不向旧任务派发消息。失败定位输入→许可→POST→模型→事件→存储→UI具体段，不以组件完成代替用户路径。

## Goal 推进规则

### AF-1 可验收 Goal 与详细执行合同

2026-10-13用户要求将design/research、截图调用/观察、对标问题表、UX-1及12项体验验收纳入当前Goal。已更新[执行定义](../planning/AF-1/goal.md)、[输入的hash与映射](../planning/AF-1/goal-evidence-map.json)和D00–D50逐片设计线；本次不改变产品PASS/FAIL。可点按提案为设计基线，仍须原生同版验证。旧一周Demo/今天首页/飞书候选与旧预算估算不扩大范围。未来截图按用户要求保存并记录版本，私人原图只留本机。

[新计划与 AF-G0–G5](../planning/AF-1/plan.md)、[详细 spec / 用户故事](../planning/AF-1/spec-details.md)、[18 项操作脚本与 CP-01–03](../planning/AF-1/acceptance-scenarios.md)、[机器映射](../planning/AF-1/contract.json)细化现有 AF-R/AF-A/S00–S08，不建立第二份实时状态。本文仍是当前状态权威。

总 Goal AF-G5 只有在同版源码/包/服务上，AF-A01–18、AF-U01–12 和研究交付、变化跟进、本地日程三条组合路径全部通过才完成。AF-G0–G4及AF-GD可以分阶段签收；基线准备、短模型探针和组件通过均不关闭总 Goal。即时云端变化推送与云电脑分别按扩展范围验收；已知时间本地提醒不作 APNs 证据。

用户已明确以iPhone体验为主、借鉴桌面Codex信息结构。新增必需设计Goal AF-GD及[UX-1规格](../design/ios-codex-experience-spec.md) / [AF-U01–12](../acceptance/ios-codex-experience-acceptance.md)，并纳入AF-A17和总AF-G5。同版18项父验收、12项UX细分及三条组合路径全部通过才签收。前期Catpaw原图与ChatGPT/dot观察已核对，具体[对照记录](../design/ios-codex-reference-review-2026-10-13.md)保留证据边界；[可点按提案](../design/prototypes/catpaw-ios-ux/index.html)已准备，[浏览器样例交互检查](../acceptance/ios-ux-proposal-review-2026-10-13.md)通过；设计方向待用户审阅，原生UX验收NOT_RUN。Goal/验收映射、文档链接/截图hash、冻结资产完整性与候选敏感扫描通过，结果仅限本轮规划和合成提案。设计逐片推进，许可/模型首片继续。

1. 每片固定source/合同/case；交源码、证据层、未验项与下一步，实时状态只更新本页。
2. 真实模型试验限定数量与结束条件；旧unknown只读核对。现有路由失败后才讨论切换。
3. 验证范围因变更、失败或风险扩大，不为测试数重复跑。构建与真机性能分别记录。
4. 原始本地历史不推远端；main经检查的差异/PR推进，不force、不拼接无共同祖先历史。连接器发布后读回commit/tree并对齐维护分支。
5. 云电脑方案未确认不实施。用户已批准冻结build16更新原手机与最多2次正常App短文本原路由验收；后续新包/新增范围另行确认。继续与方案无关的开发。
6. AF-G5须同候选18A/12U/3CP全部通过；FINAL-G1与FINAL-G2再按原合同同候选成立才关闭本运行FINAL-G3。云电脑扩展按独立确认范围；缺证据不算通过。

## 最近验证

2026-10-14继续同一个ACTIVE FINAL-G3，由三个内部Agent分别实现/审查来源端口、原生成果与动作合同，主线整合真实维护API/两种worker并固定[W31a/W32a日期证据](../acceptance/restart-sourced-results-2026-10-14.md)。156全量后台离线、6单独恢复探索、37三工具续聊、74 localhost HTTP/SSE、15解析内层场景与最终7原生XCTest PASS；Release模拟器0.3.0(19)、79宿主成员/777双语及治理/敏感/空白PASS。保留续跑/最后await撤权负对照、NEL原字节RED→GREEN、UI离屏/固定浮层手势定位和截图发现来源辅助字号未继承后的修复。八张最终Simulator合成截图带版本/hash，不能签收真实设备门。默认route hash不变，API19/tick7不改；生产Auth/公开GET/模型/PG、手机安装/部署/推送/付费计算均0，build16两文本额度未耗；终态改稿、原生待决、系统effect、W33/W50/W60及全部release门继续未完成，Goal ACTIVE。

2026-10-14沿同一个ACTIVE FINAL-G3由三个内部Agent分工持久计划、原生修改/恢复与GenUI本地状态，主线审查实际接线并固定[W30a日期证据](../acceptance/restart-plan-recovery-2026-10-14.md)。87后台离线、25最终原生XCTest（18单元方法/7实际UI）、21续聊/16队列/26状态边界、77宿主成员与751双语检查PASS；Release模拟器0.3.0(18)同production source可构建。新增原许可有界修改续跑、accepted/applied回执、原operation GET、两份草稿、合法长计划与SwiftData无效输入冷启动；修复本地/服务端空间混淆、计划卡遗漏/子标识、表格重复标识和精确负值舍入提示。失败与测试手势的键盘/inset定位保留；最终合成计划截图留忽略build且记录版本/hash。目录/冻结/MIT/受控patch/部署来源/规划/敏感与空白PASS。API19/tick7快照不改，真实Auth/模型/SQL/手机/部署/推送/付费计算0；AF-A07/CP-01、全部release门与运行Goal未关闭，继续真实路径和W31/W32。

2026-10-14明确建立并启动FINAL-G3长期Goal，核对原基础合同后由三个内部Agent分工续聊恢复、后台权威写入和GenUI核心，主线整合原生交互并固定[首片证据](../acceptance/restart-agent-start-2026-10-14.md)。最终6/6原生回归包含实际流式期间本地输入/筛选、引用草稿和阅读锚点；初始失败、原生标识修复、导航可见区修正与截图发现按钮遮挡后迭代均保留。维护后台5项租约RED→GREEN、Deno 67/67、Swift 21/16、精确算法64/64通过；Release模拟器0.3.0(17)可构建，713双语条目、69宿主成员有效。两张最终合成模拟器截图带版本/hash，私人手机内容未导出。治理/规划/敏感与空白检查通过；真实模型/SQL/手机/部署/竞品与全部release签收门保持未验，Goal ACTIVE。

2026-10-14按用户要求收齐最新内容并通过PR #8整合main。R5日期记录的47项输入／截图／保留R4来源hash逐项匹配；保留前次已发布的FINAL原型行尾空格修正，刷新当前Goal映射与精确误报复核，不改写日期证据。目录／冻结／部署来源、AF／Goal／FINAL／CG规划、敏感扫描与完整候选空白检查通过。候选不含同期GenUI业务开发改动；原生／真实模型／SQL／设备与产品签收状态不变。

2026-10-14根据用户提供的10张手机截图完成[UX-1 R5移动端对话设计](../design/mobile-conversation-reference-r5.md)、[参数](../design/mobile-conversation-reference-r5.json)和[可操作样机](../design/prototypes/catpaw-mobile-reference-r5/index.html)。图1–9与图10的视觉系统分别分析，不冒称Codex官方tokens或动效证据；私人原图仅在忽略目录按版本／hash归档。当前方向为白／近黑阅读面、深蓝本人消息、亮蓝操作、17号／1.6行高／24段间距，补紧凑／多行／全屏输入、来源、消息／会话／附件菜单与处理事件。停止正文与暂停工作独立；相机／正式分支／重新回答等保留候选合同边界，语音对话不纳入。UX-1、启动合同／prompt及72项来源同步；R4／R4.1和其他作者同期prompt改进保留。

45组不透明语义色计算通过（所列小字最低4.8543、必要轮廓最低3.4444）；54组375／390／430 CSS视口的浅深色／普通放大字／阅读输入审批及菜单无横溢出，可见目标与决定区可达。复查全屏保稿、工具追加草稿、来源关闭回焦、各会话附件／草稿恢复、失败禁用停止、流中权重75与草稿保留、暂停申请等待独立人工回执，保存7张默认视口截图，见[日期证据](../acceptance/evidence/mobile-reference-20261013-r5/RESULT.json)。这些是人工浏览器样机和静态检查，原生玻璃／触觉／系统键盘／光标选区／VO／真实执行和所有release门保持未验。未修改App／后端、增加依赖或进行模型／SQL／安装／部署／发布；没有关闭运行Goal。

2026-10-13按用户要求，综合当前docs产品／UI交互／架构／研究／验收与历史索引，完善既有[长期目标与可验收prompt](../planning/AF-1/long-task-development-prompt.md)。补现状日期摘要、文档职责、AF-G5／FINAL-G1–G3分层终点、CP-01–03实际步骤、GenUI边界／算法真值、持久与unknown语义、原生矩阵／性能样本、7天日用和BP配对规则。保留同期另一作者新增的R4.1配色、R4连续机制、R3完整状态及已有WIP；未另建规格或运行Goal。现场本聊天get_goal返回空，交接usageLimited不被推定为本聊天当前状态；其他聊天未查询。

本次目录、冻结来源／精确patch／MIT、部署快照、AF／Goal／FINAL／CG规划检查及diff空白检查通过，66项来源hash一致；仅更新E35的prompt hash。敏感扫描初次因映射文件hash变化，重新命中三条既有历史来源文件名；逐项核对原file字段／行号未变且为来源标识后，追加精确path／line／hash复核，规则未放宽，复扫无阻断或待审项。检查仅证明文档／来源一致性，不关闭产品用例。未修改App／后端，未真实模型／PG／设备测试、安装、部署、发布或安排日用／比较；全部产品未验状态保留。执行输出与修订前快照留忽略build目录。

2026-10-13根据用户提供的移动端Agent对话研究，完成[UX-1 R4.1配色与UI细节修订](../design/codex-color-detail-r4-1.md)、[语义色参数](../design/codex-color-detail-r4-1.json)及[新版样机](../design/prototypes/catpaw-codex-color-r4-1/index.html)。完整读取原文与6张内嵌图，区分Codex Remote、ChatGPT／Grok与插件示意，采样不标成官方tokens；原文／图留忽略本机目录。中性白灰／炭黑替换大面积靛蓝，紫色强调图标发送／文字操作，审批用黑白主按钮，辅助字提高到约13–15px。原R4引擎／CSS／SVG／生成图和日期证据不改，新版仅覆盖构图与样式；UX-1／启动合同／prompt同步，66项来源hash。

52组不透明语义色对比计算PASS（文字最低5.3048、必要图形最低3.0921）；不代替玻璃合成与原生实际取色。24组375／390／430 CSS视口×浅深色×普通／放大字×对话／审批无横溢出，测试可见触控区约44px，决定区在框内；中大档切换确认区纵坐标差约0.01px。额外复查抽屉保稿／焦点返回、详情返回、锚点菜单与图片回源，保存4张默认视口截图。原R4数值检查未重复宣称为新测试，网页放大字不等于最大Dynamic Type。规划／66项来源／冻结／目录／链接／敏感／diff检查PASS，见[日期证据](../acceptance/evidence/codex-color-20261013-r4-1/RESULT.json)。没有生产源码／后端／依赖／模型／SQL／安装／部署／发布变化；原生材质、触觉、系统键盘、VO、真实执行与全部产品Goal未验状态保持。

2026-10-13按用户提出的“效果优先、跟手／连续／可打断”完成[UX-1 R4原生交互与动效附录](../design/native-interaction-motion-r4.md)、[机器参数](../design/interaction-motion-r4.json)及[独立交互样机](../design/prototypes/catpaw-motion-study-r4/index.html)。并行完成App专用taste-skill生成的两张视觉方向图、解析弹簧和原生机制审查；新暖白／深靛蓝构图不沿用R3页面壳。R3完整42项对象场景与R2日期输入、A1／冻结tokens／合同保留。更新UX-1、启动合同／prompt与61项来源hash；没有新增release门或改变运行Goal。

实际浏览器拖动观察包括抽屉开关保稿、详情短拖取消／长拖回原位置、审批中大档切换且决定区坐标不变、图片关闭中向上接管回大图／下拉回源、锚点菜单与前景焦点返回、关闭编辑保稿／v2重新审阅／一次合成回执。三段正文补充期间滑杆值、焦点和可见偏移不变。24组校准后的375／390／430 CSS视口×浅深色×普通／放大字×对话／审批无横溢出、可见触控区约44px且决定区可达；手机模拟框有页面边距，不作为原生设备尺寸证据。13项独立弹簧／方向协调数值检查PASS；早期图片反向接管失败、精度跳变与viewport校准均保留迭代记录，修正后复查。规划／来源hash／冻结／目录／JS／敏感／diff检查PASS；[版本证据与4张截图](../acceptance/evidence/motion-design-20261013-r4/RESULT.json)区分浏览器观察、数值检查和限制。原生系统玻璃／scroll edge／触觉／键盘／最大Dynamic Type／VoiceOver／pinch／持久恢复与真流均未由本样机签收。未改App／后端、未加依赖、未请求模型／SQL、未安装／部署／发布；原18A／12U／3CP／9FQ／10CG／日用／竞品与运行Goal状态不变。

2026-10-13完成[UX-1 R3完整交互设计](../design/interaction-scenarios-r3.md)：保留R2视觉基线与旧提案，交付[14入口可操作Demo](../design/prototypes/catpaw-interaction-r3/index.html)、[42项场景映射](../design/interaction-scenarios-r3.json)、原生落点/相对成本和4张版本截图。补侧滑/搜索/草稿恢复，过程展开/停止文字/安全点暂停，Sheet开关/下拖/保稿/放弃/同层返回，卡片未就绪→就绪→受理→生效，表图/权重/精确数值输入/同工作跟进，以及多待决/版本失效/未知原操作核对/交付恢复。原12U/10CG与开发prompt同步，49项来源hash；不增加release门或启动Goal。

浏览器新增六场景72组尺寸/外观/字号无整页横溢出；12组审批布局、375大字键盘边界已查，发现25px home strip重叠后修正复验。实际拖动抽屉与Sheet关闭、焦点返回、后台3段正文中表单/位置稳定、两套算法真值、无效值与旧审批禁用、双击同一操作和unknown无重复写入已作合成观察。正文结束与工作暂停分轴保留。规划/冻结/布局/链接/JS/敏感及diff检查PASS；[日期证据](../acceptance/evidence/interaction-design-20261013-r3/RESULT.json)记录迭代失败读数、最终修正、source/截图hash与限制。慢速短拖/pointercancel、原生detents/VO/触觉/冷启动/部分效果复合事务和性能仍需原生/领域验证。未改App或后端、未新增依赖/模型/SQL/安装/部署/发布，真实产品验收与运行Goal保持原状态。

2026-10-13按用户指定taste-skill完成[UX-1 R2视觉、交互与动效附录](../design/taste-visual-motion-r2.md)及[机器参数](../design/taste-visual-motion-r2.json)，保留R1产品行为、A1、冻结tokens、原生入口与全部验收门。采用native HIG、系统字体/SF Symbols与系统转场；补当前决定/成果/输入的层级、180/240/280ms有限运动、触觉事实门、减弱动态/透明度和焦点/阅读锚点规则。已同步UX-1、原12U/JSON及启动合同/prompt，没有实施新的App壳或改变运行Goal。

[可点按R2提案](../design/prototypes/catpaw-taste/index.html)覆盖8个人工场景，实际浏览器检查流中选择、两份草稿、审批关闭重开/unknown、跟进编辑保留、时间试算负值/无效参数、离线草稿与搜索；375/390/430 CSS屏框×浅深色×17/30px审批矩阵12组合及375大字号键盘占位可达。44组语义配色计算通过，正文最低5.0319、必要轮廓最低3.0682；此为token计算，不代替实际原生取色。有限运动在预览可操作，未测量原生帧/手势/VoiceOver/系统最大字号/触觉。四份人工设计截图与来源hash、检查/扫描范围见[本轮证据](../acceptance/evidence/taste-design-20261013-r2/RESULT.json)。仓库布局、冻结身份、AF/FINAL/CGUI规划检查通过；41项Goal输入固定。JPEG元数据与旧文件名的扫描误报按精确hash复核，规则未放宽。真实模型/数据库/设备/安装/部署/发布均0，本轮设计不关闭产品验收。执行缓存与WIP前快照留忽略build，旧日期证据保留。

2026-10-13完成用户要求的[产品与视觉交互评审R1](../design/product-experience-review-2026-10-13.md)：收紧体验承诺、主要用户与CP01首个价值路径，补可修改默认值、活动/管理层级、单工作摘要、当前待决、明确修改模式与两份草稿、成果复制/分享、首用权限节奏和克制反馈；已回写FINAL-1、UX-1、CGUI-1、原12项UX细则/JSON与[启动合同](../planning/AF-1/development-start-contract.md)/[prompt](../planning/AF-1/long-task-development-prompt.md)。全部18A/12U/3CP/9FQ/10CG、7天日用与BP门保留，运行Goal不切换。

人工HTML提案修正日程关联错误计划、重复大计划卡、退出修改的草稿与静默开关丢字段；新增首用示例只填草稿。浏览器验证两份草稿、审批关闭重开/unknown、跟进字段、成果冲突保稿与分享说明，390px人工屏框浅色17px/深色22px样例和截图已保存，属于合成提案评审；不是原生Dynamic Type、系统分享或真实写入。Tabbit连接不可用，改用Codex内置浏览器，没有安装依赖或绕过安全页。4项规划检查、36项来源hash、冻结完整性、敏感扫描及空白检查结果见[本轮证据](../acceptance/evidence/product-design-review-20261013-r1/RESULT.json)。初次敏感扫描命中机器路径、两份JPEG与三条旧文件名；路径移除，JPEG像素/元数据复核，旧文件名仅按新精确hash续核，扫描规则未放宽。真实产品状态保留；本轮未改原生源码、未调用模型/PG、未安装/部署/发布或启动开发Goal。评审前WIP快照保留在忽略build执行目录，旧日期证据不改写。

2026-10-13完成[对话UI与onboarding复核](../research/copilotkit-conversation-ui-onboarding-review-2026-10-13.md)：OpenIntelligentUI固定main读回与既有pin一致，6个选读文件blob／字节hash核验；第二链接实际是2058字节Markdown CLI提示，响应hash已固定，未执行CLI。采纳[CGUI-1](../design/conversation-generative-ui-spec.md)原生table/bar/line、两个确定计算内核和三类动作；本地调整零请求，明确跟进经新turn或安全点接同工作，写入仍精确审批／effect。10项CG必需细分已接FINAL-G1/G3与FQ，不替代18A／12U／3CP或改写冻结HTTP。

本轮基础切片／Goal、FINAL、CGUI机器规划检查，35项输入hash、算法真值、来源身份与合同链接、冻结完整性、敏感扫描及diff空白检查PASS，范围见[日期证据](../acceptance/evidence/conversation-ui-plan-20261013/RESULT.json)。开发范围、spec与验收合同可用于[长任务启动](../planning/AF-1/development-start-contract.md)；[prompt](../planning/AF-1/long-task-development-prompt.md)仅供用户复制，未由本轮启动Goal、开发、安装或调度。模型／真实PG多实例／独立调度／物理设备／日用／竞品对照未执行；所有产品未验状态保留。SDK/Intelligence及云电脑托管仍须各自具体方案和资源门，现有route、新增compute 0及既有短文本授权边界保持。

2026-10-13完成[Grok分支与本地方案整合核读](../research/grok-companion-integration-review-2026-10-13.md)，固定commit `38c44457`的17个选读文件Git blob/size/byte hash全部PASS；新增E23–28进入28项hash输入。FINAL-1明确流中可操作六卡、同工作修改、持久待决/精确审批、unknown核对、成果冲突、why-now、手机跟进编辑和记忆控制；采纳原因/控制，修正四Tab/假执行/无来源排名。当前维护工程、A1、原route、预算与冻结合同保留。FINAL规划检查（3Goal/9FQ/8BP/4参照）、基础Goal/切片映射、文档链接、冻结来源、敏感扫描和diff空白PASS。人工交互提案JS语法PASS；本地file URL被浏览器安全策略拒绝，未绕过，浏览器视觉/交互验证NOT_RUN，不构成原生证据。本轮未调用模型/SQL/设备，未新增依赖、导入生产代码、部署或发布；新FQ/BP与产品未验状态保留。Supabase当前Edge/Cron文档已核对作为设计限制；changelog抓取失败，不宣称已审查其变更或现有项目资源可用。

2026-10-13完成用户指定[四仓源码静态核读与决策修订](../research/copilotkit-four-repo-decision-update-2026-10-13.md)，commit及54个关键文件blob/byte hash见[研究来源manifest](../research/copilotkit-four-repo-source-manifest-2026-10-13.json)。新增输入E17–22，补细既有plan/spec/UX与AF-A16、AF-U06–08：后台持久待决、审批消费/结果/续聊恢复、成果版本冲突、受控registry和参数完整门槛。Goal/切片检查、22项输入hash、166条固定源码链接及19个本地链接、冻结来源完整性、敏感扫描和diff空白检查PASS；敏感扫描对三条既有catdesk历史文件名的误报仅续核原精确path/line/hash。无生产代码导入、依赖安装、模板运行、模型/PG/设备请求或部署；AF-1-G3-UX1、当前W10–12关键路径、原路由和新增计算预算0不变，所有产品未验状态保留，不继承上游测试为产品PASS。

本轮追加侧栏/草稿片：同源码43原生＋5实际Simulator UI、侧栏包12项、non-DEBUG SDK源码和680双语资源PASS；首次中文系统取消定位失败已留档并完整复验。三张原生截图与source/log hash保存。未发图片切换保留限当前App会话，未扩展冷启动持久化范围。物理手机/真实模型0次，全部AF-U05及总Goal尚未签收，见[本片证据](../acceptance/restart-sidebar-drafts-2026-10-13.md)。

新仓复现getter编译FAIL，已修正；最终39原生＋1 UI、产品配置build、便携对话/队列、源码/本地化、完整性与敏感扫描PASS。追加[阅读锚点回归](../acceptance/restart-reading-2026-10-13.md)真实滚动＋共用许可UI 2/2、非DEBUG SDK源码检查与666双语资源PASS；该修复不在冻结build16中。build16签名构建及同身份覆盖安装PASS，系统读回16；镜像待恢复，真实模型0次，未部署云端或tick。实际部署源码50/43文件hash及14项差异PASS。原始日志和IPA在忽略build目录；精简证据见[许可回归](../acceptance/restart-permission-2026-10-13.md)、[build16](../acceptance/restart-build16-2026-10-13.md)、[安装](../acceptance/restart-install16-2026-10-13.md)和[部署来源](../../services/edge/deployed-baselines/README.md)。

## 仓库架构与开发规则（2026-10-13）

已核对目录、主App依赖、GitHub分支/PR及旧工作树；目录角色、分层AGENTS、CLI hooks与分支规范已建立。8个远端/4个本地已整合分支已删除，tip/完整历史bundle/51项原WIP已备份；新增规范按独立文件清单经PR同步，不夹带其他作者正在写入的规划/设计。未改业务源码、模型、包、部署或运行Goal；产品验收保持原未验结论。维护入口为catpaw-api＋_shared，tick独立入口仅存在部署来源，后续源对齐仍待逐片验收。[完整审查](../architecture/repository-review-2026-10-13.md)、[分支规范](../development/branch-management.md)。

2026-10-14用户明确继续并要求从底层共性解决问题。三个新内部Agent按不冲突文件边界执行：execution_fences统一维护worker租约/结算与unknown保护；native_layout收敛语义字号桥接、版本标题、真实编辑viewport/caret和Sheet环境；native_controls交同Task暂停/恢复/撤权的typed原生领域/持久日志/应用服务/页面。主线整合HTTP/账号生命周期/宿主、fresh source logout与删除屏障、证据及验证。旧Agent额度错误保持日期事实，不当当前三路状态。初步“暂停被failed覆盖”诊断已纠正：旧注入在同一事务内被整体回滚；跨独立事务pause/revoke/takeover的两worker用例已通过，另已独立复现live lease被接管、已dispatch后abort误排队的维护whole worker缺口。W33/共享布局仍是未提交实施中，不签收真实门；本轮无生产请求、安装或部署。
