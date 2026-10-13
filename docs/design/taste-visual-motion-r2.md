# Catpaw 视觉、交互与动效 R2

2026-10-13；UX-1 的视觉实施附录，设计身份 `UX-1-R2`。产品行为仍由 FINAL-1、UX-1 和 CGUI-1 管理；不建立新 Goal 或第二份状态。当前交付状态只见 [master-plan](../status/master-plan.md)。[可点按提案](prototypes/catpaw-taste/index.html)、[机器参数](taste-visual-motion-r2.json)、[原12项验收](../acceptance/ios-codex-experience-acceptance.md)。此前 R1 提案与日期证据保留。

## 设计判断

面向在手机上交代研究、整理资料、做决定与持续跟进的个人使用者。体验应让人从容：正文很好读，当前决定很好找，离开后可以继续，成果值得拿走。沿用 A1、对话入口、侧栏与 NavigationStack，精修现有框架。

按用户指定的 [taste-skill](https://github.com/leonxlnx/taste-skill)，应用已经安装的 `design-taste-frontend` 的 brief inference、audit-first、排版/颜色/形状一致性、完整状态和有理由的运动方法。本次读取的本地 SKILL SHA256 为 `2136ed83016bfada39f7b8013b2aafd9f78fcbd9799110ed222a79c6419ba5fb`。未声称这份本地文件逐字匹配远端某个 commit，未安装/执行上游代码。

该 skill 第13节把 Native mobile 列为不适用范围并指定 Apple HIG。这里采用原生设计系统：系统字体、SF Symbols、SwiftUI 控件和系统转场。营销页的摄影、巨型标题、非对称网格、磁吸按钮、滚动劫持、装饰纹理与 Web 框架默认不适用于这个阅读/任务 App。网页是实际可交互的设计 harness，没有虚构的生产截图、统计或联网能力。

| 参数 | 本次值 | 对产品的含义 |
|---|---|---|
| DESIGN_VARIANCE | 4 | 单列与熟悉导航；用正文、紧凑行、待决卡、成果文档建立差异 |
| MOTION_INTENSITY | 4 | 有限的按压/状态/进入过渡；没有自动巡游、漂浮或反复闪烁 |
| VISUAL_DENSITY | 4 | 日常阅读密度；首层一件当前工作、一个当前决定，细节按需展开 |

## 基线审阅与取舍

审阅输入为 UX-1 R1、现有 semantic tokens、R1 人工提案和当前 ConversationFirstView/composer 源码。没有重新操作私人手机，不能据此宣称当前设备像素已审阅。

| 基线 | 保留 | R2 精修 |
|---|---|---|
| 黑白主动作、蓝色操作、独立状态色 | 全部原色值与 A1；冻结 tokens 文件不改 | 加非文字控制边界色；品牌靠一致排版与操作表达 |
| 用户轻气泡，助理直接排版 | 阅读优先与两种消息形态 | 中文 body 17/约1.55，清晰的24/28pt段落节奏 |
| 工作、choice、审批和成果均有入口 | 同工作与版本、既有路由/标签 | 工作用行，当前待决用容器，历史决定收一行，成果有自己的阅读层 |
| 原生输入、附件、队列与草稿 | 合一输入器、44pt目标、显式发送 | 输入/工具两行，次级意图可读，明确修改关联条 |
| 原按压120ms，系统返回与sheet | 原press与原生手势 | 给有限的状态运动参数；不把所有过渡机械设成120ms |
| 关键状态已有合同 | 不删错误、unknown、离线和恢复 | 为每种状态指定首层文案/视觉/下一步；完整异常提案可点按 |

## 视觉参数与组件层级

颜色从 [design-tokens.json](design-tokens.json) 继承，R2 JSON 通过路径引用，不复制另造主题。正文和重要次字至少4.5:1，普通正文目标7:1；必要非文字识别至少3:1。新控制边界浅色 `#828893`、深色 `#757D8B`，用于必须靠轮廓辨认的输入/控件；装饰分隔线继续用separator。必须实测实际叠加/禁用/系统材质后的像素，计算值只帮助设计。

| 元素 | 原生参数与规则 |
|---|---|
| 导航 | 系统导航高度与安全区；两侧44pt；标题headline、单行截断；工作名次级，不堆状态徽标 |
| 正文 | body默认17pt；中文行距目标1.55，具体用系统font/lineSpacing校正，不固定文本总高度；左右20pt |
| 作品标题 | title2/semibold约22pt；空页28pt仅作起始层级，不把每页标题做海报 |
| 次级文字 | subheadline默认15pt，状态/来源footnote默认13pt；关键含义不靠低对比/小字藏起来 |
| 工作摘要 | 同对象一行块，图形36pt但动作44pt；标题15pt、状态13pt；不显百分比或估计进度 |
| 当前待决 | panel、20pt圆角、内16pt；一个问题、必要影响说明、竖排选项；option至少66pt；回答后压缩成决定摘要 |
| 普通form | 系统TextField/Toggle/Picker，标签在上；真正缺失的必要信息才问；表单增量不重建字段 |
| 审批 | 系统sheet/详情；人话标题、本次对象预览、影响、版本；滚动body，底部具体主动作＋修改＋拒绝；关闭按钮44pt |
| comparison | 先结论再同口径数据；不全屏铺卡；可读原数据和来源；排序/选择局部完成 |
| artifact | 标题22pt、版本13pt、短结论19pt、正文17pt；内容在前；来源在相关位置；底部只“继续修改”，复制/分享为工具动作 |
| table/bar/line | 数据版本一致；表仅自身横滚；单系列中性色，多系列用线型/符号＋可读标签；颜色不能成为唯一含义；图始终能切到数据表 |
| calculator | 结果数值34pt/medium＋单位17pt；参数label15pt，滑杆/stepper44pt；固定公式/来源/假设可查；超预算用负数、文字和语义色 |
| composer | radius24pt；文字与附件/主动作在同容器；输入优先，单行起、普通最多五行；按钮44pt；有焦点时描边，单一轻阴影 |
| 侧栏 | min(320pt,86%屏宽)；搜索/新对话、条件优先行、最近对话、活动、可展开管理、底部设置；不用全卡片导航 |
| 跟进/记忆 | 原生行与详情；先约定/原因，再控制；编辑不因静默切换丢值；删除/结束保留适用的历史与来源 |

Spacing使用4/8/12/16/20/24/28；卡20、控件14、composer24，按钮圆形只用于独立图标动作。主阅读背景稳定不透明，玻璃仅系统导航/控件，低版本继续现有材质。Apple 把 Liquid Glass 组织为导航和控件层，强调内容与可读性；具体参数是 Catpaw 决定。[Apple Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)

## 动效与触觉合同

动效表达操作结果或位置变化。用户操作先有即时本地反馈，再等待实际事实；持续超过约一秒才有真实等待说明。不得用固定计时把后端状态变成成功。网页回放计时只演示状态，原生必须绑定对象事实。

| ID / 触发 | 视觉与节奏 | 原生实施 | 减弱动态 / 触觉 |
|---|---|---|---|
| M01 按压 | 120ms opacity至0.78；可选独立按钮scale0.98，正文不缩放 | 复用CatpawPressButtonStyle；不改变触控边界 | 无animated scale/过渡；一般按压无触觉 |
| M02 接受决定 | 180ms淡出当前卡内容，240ms淡入摘要；同cardID保持位置 | 只更新该卡projection；当卡在阅读锚点上方时补偿高度差；不包整ScrollView动画 | 即时替换或≤120ms淡化，无位移；确认持久受理后selection一次，未受理无成功触觉 |
| M03 新成果 | 240ms opacity＋最多8pt向上进入；不从屏外飞入 | stable artifactID/revision；已见同版本不重复动画；不自动打开 | 无位移，内容即时可读；真实新回执success一次，不给旧成果重播 |
| M04 开详情/返回 | 以系统NavigationStack的交互转场为准 | 推相同对象引用；原生返回手势跟手；从成果回聊恢复锚点/草稿 | 系统reduce行为；不再叠一层自定义slide |
| M05 打开审批/关闭 | 原生sheet系统过渡；网页示意280ms最多32px，遮罩180ms | 系统detents；长内容/辅助字号用large或详情；交互式dismiss可取消，无计时触发决定 | 使用系统reduce设置；关闭无决定触觉 |
| M06 抽屉 | 自定义有限过渡目标280ms `.smooth(duration:0.28,extraBounce:0)`；拖拽直接跟随位移 | 抽屉由同一个呈现状态驱动，native mask与焦点管理；和系统返回手势互斥 | 无slide/缩放，≤120ms淡化；无触觉 |
| M07 参数变化 | 数值即时重算，不做数字翻滚；仅选中/焦点反馈120ms | 两种登记kernel；局部state更新，零新模型请求；按数据revision保留 | 即时；slider拖动默认不连续震动 |
| M08 真回执 | 单次勾号/明确文字180ms淡入；unknown显示核对入口 | UI订阅receipt，成功但续聊失败仍保留成功；先阻止重复点击 | 文字/符号足够表达；真实success一次；unknown没有success |
| M09 队列/修改模式 | 关联条/队列入口180ms淡入；输入不整体跳动 | 两份draft各保存，IME不触发Send；出入mode恢复光标/焦点 | 无位移；无触觉 |
| M10 键盘/流/返回 | 键盘跟系统；流只按稳定段落更新；上读不被拖到最新 | safeAreaInset不双计；不逐token动画；阶段变化才通知VoiceOver；恢复不重复播放历史运动 | 完全保留功能；减少公告，不移动正在编辑的焦点 |

R2的180/240/280ms是有限自定义运动设计值，原生NavigationStack/sheet/keyboard交给系统，不能覆盖系统时长来追求网页相同。按压120ms仍继承冻结tokens。SwiftUI提供无基础弹跳的smooth preset和Reduce Motion环境值，可作为实现基础。[SwiftUI smooth](https://developer.apple.com/documentation/swiftui/animation/smooth), [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)

原生iOS最低目标仍17，不为材质/动效提高deployment target。更高版本Liquid Glass按availability采用，17的现有NavigationStack/sheet/Material继续成立。不装Web运动库，不新增渲染执行权。

## 状态、可访问性与连续性

空态只有起始句、两条能做的示例与输入；点示例填draft。loading在内容位置显示匹配结构的静态骨架，说明正在读取什么；已知layout才骨架，不能假造表格或进度。错误指向同对象的修改/重读/核对；离线输入保留，本机待发和服务端受理分开。unknown没有重试写入或成功动画。归档、关闭sheet、停止文字生成、暂停队列、取消工作各有既定含义。

辅助字号不缩字以塞进屏幕。按钮可纵排并换行，body滚动；重点是可操作，不要求每个按钮永远单行。审批footer必须在375pt＋辅助字号＋键盘时可达，内容不够用large/详情。修改类表单避免再把所有字段固定在footer。输入器可进全屏编辑。网页30px只是布局压力样例，不代替系统最大Dynamic Type。

VoiceOver使用正文标题/操作标签，不重复装饰symbol；当前问题、选项、状态、成果按阅读顺序，回答后保持合理焦点并可找回原决定。sheet隔离背景并回原入口；token不会逐个announcement。Reduce Motion、Reduce Transparency、Increase Contrast均需原生操作验证；关闭触觉、无声也能理解结果。44pt是有效hit area，不能拿36pt图形当验收尺寸。

## 与开发和验收的接线

沿既有D00–D50推进：D00外观/阅读/输入/侧栏；D10流式锚点与草稿；D20当前决定/计划/审批；D30成果与表图/试算；D40跟进/记忆；D50同版尺寸/可访问性/恢复。先W10→11→12原路由事实，再贯通CP01；可独立设计/组件工作同步做，不以视觉完成声称业务通过。

视觉改动进入现有Features与共用style，由服务驱动呈现；不让View拥有HTTP/账户/任务权威。实施时以同ID/版本保持卡片与输入，运动只描述projection变化，不发命令。A1、用户数据与冻结HTTP保持；实现另一App壳不是本提案的目标。

R2具体检查并入原 AF-U02/03/04/05/07/08/10/11/12，CG-A03/06/07/09及FQ-01/02/03/06；不新增必须签收数量。屏框矩阵、浏览器按键和token对比仅作合成设计检查。最终仍需对应原生候选的真实图/帧、系统最大字号、VoiceOver、键盘/IME、触觉、手势与同对象恢复证据；没有测量不宣称“顶级”已通过。
