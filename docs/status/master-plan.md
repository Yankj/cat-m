# Catpaw-m 重启 Goal 与交付计划

更新：2026-10-13；唯一实时状态页。旧主计划完整保存在[2026-10-12快照](master-plan-2026-10-12.md)，旧失败与证据边界不改写。

**当前Goal（AF-1-G3-UX1）：交付可日常使用的Swift优先通用主动Agent iPhone App，体验对标Codex、能力对标Dot，并从唯一维护主仓持续同步GitHub。** 用户从自然对话交付目标，能够查看/修改计划、处理可找回审批、查收带来源版本的成果、管理记忆和持续跟进、从原生提醒回同事项；完整定义见[goal.md](../planning/AF-1/goal.md)。设计与功能同步推进，AF-GD为必需阶段；同版AF-A01–18、AF-U01–12及研究交付/变化跟进/本地日程三条CP路径全部通过才完成。当前Goal保持active，产品尚未签收。云电脑用途为公开网页调研＋文件处理；现有Supabase先行、新增计算预算0，托管实施待确认。

需求：[AF-1 spec](../product/agent-foundation-spec.md)；验收：[AF-A01–18与AF-C01–03](../acceptance/agent-foundation-acceptance.md)；执行切片：[delivery-slices.json](delivery-slices.json)；云电脑提案：[Proposed](../architecture/cloud-computer-proposal.md)；接手：[handoff](../../handoff.md)。

## 当前基线与证据

| 项目 | 实际状态 |
|---|---|
| 维护目录 | 用户指定的Desktop/ai-work/catpaw-m；应用入口 `apps/ios-conversation/CatpawM.xcodeproj`，服务端入口 `services/edge/supabase/functions/` |
| 代码迁移 | 已复制原生集成HEAD `582e4e4`、663个跟踪文件与12个未提交候选；候选hash逐项核对，旧源目录不修改；本地原始分支历史保留为legacy-local引用 |
| 最终handoff | 已读旧主仓handoff；用户确认相关任务停止。原文保存在忽略的local-audit；12项WIP与编译阻塞均相符 |
| 首个修复 | 新仓已复现并修复getter缺return；候选包含许可review与弹窗分离、稳定确认入口、队列折叠、持久回复证据；新增拒绝重开/旧revision回归，最终合成验证通过 |
| 本地检查 | 冻结合同/上游/历史来源完整性PASS；便携对话7/7、队列9/9 PASS；最终39/39原生＋1/1实际弹窗UI PASS，DeviceTrial无签名产品配置build PASS；证据限合成/Simulator，物理手机与provider未验 |
| GitHub | 迁移/许可、阅读/部署来源/UX合同、build16安装记录及Goal映射已通过PR #1–4合入main；本地主仓与远端引用/源码tree逐项核对。默认分支仍prepare/local-assets；终端无认证、SSH校验不匹配，未绕过。原始历史仅本地保留 |
| 手机/API | 用户明确批准后，同bundle覆盖安装0.3.0(16)成功，系统读回16；未卸载/重置数据，原有内容待UI核对。镜像从连接失败进入Mac认证锁定页，待用户Touch ID解锁；截图已保存到本机忽略目录。Supabase APIv19/tick7无部署变化；实际50/43文件、14项共享差异已同步 |
| 新候选包 | 0.3.0(16)，独立Git archive绑定原main `a905b47`；非DEBUG、严格签名、原证书/profile/entitlements及IPA逐字节PASS。已获安装及最多2次短文本原路由许可；尚未发送。见[包证据](../acceptance/restart-build16-2026-10-13.md)、[安装证据](../acceptance/restart-install16-2026-10-13.md)。PR #2阅读修复进入后续包 |
| 真实链路 | 旧build15人工新会话同意后仍等待，未观察完整回复。许可→发送FAIL，模型UNVERIFIED；先复验现有路由 |

旧仓不删除、用户数据不重置、签名凭据不发布。原始机器记录和大型旧性能采样保留本机/legacy历史，发布经扫描的spec、源码、合成摘要与原始trace hash。远端既有参数化签名模板与治理文档保留。

## 执行顺序与退出门槛

| 切片 | 用户可见交付 | 依赖 | 门槛 / 当前 |
|---|---|---|---|
| S00 维护入口与同步 | 单一维护目录、GitHub源码、plan/spec/验收/handoff齐备 | 无 | PASS：PR #1/2源码tree与本地引用核对，部署来源和体验合同已同步；包/源码版本区分明确 |
| S01 真对话与稳定许可 | 允许后能回答/追问/重开；许可可找回，队列轻量，状态诚实 | S00 | IN_PROGRESS：追加原生队列sheet/暂停编辑/明确继续/unknown发送约束；最终40原生＋4实际UI、16本机队列检查PASS，见[本片证据](../acceptance/restart-queue-ux-2026-10-13.md)。冻结build16已更新原手机，不含阅读与新队列片；镜像待Touch ID解锁；真实模型0次，NOT_RUN |
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

2026-10-13用户要求将design/research、截图调用/观察、对标问题表、UX-1及12项体验验收纳入当前Goal。已更新[执行定义](../planning/AF-1/goal.md)、[16项输入的hash与映射](../planning/AF-1/goal-evidence-map.json)和D00–D50逐片设计线；本次不改变产品PASS/FAIL。可点按提案为设计基线，仍须原生同版验证。旧一周Demo/今天首页/飞书候选与旧预算估算不扩大范围。未来截图按用户要求保存并记录版本，私人原图只留本机。

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

新仓复现getter编译FAIL，已修正；最终39原生＋1 UI、产品配置build、便携对话/队列、源码/本地化、完整性与敏感扫描PASS。追加[阅读锚点回归](../acceptance/restart-reading-2026-10-13.md)真实滚动＋共用许可UI 2/2、非DEBUG SDK源码检查与666双语资源PASS；该修复不在冻结build16中。build16签名构建及同身份覆盖安装PASS，系统读回16；镜像待恢复，真实模型0次，未部署云端或tick。实际部署源码50/43文件hash及14项差异PASS。原始日志和IPA在忽略build目录；精简证据见[许可回归](../acceptance/restart-permission-2026-10-13.md)、[build16](../acceptance/restart-build16-2026-10-13.md)、[安装](../acceptance/restart-install16-2026-10-13.md)和[部署来源](../../services/edge/deployed-baselines/README.md)。
