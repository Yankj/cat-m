import SwiftUI

/// Minimal R7 "开发者与高级 › 模型路由（仅免费）" form (DEBUG builds only).
/// Full visual treatment belongs to the design lane; this only persists the route header choice.
struct DeveloperModelRouteSection: View {
    @AppStorage(ConversationModelRoute.defaultsKey) private var route = ConversationModelRoute.automatic.rawValue
    @ObservedObject private var monitor = ConnectionMonitor.shared
    var body: some View {
        Section("开发者与高级") {
            Picker("模型路由（仅免费）", selection: $route) {
                ForEach(ConversationModelRoute.allCases) { Text($0.title).tag($0.rawValue) }
            }
            LabeledContent("连接状态", value: monitor.state.label ?? "在线")
            Text("只在服务端已同意的免费路由间选择；繁忙时是否切下一个免费路由由服务端 CATPAW_MODEL_AUTO_FAILOVER 决定。永不使用付费路由。").font(.footnote)
        }
    }
}
