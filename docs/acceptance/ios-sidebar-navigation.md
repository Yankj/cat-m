# 独立侧栏导航组件：合成验收快照

日期：2026-10-12；基于 committed HEAD `b7fa4ee5f8d144208d51f6d0dcdee9259c4315b7`，分支 `feat/ios-sidebar-navigation`。改动仅独立 package、本文和唯一主计划；未修改冻结 apps/ios、活跃原生模型/生命周期/网络/签名。

| 实际运行层 | 结果 | 边界 |
|---|---|---|
| macOS SwiftPM XCTest | 12/12 PASS，0 failures | 搜索、范围 ID、全部路由能力、宽度、根页/边缘/输入/横向排除、方向、进度、flick、取消策略 |
| 已安装 iOS simulator SDK 编译 | PASS | 全部 SwiftUI + UIKit 桥接 library 编译/链接及 emit-module；iOS 17 deployment target，无安装、无主 App 链接 |
| 既有专用 arm64 iOS 模拟器 simctl spawn | 10/10 PASS | Foundation-only 策略程序，无 App 安装、无界面、无真实服务 |
| 仓库完整性/敏感信息/空白检查 | PASS | 冻结资产校验通过，新增文件扫描无阻断或待审命中 |
| 实际界面/用户体验 | NOT RUN | 真手势仲裁、VoiceOver、AX5、浅/深截图、键盘/IME、Press-to-frame <100ms、触觉未验 |

工具为已安装 Xcode 27.1 / iOS SDK 27.1，模拟器运行时 iOS 27.0；版本来自本机，不扩展为其他平台能力。重现命令与接入合同在 [package README](../../packages/ios-navigation/README.md)。原生宿主未合入；这一批 PASS 不抵扣主计划的 R1 产品 FAIL、连续多模态或真实任务成果验收。

首轮 macOS XCTest 本身 12/12 通过，但 shell 包装使用 zsh 只读变量 `status`，包装返回 1；改为任务专用退出变量后重跑。此前默认 sandbox 读取模拟器服务失败，获准读取本机模拟器后已完成策略检查，不留下模拟器阻塞。无真实服务调用、模型调用、账号/凭据创建、安装、数据清除、push 或部署。

## 文件与源码身份

以下是本次运行的源码/说明 SHA256；编译产物和原始终端日志保持在忽略目录，不纳入仓库。

| 文件 | SHA256 |
|---|---|
| `packages/ios-navigation/Package.swift` | `4ff2d872e8249c01f5c46deaa950948bc6a23719f8e22f010053062b547da3da` |
| `packages/ios-navigation/README.md` | `b5931ad3f95e985b6da5353e869cc4e5a3dce452c7677173a9ded642f468b43c` |
| `packages/ios-navigation/Scripts/verify-ios-sdk.sh` | `c404f481be38adf40cfcf76d6ed49b6aba459222bde04b7c1911008a5594554b` |
| `packages/ios-navigation/Sources/CatpawNavigation/SidebarGestureBridge.swift` | `af0a68ed6a3d78b9b3a474baa3ba1323d2d17fa994a5b8fca3c7daebd26d29da` |
| `packages/ios-navigation/Sources/CatpawNavigation/SidebarHost.swift` | `cd75dbf95e28f9c6da4e74ab423a06235db8d3991db6e51dfbf6f5fb3c8be8e5` |
| `packages/ios-navigation/Sources/CatpawNavigation/SidebarModel.swift` | `0debaf0f5c7a89a0399281da120c50a1a95797f2ac05fec6b832242931e4e7af` |
| `packages/ios-navigation/Sources/CatpawNavigation/SidebarPanel.swift` | `e9016741b94db7c5e4e361dc6843ba79e039e00b0dd2bbd61e6dc180c43f2d70` |
| `packages/ios-navigation/Sources/CatpawNavigation/SidebarTheme.swift` | `7781a291d4e796026fc0c88d8dc58237027bea9173f02c05437d044b959bc557` |
| `packages/ios-navigation/Tests/CatpawNavigationTests/SidebarTests.swift` | `326cc6b249600904d0562616742c51a9d8df32cf4f964680bb0d892fbb6e402c` |
| `packages/ios-navigation/Verification/PolicySmoke.swift` | `f74edd5a15e6eba8bb40f107f3bd4f6ee2d5a510b968bc7c26481faf6604b207` |
