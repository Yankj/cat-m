# 14项UI验收证据矩阵（全部 NOT_RUN）

本表是证据需求，不是现有产品测试结果；编号仅为本次评审编号，不宣称原稿已定义UI ID。所有行绑定同版 App build/hash、native/backend/config/协议/模型路由 manifest、设备OS/locale/timezone/主题/辅助功能设置和固定输入。获准前不进行模型、设备或通知测试。

| 评审编号 / 原稿行 | 目标 | 必需的可观测证据 | 静态来源/限制 | 状态 |
|---|---|---|---|---|
| UI01 / 103 | 大字号 | 固定 iOS Dynamic Type 类别及渲染字号（含 accessibility5），长孩子名/日期/收件人，在浅深色截屏并量测重排、滚动与操作可达；“200%”须换成可复现原生设置。 | catTypography 语义字号及类别映射存在（AdaptiveTextLayout.swift:6,36,53）；未渲染。 | NOT_RUN |
| UI02 / 104 | 44pt 热区 | 实际 AX 控件 frame/hit area、重叠量测和点击记录；发送/麦克风/侧栏/更正/删除/关闭及键盘、Switch Control 全程。 | Components.swift:264 有 touchTarget(minimum:44)，不能证明每处调用或不重叠。 | NOT_RUN |
| UI03 / 105 | 阅读次序 | VoiceOver 录屏/音轨及 AX 树；标题→内容→状态→动作→输入；弹层开关焦点、侧栏选中 trait、装饰猫跳过。 | 只读静态源不证明真实读序。 | NOT_RUN |
| UI04 / 106 | 状态播报 | 十态逐一可进入的状态控制、转换/重复渲染日志与 VoiceOver 录音；下一步可听辨、每次转态只播一次且编辑焦点不被抢。 | 状态文案提案不是原生状态覆盖或播报证明。 | NOT_RUN |
| UI05 / 107 | 颜色之外 | 同版浅深色/提高对比度渲染，逐对测量正文/次要文字/按钮/焦点/禁用态；同时验文字、图标、AX traits。 | 5个浅色值相同；Components.swift:13–47 为语义动态配色，色值相同不构成对比度通过。 | NOT_RUN |
| UI06 / 108 | 语音隐私 | 真实麦克风权限、指示、启动/停止/离场/锁屏/后台/拔耳机生命周期；明确转写与保存授权，敏感内容默认不外放；实机另行授权。 | ComposerDictation.swift:424–426,690–703,747–751 的明确语音聊天模式含自动发送/朗读，不能据此证明家庭口述转文字流程。 | NOT_RUN |
| UI07 / 109 | 转写确认 | 真实音频到可编辑文字及姓名/孩子/时间/地点/收件人预览；记录授权是否已有、命令 hash 与执行回执，实质改变再确认。 | S08 只有 script；文本代入不能验识别或媒体流程。 | NOT_RUN |
| UI08 / 110 | 草稿与加载 | 断网/锁屏/后台/侧栏/崩溃/重开前后文本、光标、附件、SwiftData/队列读回；仅本机草稿明确标示。 | 持久层和 UI 代码存在不证明端到端恢复。 | NOT_RUN |
| UI09 / 111 | 重复与未知 | 连点、延迟、丢响应、后台重开；原 operation/command ID、revision、receipt、权威对象数与设备效果读回；部分结果逐项保留。 | 取消/unknown 静态机制可见，未跑新产品 suite、PG 或设备。 | NOT_RUN |
| UI10 / 112 | 确认与退出 | 查看/改字/返回/关闭/取消均无未授权副作用；精确对象/可见范围/command hash、真实确认记录与 AX 焦点；S10 需分离 pending/unknown/已取消。 | ConversationSessionService.swift:974–995 允许完成赢得竞态、读回失败保持 unknown。 | NOT_RUN |
| UI11 / 113 | 减少动效 | 系统 Reduce Motion 开启录制所有十态、侧栏、录音、错误/成功、前后台；循环/视差/缩放停止，状态和动作仍可达。 | 存在 reduceMotion 分支不是全流程验收。 | NOT_RUN |
| UI12 / 114 | 未读规则 | 固定真实 unread/seen/待确认/失败数据，检查各数量与已读写回、重开、账号隔离、角标关闭；先冻结角标成员定义。 | 当前新规范是规则建议，未验证数据源/推送角标/原生红点一致。 | NOT_RUN |
| UI13 / 115 | 推送频控 | 固定时钟与时区跨午夜，验证 quiet/cap/dedupe/暂停多渠道，明确保留的用户提醒另列；真实 Focus 行为须获准设备验证。 | proactive/index.ts:25 默认 cap=5，与新建议每天1条不同；环境实际值未读，禁止声称当前已为1。 | NOT_RUN |
| UI14 / 116 | 锁屏与控制权 | 带合成隐私 canary 的 alert/Live Activity/widget/local payload 和获准锁屏截图；详情揭示权限、暂停持久回执与 stale claim/dispatch 围栏及恢复。 | apns-payload.mjs:6,9 直接带 title/body，无该 builder 层敏感脱敏证明；不据此推断真实数据已泄漏。 | NOT_RUN |

十态也须逐态可进入：识别中、需要澄清、待确认、执行中、成功/部分完成、明确失败、超时未知、冲突、更正记忆、暂停主动建议。实际成功、失败及未知由各自真实凭据驱动；不能只换UI文案或返回fixture宣称覆盖。

来源：`a54d7f2b34db4bcda13fb1a22eaaf4b847dd9e17` 的 `qa/family-cloud-verification/product/interaction-state-contracts.md`；本地评审以 `789ad4feceb0680b8e2e5913083c5b834dc63db1` 源码为静态依据。表中 UI01–UI14 对应 [crosswalk](product-contract-crosswalk-v1.json) 的本地别名 UI-01–UI-14。原始独立矩阵 SHA256 `cf65dcfd1a22e821611b4da7936381f630b33ff0ba77e8cfd7ebfa8914dbcc47`；整理稿仅补来源与完整类名，未产生执行结果。
