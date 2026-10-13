# Catpaw-m 重启 Goal 与交付计划

更新：2026-10-13；唯一实时状态页。旧主计划完整保存在[2026-10-12快照](master-plan-2026-10-12.md)，旧失败与证据边界不改写。16:07交接事实与待提交文件见[handoff](../../handoff.md)和[快照](handoff-snapshot-2026-10-13.json)；快照不另维护实时进度。

**当前Goal（AF-1-G3-UX1）：交付可日常使用的Swift优先通用主动Agent iPhone App，体验对标Codex、能力对标Dot，并从唯一维护主仓持续同步GitHub。** 用户从自然对话交付目标，能够查看/修改计划、处理可找回审批、查收带来源版本的成果、管理记忆和持续跟进、从原生提醒回同事项；完整定义见[goal.md](../planning/AF-1/goal.md)。设计与功能同步推进，AF-GD为必需阶段；同版AF-A01–18、AF-U01–12及研究交付/变化跟进/本地日程三条CP路径全部通过才完成。2026-10-13 16:06运行Goal读回为`usageLimited`；产品尚未签收，本次交接没有改变Goal状态。云电脑用途为公开网页调研＋文件处理；现有Supabase先行、新增计算预算0，托管实施待确认。

需求：[AF-1 spec](../product/agent-foundation-spec.md)；验收：[AF-A01–18与AF-C01–03](../acceptance/agent-foundation-acceptance.md)；执行切片：[delivery-slices.json](delivery-slices.json)；云电脑提案：[Proposed](../architecture/cloud-computer-proposal.md)；接手：[handoff](../../handoff.md)。

终版产品方向与验收已整合为[FINAL-1规格](../product/catpaw-final-product-spec.md)、[质量／具名优势验收](../acceptance/catpaw-final-product-acceptance.md)及[交互状态提案](../design/prototypes/catpaw-final/index.html)。当前运行AF-1-G3-UX1仍按原基础合同推进；终版Goal不是一次文档更新就切换或关闭的运行Goal。

| 终版目标 | 当前证据与判定 |
|---|---|
| FINAL-G1 日常可信体验 | 合同已制定；原18A／12U／3CP＋9项FQ＋10项CG对话细分需同版真实证据与7天日用；NOT_RUN |
| FINAL-G2 限定竞争优势 | 8BP固定具名版本、输入与配对规则；尚无竞品配对测量，NOT_RUN，不能称优于 |
| FINAL-G3 终版产品签收 | 依赖G1/G2同候选；NOT_RUN，设计/静态检查不关闭产品目标 |

## 当前基线与证据

| 项目 | 实际状态 |
|---|---|
| 维护目录 | 用户指定的Desktop/ai-work/catpaw-m；应用入口 `apps/ios-conversation/CatpawM.xcodeproj`，服务端入口 `services/edge/supabase/functions/` |
| 代码迁移 | 已复制原生集成HEAD `582e4e4`、663个跟踪文件与12个未提交候选；候选hash逐项核对，旧源目录不修改；本地原始分支历史保留为legacy-local引用 |
| 最终handoff | 已读旧主仓handoff；用户确认相关任务停止。原文保存在忽略的local-audit；12项WIP与编译阻塞均相符 |
| 首个修复 | 新仓已复现并修复getter缺return；候选包含许可review与弹窗分离、稳定确认入口、队列折叠、持久回复证据；新增拒绝重开/旧revision回归，最终合成验证通过 |
| 本地检查 | 冻结合同/上游/历史来源完整性PASS；便携对话7/7、队列9/9 PASS；最终39/39原生＋1/1实际弹窗UI PASS，DeviceTrial无签名产品配置build PASS；证据限合成/Simulator，物理手机与provider未验 |
| GitHub | 本轮21项治理资料已由[PR #7](https://github.com/Yankj/catpaw-m/pull/7)合入main `9dc9cd9`，tree `cd961a8`与候选核对；本地main/origin/main/临时docs分支已对齐，所有工作文件原样保留。默认main、合并后自动删head已启用；8个已整合远端/4个本地短分支已清理，legacy-local的9个来源引用与旧工作树保留。稳定的R4.1及此前规划／设计／研究已收齐到docs/restart-design-integration候选，R5仍由其他聊天编辑并留作本地WIP；本次远端同步结果以Git分支／PR读回为准；规则采用本地hooks＋PR读回，当前私有仓库服务器保护不执行。详见[架构审查](../architecture/repository-review-2026-10-13.md)与[分支快照](branch-inventory-2026-10-13.json) |
| 手机/API | 用户明确批准后，同bundle覆盖安装0.3.0(16)成功，系统读回16；未卸载/重置数据，原有内容待UI核对。镜像从连接失败进入Mac认证锁定页，待用户Touch ID解锁；截图已保存到本机忽略目录。Supabase APIv19/tick7无部署变化；实际50/43文件、14项共享差异已同步 |
| 新候选包 | 0.3.0(16)，独立Git archive绑定原main `a905b47`；非DEBUG、严格签名、原证书/profile/entitlements及IPA逐字节PASS。已获安装及最多2次短文本原路由许可；尚未发送。见[包证据](../acceptance/restart-build16-2026-10-13.md)、[安装证据](../acceptance/restart-install16-2026-10-13.md)。PR #2阅读修复进入后续包 |
| 真实链路 | 旧build15人工新会话同意后仍等待，未观察完整回复。许可→发送FAIL，模型UNVERIFIED；先复验现有路由 |

旧仓不删除、用户数据不重置、签名凭据不发布。原始机器记录和大型旧性能采样保留本机/legacy历史，发布经扫描的spec、源码、合成摘要与原始trace hash。远端既有参数化签名模板与治理文档保留。

## 执行顺序与退出门槛

| 切片 | 用户可见交付 | 依赖 | 门槛 / 当前 |
|---|---|---|---|
| S00 维护入口与同步 | 单一维护目录、GitHub源码、plan/spec/验收/handoff齐备 | 无 | PASS：PR #1/2源码tree与本地引用核对，部署来源和体验合同已同步；包/源码版本区分明确 |
| S01 真对话与稳定许可 | 允许后能回答/追问/重开；许可可找回，队列轻量，状态诚实 | S00 | IN_PROGRESS：[队列sheet/暂停编辑/明确继续/unknown发送约束](../acceptance/restart-queue-ux-2026-10-13.md)已交付；追加[侧栏尺寸/搜索清空/按会话保留文字与图片草稿](../acceptance/restart-sidebar-drafts-2026-10-13.md)，最终43原生＋5实际UI、12侧栏包检查PASS。冻结build16已更新原手机，不含阅读、队列与本片；镜像待Touch ID解锁；真实模型0次，NOT_RUN |
| S02 真图片与连续体验 | 合成图真实理解；长文/前后台可用 | S01 | AF-A06与A04/05；NOT_RUN，不自行放宽视觉路由 |
| S03 执行审批成果 | 自然形成计划，可改/停/恢复；等待有入口；成果回对话/活动 | S01 | AF-A07–10；映射现有worker/store，先同task恢复试验。NOT_RUN |
| S04 记忆闭环 | 保存/来源/更正/删除，新会话生效 | S01 | AF-A11；接既有端口与真实PG，NOT_RUN |
| S05 主动跟进 | 时间/公开变化触发；无变化静默，暂停与退避 | S03 | AF-A12/13；调度托管部署先确认，产品配置代码可先做。NOT_RUN |
| S06 原生动作触达 | 本地日程确认写入，提醒返回同事项 | S03 | AF-A14/15；已知时间本地提醒先做，APNs独立接线。NOT_RUN |
| S07 智能UI与整体签收 | 六类卡、侧栏/输入/阅读；三条组合路径 | S02,S03,S04,S05,S06 | AF-A01/16/17/18与全部必需项同版通过。NOT_RUN |
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
6. AF-A01–18全部必需项签收后Goal才complete；云电脑扩展按独立确认范围。缺证据不算通过。

## 最近验证

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
