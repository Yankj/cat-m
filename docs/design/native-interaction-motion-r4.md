# UX-1 R4：交互模式、连续转场与原生动效

2026-10-13。本文是 [UX-1](ios-codex-experience-spec.md) 的 presentation 实施附录，服务于同一套 AF-1／FINAL-1／[CGUI-1](conversation-generative-ui-spec.md) 对象、状态与验收。它调整呈现机制，不新增功能种类、Goal 或 release 门槛。实时进度只在 [master-plan](../status/master-plan.md)；此前 [R3 场景表](interaction-scenarios-r3.md) 保留为日期版本。本文的“R4”是本轮交互设计版本，与历史暂停的周边 r4 工作无关。

**界面应像一件拿在手里的工具：手指移动时跟着走，松开时自然停住，途中能改主意，回来时仍能接着读。** 动效先解决方向、关系与控制权，材质再说明层次。连续性比装饰重要。

效果审阅入口为[独立交互样机](prototypes/catpaw-motion-study-r4/index.html)、[视觉方向与机器参数](interaction-motion-r4.json)、[App专用skill的对话方向](prototypes/catpaw-motion-study-r4/assets/mobile-conversation-concept-r4.png)和[审批方向](prototypes/catpaw-motion-study-r4/assets/mobile-approval-concept-r4.png)。本轮采用 taste-skill 的 [imagegen-frontend-mobile](https://github.com/Leonxlnx/taste-skill/tree/main/skills/imagegen-frontend-mobile)，其职责是生成移动屏幕／流程参考，动态机制由可操作样机验证。新构图不受R3页面样式限制；旧tokens与A1不改，颜色方向是本轮语义角色提案，不把生成图当原生像素规范。

## 1. R3 的缺口，以及本轮应看到的改变

| R3 的具体缺口 | R4 的设计决定 | 证据边界 |
|---|---|---|
| 抽屉拖动已有位移，但松手主要是固定曲线；收起时有卸载时机 | 拖动与吸附共用一个连续的位置值；弹簧收束中再次抓取，从当前可见位置接管 | Web 可评审跟手、反向和取消；原生必须另验 |
| Sheet 只有开关与下拖关闭，没有实际中档停靠 | 审批支持中／大档；正文滚动与抓手拖动协调，确认区固定 | 系统 detents、键盘与大字体需要 iPhone 路径 |
| 同层“返回”主要是按钮切换 | 详情采用系统可取消返回；网页样机可演示进度、取消及恢复原锚点 | 不用网页手势签收原生 NavigationStack |
| 菜单用通用浮层，没有触发对象的空间关系 | 短说明用锚点 popover；对象操作用 context menu；全局详情用 Sheet／导航 | iPhone 系统适配结果要按目标 SDK 验证 |
| 图片缺连续放大／缩回到来源 | 缩略图与大图共享同一图片身份，按来源转场，返回同一格 | 静态图无法证明 zoom 连续性 |
| 阅读位置主要依赖整体 scrollTop | 稳定 block 身份＋可见块与块内偏移；布局变化后恢复同一句附近 | 真流、键盘、懒加载长文必须联合验证 |
| 动效说明侧重若干毫秒 | 明确每种手势的 owner、取消、吸附、打断与状态事实；系统物理保持原样 | 本文是设计决定，不是已通过的性能记录 |

## 2. 视觉的三层，以及材质的职责

内容层承载长文、表、图、来源和成果。它应稳定、清晰、接近纸面，不给每条消息套玻璃。用户消息适度分组，助理正文保持开放排版；读长文时关注的是内容，不需要背景不断折射。

控制层承载悬浮导航按钮、输入器的主要控制和必要工具组。原生优先使用系统导航栏、工具栏与控件。Liquid Glass 具有平台的动态适应与光学效果，普通 `blur`、`UIBlurEffect` 或 Web `backdrop-filter` 只能表现模糊／半透明。Apple 将玻璃定位于交互层，并建议避免玻璃层彼此覆盖；当前原生接口与系统菜单转场见 [Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/)。

临时前景承载抽屉、Sheet 和对象菜单。打开时以 scrim 压低背景注意力，压暗程度与呈现进度连续关联；不把整段正文做强模糊后仍允许点击。模态审批呈现期间底层不接收操作。关闭时背景与前景同时恢复，不在结束后突然解除遮罩。

滚动内容可以进入悬浮控件背后，但文字不应穿过按钮造成混读。使用系统 scroll edge effect；自定义输入器容器需与实际内容 ScrollView 关联，而非加一道常驻模糊横条。Apple 的 [UIScrollView](https://developer.apple.com/documentation/uikit/uiscrollview?language=objc) 提供各边缘 effect；WWDC25 的 UIKit 示例展示 `UIScrollEdgeElementContainerInteraction` 的自定义容器接法。

减弱透明度时改为有充分对比的实色表面、边界与遮罩；玻璃失去透明效果后，层级与操作含义仍成立。浅深色用语义色，不把暗色屏幕简单反相。A1 图标继续保留。

## 3. 手势只交给一个 owner

“能滑动”不意味着页面任意位置都同时监听横滑。识别前先确定当前路由、触点所属控件和方向；识别后当前 owner 保持到 ended／cancelled，不能拖到一半改成另一动作。

| 当前位置／触点 | 首选 owner | 排除与取消 |
|---|---|---|
| 系统 Sheet、照片选择器、分享面板 | 系统 presentation | 根抽屉禁用；不监听系统浮层背后的窗口触点 |
| 图片放大后 | 图片 zoom／pan | 已放大图片的平移优先；回到 fit 状态才允许 viewer 退出手势 |
| 输入字段、文本选择、系统编辑菜单 | 原生文本控件 | 不抢 selection、光标或中文 marked text |
| 横向表格／代码、局部滑杆、横向图片页 | 所属控件 | 横向滚动／调参先于页面返回；不能横滑一列却打开抽屉 |
| Sheet 正文非顶端 | 正文 ScrollView | 保持惯性；由系统协调到边缘后的 Sheet 扩展／收缩 |
| Sheet grabber／标题可拖区域 | Sheet | 跟手改高度，松手停靠；cancel 回先前档位 |
| NavigationStack 深度 > 0 | 系统返回 | 根抽屉关闭且识别器禁用；返回可取消 |
| 根对话左边缘，横向意图明确 | 抽屉 | 可编辑／横向控件排除；纵向阅读优先 |
| 消息正文纵向拖动 | 消息 ScrollView | 不触发抽屉；读上方时停止自动追最新 |

表中的方向锁是项目策略：现有 `SidebarGesturePolicy` 以 `abs(vx) > 1.2 × abs(vy)` 判断横向意图，边缘区域 24pt。参数可在同候选试用后调校，不作为 Apple 的强制标准。现有入口为 [SidebarGestureBridge](../../packages/ios-navigation/Sources/CatpawNavigation/SidebarGestureBridge.swift) 与 [SidebarHost](../../packages/ios-navigation/Sources/CatpawNavigation/SidebarHost.swift)。

iOS 26 的系统返回还可从内容区域开始；Apple 说明它会判断竞争交互。局部自定义 gesture 需要优先权时，使用公开 failure requirements 与 `interactiveContentPopGestureRecognizer` 协调，不用全窗口 `simultaneousGesture` 放行全部横滑。支持旧系统时沿系统 edge-pop 行为。此结论来自 [UIKit 新设计视频的转场部分](https://developer.apple.com/videos/play/wwdc2025/284/?time=730)，API 必须按最低支持系统做 availability 检查。

## 4. 抽屉：抓住位置，而不是播放开关动画

根对话打开宽度沿现有 `min(320pt, 屏宽 × 0.86, 屏宽 − 44pt)`，保留可点遮罩。屏幕窄时不把“关闭入口”挤成无法操作的一条缝。抽屉面板滑入，对话保持自己的阅读与布局，不用整屏缩成一张缩略卡来制造质感。

连续值 `x` 表示抽屉当前可见位移，范围 0…width。手指按下时读取**当前可见** `x`，而不是目标端点；拖动 `x = startX + translation`，期间不另加 easing。松手按当前位置与速度决定打开／关闭目标；动画只负责余下的收束。现有原生默认 50%／400pt/s 先作为对照起点；网页旧 45%／700px/s 不直接搬进 Swift。

物理试调可使用 `projectedX = x + vx × 0.18s` 辅助选择最近端点，同时限制投射距离，避免很短的抖动被偶发速度变成翻页。0.18s 是本项目样机参数。边界之外只允许轻微阻力位移，不能让抽屉越拉越远；松手回合法端点，不产生多次弹跳。

收束中再次触碰会中断上一收束，继续同一个位置轨迹；快速开—关—开不能先跳到全开或全关。route、scope 改变或系统取消时回到手势开始时的稳定状态，保存原草稿与锚点。目标关闭且视觉已回到 0 后才能卸载面板；旧动画完成回调不得关闭新 presentation。

SwiftUI 可保持同一可动画属性并用持久 spring 重定向；Apple 说明同属性连续 spring 会保存前一动画的速度，见 [spring(response:dampingFraction:blendDuration:)](https://developer.apple.com/documentation/swiftui/animation/spring(response:dampingfraction:blendduration:))。若需要精确取当前展示位置与暂停后拖动，局部 UIKit animator 更可控；不因抽屉单元换掉整个原生导航。

## 5. 详情与图片：先让用户认出“从哪里来”

工作、成果、全表与长编辑器使用 NavigationStack。点入后可立即返回，不锁屏等转场播放完；返回拖动中前后两页随进度移动，反向拖动或取消后留在详情。取消不弹出页面、不触发“已保存／已执行”回调；真正完成返回后恢复来源卡、选点和块内阅读偏移。默认系统 slide 不硬写 280ms。

图片、附件预览以及具有清晰封面的成果可采用 zoom。缩略图与目标使用同一 sourceID；系统支持时 SwiftUI 用 `matchedTransitionSource(id:in:)` 与 `navigationTransition(.zoom(sourceID:in:))`，参考 [ZoomNavigationTransition](https://developer.apple.com/documentation/swiftui/zoomnavigationtransition)。来源有实际图片时才使用，不把文字正文标题硬拉伸成大屏。

放大时保持图片比例，在 fit 图与原缩略图裁切之间连续过渡；先提供清晰预览，高清加载只改善细节。返回时按 stable attachmentID／artifactID 找当前源格，列表已滚动或对象不在屏幕时使用系统／淡入降级，不偷偷把用户列表滚回老位置。关闭大图不删除附件。图片已缩放时 pan 与 pinch 优先；“关闭”按钮始终提供可访问替代。

Apple 的 [Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/) 展示了从 source cell 展开、可在转场进行时继续交互的 zoom。网页共享元素样机只能检验空间关系及取消规则，不能证明 iPhone 的缩放、解码与手势协同。

## 6. Sheet：有档位、有正文、有一直能找到的决定

| 内容 | 档位／初始值 | 内容和操作区 |
|---|---|---|
| 短来源摘要、队列、轻量选择 | medium／large；通常 medium | 不够读时向上扩展；正文可滚 |
| 精确审批 | medium／large；仅当摘要与决定完整容得下时 medium，否则 large | 动作、目标、内容、版本、影响可审阅；确认区固定 |
| 审批修改、长表单、复杂编辑 | large | 随键盘安全区变化，保留字段光标与草稿 |
| 辅助大字体／横向紧凑高度 | large 或系统自适应 | 不坚持半屏，按钮改纵排 |

采用 `.sheet(item:)`，同对象由一个 presenter 管；detent selection 属于本次 presentation 的局部状态。原生停靠与滚动交给 `.presentationDetents`／`UISheetPresentationController`，参考 [SwiftUI presentation modifiers](https://developer.apple.com/documentation/swiftui/view-presentation) 与 [UISheetPresentationController](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller)。这些 API 提供 detents、grabber、滚动到边缘的扩展协调；本表的默认档位是 Catpaw 的选择。

Sheet 内布局由正文 ScrollView＋`.safeAreaInset(edge: .bottom)` 决定区组成。确认区不能放在长文尾部，也不能靠绝对屏幕坐标悬浮在键盘背后；同时预留它占用的正文空间。确认按钮维持明确动作名称；关闭与“稍后／拒绝／修改”分开。短档若无法完整呈现四种决定，直接选 large，不把次动作缩成 30pt 图标。

抓手拖动时 Sheet 与遮罩进度联动，松手按当前位置和速度吸附；正文内部滚动沿系统惯性。Sheet 向下关闭只结束查看层，批准状态仍为 pending；再次打开同一对象恢复审阅状态与编辑草稿。键盘进入前先把 presentation 提升到可容纳输入的档位；依赖系统 keyboard safe area，避免 240px 假键盘成为生产布局规则。

审批属于模态决定，背景交互保持禁用。资料浏览若未来确需允许操作底层，才按具体对象采用 [presentationBackgroundInteraction](https://developer.apple.com/documentation/swiftui/view/presentationbackgroundinteraction(_:))；不能为了展示两层玻璃，在审批期间留背景发送按钮可点。

## 7. Popover、Context Menu 与浮层生命周期

Popover 是“这个位置的解释／少量设置”：来源徽标的元信息、图表单位说明、会话标题的短操作。锚点来自触发控件 bounds，位置随当前可用空间选择，避免压住正在看的关键结果。窄屏／辅助大字容不下时用系统自适应 Sheet；不强行保持一枚挤满文字的小气泡。源按钮已移出、route 或 scope 变更时关闭；输入 draft 不因此丢失。

Context Menu 是“这个对象能做什么”：长按消息复制、点成果更多查看版本／分享、附件移除。只出现适用于该对象与当前权限的操作；文字选中时保留系统编辑菜单。危险动作使用具名对象和原生确认，不能只写“确定”。iOS 26 源控件到菜单的系统呈现可提供连续关系；Web 样机用锚点几何关系演示，不冒充系统 optical morph。

所有浮层用 `route + objectRef + presentationGeneration` 管理。关闭请求从当前视觉位置继续收束；新开会递增 generation、取消旧 closure。只有同 generation 的完成回调才清理视图。底层点击／VO 焦点从开始呈现到关闭结束由 foreground owner 管理；关闭后焦点回源控件，源控件已消失则回对应消息摘要。Esc／外部点击／向下拖只关闭查看，放弃草稿是独立决定。

## 8. 流式内容：增量在动，正在读的地方不动

过程展示**可观察的执行摘要**：当前步骤、输入／输出概况、受阻原因与可查看来源，不展示隐藏思维链，不编造读了什么或百分比。默认一个稳定行，点开在原位置展示步骤。新事件更新同一行，不反复插入等权重“思考卡”；正文按有意义片段追加，不逐 token 渐隐或震动。

阅读状态至少记录 `conversationID + stable blockID + block内偏移 + followingLatest`。用户在底部阅读时跟随新增高度；手动向上后立刻取消待执行的自动滚动。正文增量、表单出现、过程展开、图片尺寸补齐、Sheet 关闭和键盘改变高度，都基于同一可见锚点恢复。恢复属于几何修正，不动画滚过几十行。

在用户主动点“展开过程”时，保持触发行的位置，展开内容从该行下方占据空间；读者已向下读另一段时，后台过程变长不能把视口推走。正在点选／输入的卡保持 node／View identity，旧 seq 与其他 scope 的回包忽略。新卡可完整读取后再出现一次，已有卡字段不跟着流整体 crossfade。

“回到最新”是显式操作，使用一段短且可打断的滚动；用户重新触摸立即停止。它的显示／隐藏不能改变消息列宽、composer 高度或正在读的行。消息列表使用系统 ScrollView／UIScrollView 的惯性、方向锁和边界回弹；`bounces` 默认开启，`decelerationRate` 默认为 normal，见 [bounces](https://developer.apple.com/documentation/uikit/uiscrollview/bounces) 与 [decelerationRate](https://developer.apple.com/documentation/uikit/uiscrollview/decelerationrate-swift.property)。原生不实现自定义 rAF／定时器惯性滚动。

现有 [ConversationFirstView](../../apps/ios-conversation/Sources/Features/ConversationFirstView.swift) 已有 100ms 合并跟随、48pt 底部判断和系统交互收键盘。R4 需要补的是复杂 stable block 与可见偏移恢复，并在长文／图卡／键盘联合路径验证，不能把现有基础删除重写后自称更原生。

## 9. Agentic UI、Intelligence UI 与 HIL 的动作节奏

卡片就绪由完整 schema 和权威对象事实决定。choice／form 未就绪时保持有界占位；可操作后一次揭示具体控件。选中项立即变为 selected，提交后由 typed service 分别表达受理／安全点应用；动画不制造绿勾。已回答 choice 压缩到稳定摘要，摘要可重新查阅；复杂审批不被压缩到无法核对后果的一行。

表单保持字段身份、光标和中文组合输入。错误信息出现在相关字段下，校验期间不晃动整卡。有效输入后就地消除错误，提交时只聚焦首个错误。减弱动态或 VO 模式仍能知道哪些字段需要改。单个控件 press／selection 可以反馈，正文流不能让整张卡持续呼吸。

Intelligence UI 调参数、排序、筛选和选点全是本地动作；即时改变结果与可读原值，零新增请求。图表点选用稳定高亮和文本说明，过渡只作用于图形差异，不让单位／来源／公式跟着数字滚轮闪动。拖动滑杆时结果连续更新，不为每一帧加额外 240ms tween；停止拖动后可短暂平滑收束。减少动态时数据直接更新。

“按这些条件继续”携同数据版本进入原会话／工作，明确提交才创建后续意图；本地试算不保存记忆或触发 effect。来源版本变化使旧条件与批准失效时先保留草稿、呈现差异，不用动画自动替用户换版本。

HIL 审阅中确认区一直可达。点确认后立刻显示一次已提交的视觉反馈并阻止重复意图；权威状态后续依原 operation 更新。处理中可关 Sheet，原 pending／operation 可找回。未知结果显示核对原操作，不能画“重试创建”；部分效果列出各子项事实，仅确认未执行的子项可准备新审批；成功但交付失败读取原回执。拒绝／关闭／稍后各自有明确文字，收起速度不能暗示批准成功。

触觉绑定**用户动作或权威状态**，不绑定动画完成。离散选择变化可轻反馈，审批显式提交至多一次轻反馈，真正 effect 成功至多一次 success；unknown、仅流结束或合成回放不产生真实成功含义。已有 `.sensoryFeedback` 可复用，平台能力参考 [SensoryFeedback](https://developer.apple.com/documentation/swiftui/sensoryfeedback)。触感强弱、重复频率和设备是否支持必须真机确认；网页按键闪烁／震动 API 不代替触觉验收。

## 10. 动效预算与可打断机制

下表是设计调试起点，复用既有 FQ／UX 验收，不新增数值门槛。系统导航、Sheet、zoom 和滚动物理采用平台值；只给自定义局部动效设预算。响应时间、主线程负载、掉帧需同候选实测。

| 组件 | 拖动／触碰期间 | 松手／状态变化 | 取消与减弱动态 |
|---|---|---|---|
| 抽屉 | 当前位移直接跟手，无额外 easing | 近临界收束，样机 spring response 约 0.32–0.40s、damping 0.90–1.0；原生先测再定 | cancel 回起始稳定态；RM 保留直接控制与明确端点，去掉惯性尾段 |
| 详情返回 | 系统 progress 驱动 | 系统完成／取消，允许再次触摸 | RM 采用系统降级；不自行叠缩放 |
| 图片 zoom | 原生交互转场；放大后 pinch／pan | 系统 zoom；来源消失时淡入降级 | 关闭／取消回原 attachment；RM 短淡入，不长距离缩放 |
| Sheet | 系统 detent 与 ScrollView owner | 系统吸附，不另建第二弹簧 | cancel 回原档；大字／键盘转 large |
| 锚点 popover／菜单 | 系统 owner；外部点击关闭 | 原生默认；Web 可用约 140–180ms 小距离展开 | 新 presentation 取消旧清理；RM 淡入／直接替换 |
| 过程展开 | 保持触发锚点 | 自定义高度变化约 180–220ms，正文无逐 token 动画 | 用户滚动中后台变高只做锚点修正；RM 直接展开 |
| 选择／press | 局部高亮、最多轻微压感 | release 约 100–140ms，不连环反弹 | cancel 还原；RM 仅颜色／边界 |
| 卡片就绪／已回答摘要 | 不替换已编辑字段 | 一次约 160–220ms 揭示／收拢 | 新事件不得覆盖输入；RM 直接状态切换 |
| 图表参数 | 原值与图形连续本地更新 | 非拖动更新可约 160–220ms 插值 | 中途新值从当前形状转向；RM 无插值 |
| 结果回执 | 先读取真实事实 | 一次轻反馈；不展示烟花或大屏成功盖住结果 | 不以转场结束写入任务完成 |

“response”不是严格完成时长；spring 的收敛受初始速度与阻尼影响。不把 0.35s 写成任何距离都必须结束的 timeout。使用持久 spring 的同属性重定向，或用 [UIViewPropertyAnimator](https://developer.apple.com/documentation/uikit/uiviewpropertyanimator) 的 pause／fractionComplete／reverse 协调局部动画；不靠一串 `setTimeout` 模拟可打断。

中断后保留当前呈现位置与速度；用户再次拖动时以当前位置建立新的手指基线，不偷加第一次拖动的 translation。UIKit 实现先 pause animator，再从展示层取位移并使 model layer 与之对齐，之后接管 translation；不能从已写成目标值的约束常量计算起点。SwiftUI 实现也必须提供可观察的连续值或可检验的系统接管，不能仅更换 `.easeOut` 为 `.spring` 就声称完成。动画生命周期只改变 presentation phase；关闭清理检查 generation，回执与草稿写入不放在完成回调。

## 11. 队列、编辑、键盘与恢复的连续性

队列在对话里维持一行摘要，不挤占正文；打开 Sheet 后依旧是同一批 queue item。编辑未发项进入具名项，返回恢复队列位置；移除有明白的对象后果。暂停队列与暂停持久工作分开，待发本地文字不标为已发送。查看／收起队列不推进 execution。

聊天草稿、工作修改草稿、Sheet 字段草稿按 scope 与对象分区。打开修改模式可以有小距离关联条揭示，但不清空聊天草稿；退出回聊天草稿，编辑光标尽量恢复。切换会话后迟到图片选择回调不得插进新会话。长文本进入系统全屏编辑器，返回同一草稿与光标，不通过复制形成第二份内容。

键盘升降沿系统 interactive dismissal 与 safe area；手指下拉时键盘和 composer 连续跟随，不让 composer 先落底、键盘稍后跳走。保持当前输入、最近错误和提交动作可见。阅读已离底时，键盘动画不触发追最新。开抽屉可收键盘并保存 draft，但不自动点搜索；打开 drawer 不是申请 focus 的理由。

离线／后台／回来先恢复同对象最后可靠状态，保留可读内容、选点与草稿，再核对原 operation。未知时期只提供读取原请求，恢复成功后状态就地更新，避免整屏闪白和历史重复插入。冷启动的对象、draft 与 local calculation state 需应用服务持久能力证明；样机 RAM 状态不能作为此证据。

## 12. Swift 落点与实现成本

成本是基于当前文件的相对判断，非工期或已完成功能。高成本主要来自领域事实与持久恢复，不能用漂亮动画隐藏。

| 单元 | 复用／原生落点 | 相对成本与优先顺序 |
|---|---|---|
| 根抽屉 | 现有 `SidebarHost/Model/GestureBridge`；保留排除区与 root-only | 中：补当前展示位置抓取、持续 mount、spring retarget；先完成质感主路径 |
| Slide 返回与 zoom | 原 NavigationStack；系统 `.navigationTransition(.zoom)`；最低系统分支 | 低–中：主要是 source identity、回源位置与 gesture 协调 |
| Sheet／Popover／菜单 | `.sheet(item:)`、detents、safeAreaInset、`.popover`、`.contextMenu`；复杂配置才桥接 UIKit | 低–中：单一 presenter、精确关闭语义和大字布局比造控件重要 |
| 材质与 scroll edge | 系统导航／toolbar 优先；自定义局部用 glassEffect／UIGlassEffect 与公开 edge API | 低–中：移除妨碍系统材质的自绘背景，按 OS availability 降级 |
| 流式锚点和稳定卡 | `ConversationFirstView`＋typed projection；block/field identity、可见偏移恢复 | 中–高：动态高度与用户滚动交错，不把整流列表重建 |
| 表图与试算 | CGUI registry＋固定内核；Swift Charts／原生字段和表格替代 | 中：本地 reducer 与同版数据选择；不加任意脚本 renderer |
| 审批／恢复／部分效果 | 原领域服务的 operation、revision、effect、receipt | 高：真实幂等、未知核对、checkpoint；展示层只订阅事实 |
| 键盘／触觉／辅助技术 | 系统 FocusState/safeArea/ScrollView/sensoryFeedback | 中：用真机与最大字号联合路径兑现，不靠截图收尾 |

不新建第二个维护 App，不替换 Supabase 或模型路由，不增加 compute。独立 native design study 若用于机制验证，应在忽略 build 中临时生成、沿已有 SDK 无外部依赖；提取可审阅的最小代码与说明进入本附录范围，正式实现仍只回 `apps/ios-conversation`。本轮只读观察已有 Xcode 27.1 与 iOS／Simulator 27.1 SDK；当前受限进程未能连接 CoreSimulatorService，因此不能宣称 runtime 或 Simulator 样机已运行。

## 13. 怎样评审效果，以及不能据此签收什么

评审先走一条连续动作：从对话边缘慢拖抽屉→半途反向→松手吸附→收束未结束再次抓住→打开成果详情→慢拖返回再取消→返回原句→点图片放大缩回→打开审批→在中／大档拖动并编辑→关闭重开→在正文继续流入时改一项本地参数。用户应能改主意，当前输入和读到的位置始终有来路。重复点按、取消和快速反向比只看最终截图更能暴露质感。

同候选原生验证覆盖原有 AF-U／FQ／CG：375/390/430、浅深色、辅助大字、VoiceOver、Reduce Motion／Transparency、键盘、安全区、真实流及重连。关注卡片焦点与 caret、可见块偏移、动画中接管、系统返回冲突、长图解码、回执语义和触觉重复。已有截图只证明保存时的构图；浏览器轨迹只能证明合成 presentation；原生 Simulator 也不能替代手机触觉与真实后台。所有用户数据、权限、费用、模型调用与效果授权仍沿原合同。

Apple 的 [accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion) 要求避免大型运动，尤其模拟三维的效果。降级保留操作、状态、位置关系、明显焦点与原对象身份；不因动效关闭而拿掉返回、确认或查看来源入口。
