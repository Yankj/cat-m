# Catpaw-m 重启 Goal 与交付计划

更新：2026-10-13；唯一实时状态页。旧主计划完整保存在[2026-10-12快照](master-plan-2026-10-12.md)，旧失败与证据边界不改写。

**Goal：交付Swift优先的通用主动Agent底座，体验对标Codex、能力对标Dot，并从唯一维护主仓持续同步GitHub。** 通用能力以研究交付、变化跟进、本地日程动作三条组合路径签收。当前产品仍未通过，真实模型路径待新包复验。云电脑第一阶段用途为网页调研＋文件处理；用户已选先现有Supabase、后托管执行器/沙箱，新增计算预算0。托管实施仍待确认。

需求：[AF-1 spec](../product/agent-foundation-spec.md)；验收：[AF-A01–18与AF-C01–03](../acceptance/agent-foundation-acceptance.md)；执行切片：[delivery-slices.json](delivery-slices.json)；云电脑提案：[Proposed](../architecture/cloud-computer-proposal.md)；接手：[handoff](../../handoff.md)。

## 当前基线与证据

| 项目 | 实际状态 |
|---|---|
| 维护目录 | 用户指定的Desktop/ai-work/catpaw-m；应用入口 `apps/ios-conversation/CatpawM.xcodeproj`，服务端入口 `services/edge/supabase/functions/` |
| 代码迁移 | 已复制原生集成HEAD `582e4e4`、663个跟踪文件与12个未提交候选；候选hash逐项核对，旧源目录不修改；本地原始分支历史保留为legacy-local引用 |
| 最终handoff | 已读旧主仓handoff；用户确认相关任务停止。原文保存在忽略的local-audit；12项WIP与编译阻塞均相符 |
| 首个修复 | 新仓已复现并修复getter缺return；候选包含许可review与弹窗分离、稳定确认入口、队列折叠、持久回复证据；新增拒绝重开/旧revision回归，最终合成验证通过 |
| 本地检查 | 冻结合同/上游/历史来源完整性PASS；便携对话7/7、队列9/9 PASS；最终39/39原生＋1/1实际弹窗UI PASS，DeviceTrial无签名产品配置build PASS；证据限合成/Simulator，物理手机与provider未验 |
| GitHub | 已核main `78d9002`、默认prepare/local-assets；HTTPS Git无终端认证，SSH主机校验不匹配，未绕过。已有连接器可读写，将以main为父发布安全差异，不推原始本地历史 |
| 手机/API | 手机旧0.3.0(15)，来源 `4750142`；APIv19/tick7是旧handoff归属，未刷新部署。新候选未安装，不当作手机现状 |
| 真实链路 | 旧build15人工新会话同意后仍等待，未观察完整回复。许可→发送FAIL，模型UNVERIFIED；先复验现有路由 |

旧仓不删除、用户数据不重置、签名凭据不发布。原始机器记录和大型旧性能采样保留本机/legacy历史，发布经扫描的spec、源码、合成摘要与原始trace hash。远端既有参数化签名模板与治理文档保留。

## 执行顺序与退出门槛

| 切片 | 用户可见交付 | 依赖 | 门槛 / 当前 |
|---|---|---|---|
| S00 维护入口与同步 | 单一维护目录、GitHub源码、plan/spec/验收/handoff齐备 | 无 | hash/tree一致与扫描通过；迁移完成，同步验证中 |
| S01 真对话与稳定许可 | 允许后能回答/追问/重开；许可可找回，队列轻量，状态诚实 | S00 | AF-A02–05与A17相关回归；修getter→候选单测/UI→同版真实路径。IN_PROGRESS；真模型NOT_RUN |
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

[新计划与 AF-G0–G5](../planning/AF-1/plan.md)、[详细 spec / 用户故事](../planning/AF-1/spec-details.md)、[18 项操作脚本与 CP-01–03](../planning/AF-1/acceptance-scenarios.md)、[机器映射](../planning/AF-1/contract.json)细化现有 AF-R/AF-A/S00–S08，不建立第二份实时状态。本文仍是当前状态权威。

总 Goal AF-G5 只有在同版源码/包/服务上，AF-A01–18 和研究交付、变化跟进、本地日程三条组合路径全部通过才完成。AF-G0–G4 可以分阶段签收；基线准备、短模型探针和组件通过均不关闭总 Goal。即时云端变化推送与云电脑分别按扩展范围验收；已知时间本地提醒不作 APNs 证据。

1. 每片固定source/合同/case；交源码、证据层、未验项与下一步，实时状态只更新本页。
2. 真实模型试验限定数量与结束条件；旧unknown只读核对。现有路由失败后才讨论切换。
3. 验证范围因变更、失败或风险扩大，不为测试数重复跑。构建与真机性能分别记录。
4. 原始本地历史不推远端；main经检查的差异/PR推进，不force、不拼接无共同祖先历史。连接器发布后读回commit/tree并对齐维护分支。
5. 云电脑方案未确认不实施；旧安装许可已撤销，准备具体新包再申请新安装确认。继续与方案无关的开发。
6. AF-A01–18全部必需项签收后Goal才complete；云电脑扩展按独立确认范围。缺证据不算通过。

## 最近验证

新仓复现getter编译FAIL，已修正；最终39原生＋1 UI、产品配置build、便携对话/队列、源码/本地化、完整性与敏感扫描PASS。当前未运行真实模型、签名、手机安装、云部署或tick。原始日志在忽略build目录；精简绑定hash结果在[首片验收](../acceptance/restart-permission-2026-10-13.md)完成后归档。
