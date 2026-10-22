# catNavigation

独立 SwiftPM 侧栏组件，复用仓库 `docs/design/design-tokens.json` 的语义配色和系统字号。最低 iOS 17 / macOS 14，无第三方依赖。它只处理本地导航呈现；历史、任务、成果、记忆和设置由原生宿主提供，不产生模型回复、不请求网络、不管理账号或执行状态。

## 接入契约

在活跃原生工程添加本地 package，并将 `SidebarHost` 放在现有 `NavigationStack` 外。宿主保留现有 path、对话模型、草稿、生命周期和服务实例。以下只展示接线位置，`routeExistingDestination` / `snapshot` 是宿主自己的状态和方法，不能复制为新状态机。

```swift
import catNavigation

SidebarHost(
    isPresented: $sidebarPresented,
    isAtRoot: path.isEmpty && !otherModalPresented,
    snapshot: snapshot,
    onWillOpen: { composerFocused = false },
    onDismissed: { menuAccessibilityFocused = true },
    onSelect: routeExistingDestination
) {
    NavigationStack(path: $path) {
        ExistingConversationView()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton {
                        guard path.isEmpty && !otherModalPresented else { return }
                        sidebarPresented = true
                    }
                    .accessibilityFocused($menuAccessibilityFocused)
                }
            }
            // 保留宿主自己的 navigationDestination / sheet / alert。
    }
}
```

- **宿主注入**：`SidebarSnapshot` 只包含当前身份/范围可见的记录，顺序由宿主决定。`contextID` 是不含凭据的范围标识；切换后清空搜索并关闭侧栏。它不是鉴权或持久化隔离。宿主收到 `.conversation(id)` 后仍要按当前范围复核 ID，再切换现有对话；不要发送新 chat 来代替历史读取。
- **入口**：新对话、搜索、历史、任务、成果；底部记忆/设置。搜索只过滤传入标题/摘要，提供44pt清空动作；宿主传入的未发草稿摘要可见，无云端搜索。抽屉宽度按UX-1为 `min(320pt, 屏宽×0.86)`，极窄宿主仍保留44pt遮罩。默认任务、成果、记忆禁用并显示“暂不可用”，只有宿主接入真实路由后才能启用。新对话、历史、设置也应按宿主实际能力显式配置。不能导向假完成页面、手填任务表单或空的详情页。
- **详情和手势**：`isAtRoot` 必须来自真实 path，并在 sheet/其他模态交互时为 false。只在根页显示汉堡按钮；详情继续用系统返回。根页左边缘右滑打开；面板内左滑、遮罩、关闭按钮、VoiceOver escape 关闭。保留导航和滚动系统自己的 delegate。UIKit 桥接拒绝横向 `UIScrollView`、文本输入控件；自绘代码/内容横向区域需通过 `excludedGestureAreas` 注入 **host 本地坐标**，宿主布局变化时同步更新。不要另加全屏横向 DragGesture。
- **取消**：开门手势取消保持关闭，关门手势取消恢复打开；展开/关闭不修改草稿。`onWillOpen` 用于宿主撤销输入焦点，`onDismissed` 用于将 VoiceOver 焦点返回根页按钮。没有启用触觉；宿主如增加触觉需避免与既有反馈重复，并在真机验证。
- **无障碍和动效**：系统动态字体，无固定行高或最大字号封顶；内容和底部入口在同一纵向 ScrollView。按钮/搜索最低 44pt，按下态即时 opacity 0.78，无按下动画；释放 0.12s。面板打开时隐藏底层无障碍元素、聚焦标题，保留搜索/关闭的语义。Reduce Motion 禁用面板位移动画和跟手移动，手势结束后直接切换；默认收束 0.22s ease-out，无回弹。这些是实现参数，不是 <100ms 或无障碍实测通过。

## 复验

使用已有 Xcode，按实际位置设置进程 `DEVELOPER_DIR`，不要更改全局配置：

```sh
swift test --package-path packages/ios-navigation --scratch-path packages/ios-navigation/.build-verification
packages/ios-navigation/Scripts/verify-ios-sdk.sh
# 可选，仅已有专用 arm64 模拟器；不自动选择、不安装 App：
SIDEBAR_TEST_DEVICE=<专用模拟器标识> packages/ios-navigation/Scripts/verify-ios-sdk.sh
```

`swift test` 覆盖搜索/记录范围/路由能力和手势策略。SDK 脚本编译并链接全部 SwiftUI + UIKit 源码为独立 library，然后构建无 UI 的合成策略程序；可选 `simctl spawn` 只运行程序，不证明真实手势、VoiceOver、布局或延迟。

原生接入后仍需验证：根页边缘与详情系统返回、代码块横向滚动、键盘/IME、VoiceOver 焦点与取消、大字号 AX5 下底部可达、浅/深色截图、Reduce Motion，以及实际 press-to-frame 延迟。当前独立包没有 App 安装、主线接入或这些 UI 通过声明。详见 [本批次验收记录](../../docs/acceptance/ios-sidebar-navigation.md)。

官方参考入口：[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[NavigationStack](https://developer.apple.com/documentation/swiftui/navigationstack)、[UIScreenEdgePanGestureRecognizer](https://developer.apple.com/documentation/uikit/uiscreenedgepangesturerecognizer)。边缘宽 24pt、50% 收束阈值和 400pt/s flick 阈值是本组件的设计选择，未称为 HIG 要求。
