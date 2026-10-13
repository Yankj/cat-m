# Catpaw 长期目标与可验收开发 prompt

整理日期：2026-10-13（Asia/Shanghai）。本文综合现有docs的产品、UI交互、架构、研究与验收合同，供用户复制启动后续开发。本次整理不执行正文，也不创建/切换运行Goal。权威与授权边界见[启动合同](development-start-contract.md)，实时状态只见[master-plan](../../status/master-plan.md)。

## 现状分析

项目已有明确的产品方向、完整验收合同和局部原生修复，尚未证明完整的日常Agent工作循环。主要缺口是现有模型路由真实闭环、同版本交付、持久任务与真实数据库恢复、独立调度、系统动作和原生整体体验。继续增加提案或组件数量不能关闭这些缺口。

以下是本次读取的日期摘要；后续执行须回到主计划和现场核对，本文不滚动维护状态。

| 层 | 2026-10-13读取事实 | 对后续开发的含义 |
|---|---|---|
| 维护源码 | 本地HEAD为`9dc9cd9`，tree为`cd961a8`，分支`docs/restart-design-integration`；有其他作者的文档WIP | 不全量暂存或重置，不用HEAD代表全部设计输入；本次未重新读取远端 |
| 手机 | 记录为`0.3.0(16)`、冻结源码`a905b47`，不含后续阅读、队列、侧栏与草稿修复 | 源码通过与手机通过分别记账；后续安装先准备具体候选 |
| 后端 | 最近部署证据为API v19／tick v7，维护代码和部署快照尚需对齐，tick入口目前只在快照 | 不继承旧部署为新源码通过，不直接覆盖共享来源；本次未查询云端 |
| 局部验证 | 最近侧栏／草稿片为43项原生状态、5项实际Simulator UI及12项组件检查 | 限固定源码、离线fixture和单一Simulator；未发图片保留不等于冷启动持久化 |
| 产品验证 | 主计划记录本轮真实模型发送0次，基础、日用与竞品尚未签收 | 先定位许可→受理→原模型→事件→存储→展示；旧build15等待不证明provider失败 |
| Goal | 本聊天`get_goal`返回空，交接中的`usageLimited`是另一时点快照 | 不推断其他聊天当前状态；启动时读实际Goal，不沿用旧状态创建替代Goal |

**基础签收与长期终点分开：AF-G5＝18A＋12U＋3CP；FINAL-G1再加9FQ、10CG及7天日用；FINAL-G2按8BP证明限定优势；FINAL-G3在G1/G2同候选成立时完成。** 云电脑、即时APNs和语音按各自扩展合同处理。

## 文档采用关系

| 文档组 | 本文采用的职责 |
|---|---|
| [AF-1](../../product/agent-foundation-spec.md)、[详细规格](spec-details.md)、[计划](plan.md)、[机器合同](contract.json) | 通用底座、稳定需求ID、领域权威和W/D依赖 |
| [FINAL-1](../../product/catpaw-final-product-spec.md)、[产品评审R1](../../design/product-experience-review-2026-10-13.md) | 体验承诺、合理默认值、首个价值路径、日用质量与竞争假设 |
| [UX-1](../../design/ios-codex-experience-spec.md)、[R3](../../design/interaction-scenarios-r3.md)、[R4](../../design/native-interaction-motion-r4.md)、[R5](../../design/mobile-conversation-reference-r5.md) | 页面与返回、42项状态、连续操控、配色细节；R2保留日期输入，网页样机不证明原生采用或通过 |
| [CGUI-1](../../design/conversation-generative-ui-spec.md)及JSON | 六种领域卡、受控表图、确定试算和三类动作 |
| [18A](../../acceptance/agent-foundation-acceptance.md)、[12U](../../acceptance/ios-codex-experience-acceptance.md)、[CP脚本](acceptance-scenarios.md)、[FQ/BP](../../acceptance/catpaw-final-product-acceptance.md)、[CG](../../acceptance/conversation-generative-ui-acceptance.md) | 通过断言、量化门、证据层和完成条件 |
| [架构审查](../../architecture/repository-review-2026-10-13.md)、ADR、[研究索引](../../research/README.md)、[来源映射](goal-evidence-map.json) | 现有系统职责、复用机制、来源/许可和待确认选型 |
| 历史产品、v1/r2/r3、旧验收、根design/research与日期证据 | 保留已交付身份、反例、失败与来源；不覆盖当前方向、不扩大授权 |

复制下方完整正文到本项目开发聊天。执行时核对最新用户指令与权威文档；本文不能替代后续具体安装、真实测试、部署或资源批准。

## 可复制正文

```text
在当前 Catpaw-m 主维护仓库中继续开发 Catpaw。终版交付终点是 FINAL-G3：Swift 优先、iPhone 体验优先的通用主动 Agent App。体验承诺是“把你交代的事变成可用成果；需要你时说清楚，回来时接得上”。持续完成实现与必要验证，不停在规划、骨架、合成Demo或组件通过。

【长期目标与分阶段完成】
主要用户是在手机上短暂交代、途中调整、稍后查收的个人。自然对话提出目标，原生交互作决定，实际成果验收工作；离开后已受理云端工作继续，回来接同事项。普通问题直接回答，通用性用同一底座组合不同工作证明。
AF-G5基础门要求同一发布候选AF-A01–18、AF-U01–12、CP-01–03全部通过；FINAL-G1在基础门上再通过FQ-01–09、CG-A01–10和7天真实日用；FINAL-G2要求BP-01–08具名竞品记录齐备并满足每个参照的比较规则；FINAL-G3只有G1/G2同候选成立、源码/包/部署/证据可追溯且无必需阻断才完成。可以交付已通过阶段，缺少比较证据就保留长期未完成条件和限制，不偷删必需项。

先读 AGENTS.md、README.md、handoff.md、docs/status/master-plan.md、docs/planning/AF-1/development-start-contract.md 和 docs/design/product-experience-review-2026-10-13.md；沿链接读 AF-1、UX-1设计修订R5以及 docs/design/taste-visual-motion-r2.md、docs/design/taste-visual-motion-r2.json、FINAL-1、CGUI-1 的规格、验收、W/D依赖与来源。检查当前工作区、活跃owner和运行Goal实际状态，保留未提交工作。已有Goal按其合同继续，不覆盖、偷换或重复创建；AF-1-G3-UX1基础门与FINAL-G3终版门分开，usageLimited等受限状态不能绕过。

同时读docs/README.md、docs/status/local-integration-source.json、docs/acceptance/local-fixed-directory.md、docs/development/branch-management.md和docs/architecture/repository-review-2026-10-13.md。盘点现有docs，区分当前规格、验收合同、日期证据、历史来源和待确认提案，沿索引读相关全文。最新人类决定优先；AF-1管领域与协议，FINAL-1管产品和质量，UX-1及附录管呈现，CGUI管受控交互，验收合同裁决完成，master-plan管当前状态。R3状态、R4连续机制、R5移动视觉／过程／菜单按职责组合，R4.1保留日期输入，不按日期全盘覆盖旧合同。未Accepted的runtime/托管方案不当成已决定，参考图不当官方tokens；范围或阈值变更先版本化。历史PASS与交接快照不能沿用成当前事实。

读取 UX-1 时，同时读取 docs/design/native-interaction-motion-r4.md、docs/design/interaction-motion-r4.json 和 docs/design/prototypes/catpaw-motion-study-r4/README.md，并读取 docs/design/mobile-conversation-reference-r5.md、docs/design/mobile-conversation-reference-r5.json 和 docs/design/prototypes/catpaw-mobile-reference-r5/README.md。连续机制沿R4，当前移动端视觉、过程与菜单沿R5：白／近黑阅读、亮蓝动作、深蓝本人消息、正文17／行高1.6／段间24起点、三态输入、就近来源和消息／会话／附件三类菜单。R4.1保留日期候选，不把采样当官方tokens。语音对话不纳入本轮；相机／正式分支／重新回答／空间等未接能力只作候选，正式版隐藏未接入口。过程从真实受控事件投影，现事件无elapsed，只有有依据时才能显示耗时；stopObserving不等于取消输出，暂停申请须等权威回执。R3 md/json 保留完整对象状态与42项场景索引，R2保留日期输入。R4样机和App专用skill生成图仅是效果评审输入：实现跟手抽屉、当前可见位置接管／反向打断、距离与速度吸附、可取消详情返回、medium/large审批面板与固定决定区、锚点popover/contextMenu和图片回源。按手势owner表排除字段／横向表／滑杆，详情期间禁用根抽屉；系统ScrollView保留惯性／边界回弹，导航／Sheet／zoom／键盘／玻璃／触觉优先系统API。真正连续控制需测动画中途接管，不能只把easeOut换成spring。稳定block＋像素偏移保存阅读，现有卡／字段不重建；View和动画不授予执行权威。

先沿 W10→W11→W12 验证许可→原operation→现有provider→事件→存储→UI，按最新记录核对冻结build16和最多两次短文本的剩余授权；unknown只读核原ID。先验原模型route，记录失败段后再讨论切换，不自行换provider或付费fallback。真实阶段待授权时继续可独立的源码与离线工作，不把真实验收状态改成通过。

随后先贯通 CP-01：三份公开资料→可修改计划→真实读取→有来源的可读报告→离开/返回→同成果改稿；再沿依赖完成记忆、CP-02变化跟进、CP-03本地日程与提醒。全部范围保留，同一套领域对象组合三路径。设计与功能同行：每片明确当前事实、用户下一步、修改/停止入口和失败/返回恢复，交付整条用户路径。

【三条可验收用户路径】
CP-01研究交付：正常对话给三份公开URL→必要澄清/持久计划→修改维度仍同Task→真实读取/时间/receipt→三条结论、对比表、可点击来源的成果→云端受理后离开→原对话/Inbox同version/hash→补风险形成新版本，旧版可追溯→保存格式记忆，在新会话复用并查来源。关键事实按固定资料真值，虚构引用或CLI补写成果才能继续即FAIL。给定URL读取与自主搜索分开，无实际工具不冒充实时查询。
CP-02变化跟进：对话创建时区/频率/预算/静默/结束约定→v1基线→不变零新消息→App/Mac离线跨两次真实due，受控公开页面变v2→一个变化成果/Inbox→重复v2不多提醒→错误退避，恢复不重发→手机查依据/why-now→暂停后跨下一due无新增，结束不自启。不可人工tick或常开Mac冒充独立调度；未知云变化即时锁屏推送另按APNs扩展。
CP-03本地日程：明确测试日期/时区的20分钟会议→核对目标日历/标题/起止/提醒→关闭重开审批→改时间旧卡失效→拒绝系统权限无写→重新允许并精确批准→一个真实EventKit对象/持久effect→锁屏实际已知时间提醒→点击回同事项→更改/删除只处理同对象并同步提醒。跳转日历或“已安排”文字不算创建；设备离线等待。
三路径同底座、同候选，用户通过正常App入口完成，不需开发者CLI代操作。AF-R01–12全部保留，包括真实图片、上下文历史、持续责任、可控记忆和能力诚实展示。

按R1产品取舍、R4连续交互与R5移动端细节执行：普通问题直接正文；非关键格式使用可修改默认值，已给信息不重复问。首屏是对话和合一输入器，活动统一待决/成果/运行；每项工作一个稳定摘要，当前待决突出，完整计划进详情。修改模式显式关联工作并可退出，聊天/修改草稿分别保留。审批可找回、关闭不决定，精确写入只在真实回执后成功。成果先实际内容，来源/版本可查，复制/系统分享可用，未接格式不假导出；主动无变化静默。采用系统字体/semantic色/SF Symbols，内容与控制层有明确分工，按R5中性白／近黑与局部亮蓝动作、本人深蓝和可读辅助字映射原生角色；保留历史冻结tokens和A1。局部按压与有限状态动效采用R4预算；抽屉由跟手位移、释放速度和持续弹簧收束，不用固定280ms开关曲线。导航/sheet/zoom/键盘采用系统，动效取消／返回／完成与领域回执分开。动效不夺焦点/阅读锚点，不逐token动画；降低动态/透明度和大字号有功能等价路径，真实新回执才一次成功反馈。逐片实现D00–D50，与原12U同版验证。

实现受控Swift原生GenUI：六类领域卡及同数据的table/bar/line、两种登记计算内核。按任务选择呈现，不把所有回答做成仪表盘；局部排序/调参零新增请求，明确跟进才提交原会话/工作的新turn或安全点修改。持久写仍走typed command、revision、精确审批与effect。复用ios-conversation、Repository/SwiftData、Supabase和受控worker；每片先映射现有类型→API→存储，缺口兼容扩展，保留A1、用户数据、冻结HTTP、MIT与受控patch。不要全局重建执行栈或运行onboarding latest CLI。

【GenUI的具体断言】
六卡为choice/form/plan/approval/artifact/comparison；表图和calculator是presentation，不新建执行对象。完整schema与权威对象就绪才提交，部分参数/未知kind/version可读降级。稳定block/card/field ID使其他正文继续时输入、caret、焦点和锚点不丢。只编译内registry/renderer/kernel/action，不执行模型生成代码/公式。
完整payload≤64KiB；表≤12列×200行、单元格≤2000字符；图≤4序列×200点；来源≤20；标题≤200、标签≤80字符。超限给摘要与完整成果入口，不静默删源数据；表图同版本/单位/来源，图能回表和查原值。
duration_budget_v1：剩余=总时长−保留−步骤数×单步，统一分钟和十进制；60−10−4×8=18，保留15时=13，负剩余明确超额。weighted_comparison_v1为Σ得分×权重/Σ权重；甲80/40、乙60/90，3:1时70/67.5，1:3时50/82.5。按CG合同固定输入范围/舍入，验证NaN/Infinity、非整数步骤、全零权重和重置，显示单位/公式版本/来源或假设，人工分数不冒充竞品事实。
local_interaction连续调参10次零新增网络/模型/turn/effect；agent_followup显式“用此方案继续”才一次原会话/工作意图，经新turn/run或安全点继续；domain_command写计划/记忆/日历仍精确授权/真实receipt。同工作不等于同SSE双向中断，本地输入不是批准。完成解释试算与成果探索两条CG路径，至少一条真实模型→结构→原生交互→持久跟进→同工作继续。重开同版本选择，版本变化说明差异并保稿，旧选择不批准新动作，删除/换scope后旧回包不复活。

【持久权威与故障语义】
UI通过typed应用服务发意图，组件不拥有账号、HTTP准入或执行权威。保留operation/request hash、scope、epoch、sequence/cursor、revision、lease/fence、approval/action/effect/receipt；同Send一个逻辑意图，同ID不同payload冲突。SSE完整帧按sequence投影，JSON replay按Content-Type解码；EOF/transport成功不等于terminal，chat结束不等于Task完成，点击/批准/消费/执行/交付分开。
后台/弱网/冷启动先只读原operation/turn/cursor，不重发POST。已消费无结果保unknown；已存receipt但续聊/刷新失败只恢复交付。参数变更旧审批失效，同轮拒绝不换toolCall绕过；取消安全点停止后续步骤，不伪撤回既有效果。真实PG双执行者、旧lease/权限、checkpoint接管、撤权/换scope要验；版本、记忆generation、删除tombstone、due去重与Inbox/outbox事务一致。迟到job/回包不覆盖新改稿、不复活删除、不越scope，每步成功有实际记录，不把finish_task画成全部变绿。

在用户明确允许内部子agent时，按明确端口、互不冲突文件分配独立单元，由你统一集成；不要另建用户聊天或向旧任务发消息。每片交可构建源码、适用回归、证据hash/层级/限制和下一路径，当前进度只维护master-plan。提交前跑完整性与敏感扫描，GitHub操作遵守已有具体授权；旧日期证据不改写，合成/Simulator与真实模型/PG多实例/调度/真机分开。

【原生验收、性能与长期日用】
按R3场景表I01–I42逐项执行相关AF-U／CG断言；这些是原验收的设计细分，不建立另一套release门，也不以HTML回放抵扣真实原生／领域证据。
同候选覆盖正常/空/加载/等待/失败/离线/过期/unknown；375/390/430pt、浅深色、小屏键盘、长中文/真实IME、最大Dynamic Type、VoiceOver、Reduce Motion/Transparency、Increase Contrast。有效主动作≥44pt，正文/关键次字≥4.5:1、必要非文字≥3:1，实际渲染证据支持；无裁切/整页横滚/hover依赖。真机证明主路径与系统行为，Simulator补尺寸，不冒充多台物理手机。sheet决定栏可达、关闭保稿，抽屉中途反向/接管、详情取消返回、图片回源、菜单焦点回源、正文增长时控件/锚点稳定均实操。
性能按原合同，不降低门槛：回显p95≤150ms，基础≥20样本；终版本地交互/卡≥30样本；决定本地反馈p95≤500ms，合法完整卡事件到可操作呈现p95≤250ms；试算p95≤150ms且≥30真机本地操作；原route短答首字p95≤10s、完整terminal落盘可见p95≤60s，≥20获准真实短答；返回/重开正常网络5s内启动同turn只读恢复；两个真实due各≤120s受理，每due一个逻辑run，预算内成果或明确终止。
p95用nearest-rank，记录全部样本/失败/超时、冷暖/网络和误差；输入事件到物理可见帧计，provider回调、Simulator/Web不代真机。人类阅读时间单列，两次短探针不冒充性能签收。
FQ-01流中交互、02持久HIL、03手机主动闭环、04可见记忆、05成果质量、06原生设计、07性能、08持久执行、09日用及CG-A01–10全部必需。同候选7天真实日用至少10次会话并完成三CP，含跨日due、静默、回同事项，记录帮助/噪声/恢复/误操作。无P0/P1和必需FAIL：越权、隐私/数据丢失、双写、假成功、主路径不可继续为P0；稳定主要交互/恢复/无障碍失效为P1。无P0/P1不替代全用例通过。

【限定竞品优势】
BP-01–08分别对照对话阅读、流中决定、审批恢复、手机改计划、成果查收、克制主动、记忆控制、工作接续。参照Codex mobile、OpenAI dots、xAI Grok Bot、Meta Muse；开源模板不代实际产品。先固定版本/日期/平台/账户计划、同输入/真值、可见模型差异、结束条件与预登记指标，每适用任务≥5组AB/BA配对。
每个具名参照记录全部BP适用性，至少4项共同可执行任务有有效配对；关键正确性/授权/真实effect/数据保留/恢复不劣，至少2个预登记体验维度中位数改善≥20%且状态可理解，才限定说“在这些任务和版本上改善”。未支持是覆盖差异，不记耗时0/任意胜分；未取得版本/账户是NOT_RUN/BLOCKED，宣传资料不代测量，5组不推导市场或统计显著性。比较受阻不阻挡已确认产品阶段交付，也不关闭FINAL-G2/G3。

需要新包安装、扩大真实测试、部署、新依赖或资源时，先准备具体候选、改动、验证数量/预算/停止条件，再说明最小授权及出处，同时继续独立工作。已有Supabase先行，新增计算预算0；云电脑资源/provider/region未确认不实施。不能重置数据、用常开手机/Mac冒充独立调度或把两次短探针扩展成性能/日用许可。

独立调度仍是基础必需项，但现有套餐/实际Cron/配额/调用方/部署需核实，没有条件保留BLOCKED；不把免费套餐宣传当当前资源证据。云电脑AF-C01–03限方案确认后的无第三方登录网页/文件范围，试用赠额不当长期免费；即时APNs、语音、多Specialist、任意MCP/第三方登录等独立扩展，不混入本版必需门。
唯一维护App为apps/ios-conversation/CatpawM.xcodeproj，后端为services/edge/supabase/functions；历史App、vendor pin/MIT/controlled patch、部署快照和legacy-local保留。读适用子目录AGENTS，按短分支规则开发，不在main、不覆盖独立checkout、不整段merge/push旧历史。交付前跑check-repository-layout.py、check-repository.py、check-deployed-source.py、scan-repository.py、git diff --check及AF/FINAL/CG规划检查，再做受影响源码/行为检查。新QA用独立执行副本，不改冻结报告。Github发布遵守实际授权；CLI hooks不是服务器强制保护。按实际工时/等待/阻塞滚动估算，不继承旧一周/4–6周承诺。

【证据与最终交付】
验收结果只有PASS/FAIL/NOT_RUN/BLOCKED，缺证据不通过。静态/合成、Simulator、loopback、真实模型、真实PG多实例、独立调度、物理手机/系统、日用、竞品分层记账。历史PASS只覆盖固定输入，变更影响断言则重验。
证据绑定sourceCommit/tree或dirtyFilesSHA256、App/build/package hash、API/tick部署、协议、工具/route/模型、case/input/truth、scope、实际操作/起止/断言/限制；按适用项关联operation/turn/task/run、plan revision、approval/effect/receipt、artifact version/hash、trigger/due/outbox、网络/模型计数。不可见字段写unavailable，不伪造。截图保来源/版本/hash，私人手机/参考原图留ignored local-audit/screenshots；合成proposal不关原生验收，私密凭据/原图不进提交。
最终交同候选release manifest、可构建源码、包/实际安装和服务身份、18A/12U/3CP/9FQ/10CG证据索引、性能全样本、7天摘要、8BP配对与能力限制。进度/owner/阻塞只在master-plan，索引只链接，旧日期证据保留。

同候选18A、12U、3CP、9FQ、10CG和7天日用全通过，且BP满足具名竞品配对规则，才能关闭FINAL-G3。必需FAIL/NOT_RUN/BLOCKED保留；可准确交付已通过的阶段能力，未比较不声称优于。最终交源码/包/API/证据manifest与实际限制。现在读取现状，选第一条尚未通过且可推进的用户路径开始实施。

```
