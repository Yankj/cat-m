# 交互流畅度复盘（feat/interaction-polish）

分支 tip：`660c530`（基于 `c896dc2`）。测量在 BE5C「小咪最新体验」上，用 `Scripts/measure-interaction.sh` + Time Profiler；hitch = 显示回调间隔 > 25 ms。

## 问题清单

| # | 现象 | 根因 | 方案 | 提交 |
|---|------|------|------|------|
| 1 | 侧滑不跟手 / 松手生硬 | 固定 400 pt/s 阈值 + ω=18；拖拽中面板 body 每帧重算；开满后硬停 | 投影释放 + 过冲回弹 + ω20；`.equatable()` 面板槽；视差 | `a8e90ac` |
| 2 | 键盘弹起后列表跳动 | 输入框已跟键盘，但「跟底部」靠事后 scroll；曾试 `.sizeChanges→bottom`，会抢走横向手势，侧栏打不开 | `CatpawKeyboardFollowScroll` 在 `willChangeFrame` 曲线内 `scrollTo(latest)`；去掉 sizeChanges | `688feb4` |
| 3 | 发送气泡突然出现 | 草稿清空与气泡插入无同一动画；时间线投影在 body 里被多处重复计算（Time Profiler 单次主线程卡 ~235 ms） | 每 body 一次 memo；发送事务 + `catpawSendRise` + 同弹簧滚到底 | `97666c9` |
| 4 | 按压无反馈 | `CatpawPressButtonStyle` 只有透明度；消息长按前无下沉 | 缩放 + soft haptic；长按前 ~90 ms 延迟下沉（防滑动闪烁） | `53c2be0` |
| 5 | 打字时主线程尖峰 | `NativeConversationComposer.sizeThatFits` 每个 proposal 全量 TextKit 测量 | 同宽/字号/文本命中缓存 | `0f93137` |
| 6 | DEBUG 假卡顿 | `P0ExperienceProbe` 在 1500 帧缓冲满后仍每帧 `revision+=1`，整棵对话树 60 Hz 重算 | 仅在真正追加样本时再触发 | `07d2fe8` |

## 测量（同 harness，对比 `01e3a17` 工具基线 vs 全量后）

| 阶段 | hitch% 前→后 | hitchms/s 前→后 | 备注 |
|------|-------------|-----------------|------|
| send | 5.1% → ~4% | 113 → ~85 | 时间线投影次数大幅下降 |
| keyboard | **15% → ~2%** | **304 → ~25** | 去掉 probe 误报 + sizeChanges 后；键盘跟手待 demo 后目视 |
| drawer | 4.4%（打开成功） | ~50 | UITest 在键盘仍起时 DRAWER_OPEN=false；harness 已先收键盘 |
| navigation | 4.6% → ~2.5% | 99 → ~60 | |
| press | ~3% | — | 触感/缩放需真机体感 |

未再跑 Instruments 对比（demo 占用 BE5C）。composer 缓存与键盘曲线跟滚待 BE5C 空闲后复测。

## 边界与未做

- **未动**：启动出场、新对话文案跳动、语音权限闪屏、发送失败提示、连接状态点、系统消息（Grok Bot worker）；三角网络层。
- **开屏**：属对方范围，本分支未改。
- **页面跳转**：未单独做自定义导航转场；NavigationStack 默认。
- **真机触感 / Instruments 终态**：需 BE5C 空闲后补一轮 `Scripts/measure-interaction.sh after` + Time Profiler。

## 后续反馈（状态文案 / 图2）

- **流式 / 进行中**：`ThinkingHeader` 去掉「思考中 + 摘要 + 计时 + 工具列表」文案堆；改为猫咪 presence + 墨色 … 闪烁；流式气泡加 ink shimmer 扫过（`StreamProgressVisuals`）。步骤只在结算后的 chip 展开。
- **多状态叠在一起**：时间线里 `ConversationTurnActivity` 在 sending/waiting/writing/processing 阶段改为 `EmptyView()`，避免再叠一层「正在…」；`processPending` 行同样改成 presence + …。
- **归属说明（未改代码）**：顶栏 `ConnectionStatusHeaderDot`、`ConversationConnectionStatusCapsule`、以及 `ConversationSystemNotice`（额度 / 离线 / 路由）归 Grok Bot worker；本分支不合并它们与对话进度指示。若「图2」指的是这几块叠在顶栏/安全区，需要对方在那一侧做单一主指示。
- **落地页「点按开启」**：Grok Bot，未动。
