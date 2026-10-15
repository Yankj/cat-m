import SwiftUI

/// Minimal R7 "开发者与高级 › 模型路由（仅免费）" form (DEBUG builds only).
/// Full visual treatment belongs to the design lane; this only persists the route header choice.
struct DeveloperModelRouteSection: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @AppStorage(ConversationModelRoute.defaultsKey) private var route = ConversationModelRoute.automatic.rawValue
    @ObservedObject private var monitor = ConnectionMonitor.shared
    var body: some View {
        Section(ui("开发者与高级")) {
            Picker(ui("模型路由（仅免费）"), selection: $route) {
                ForEach(ConversationModelRoute.allCases) { option in Text(ui(option.title)).tag(option.rawValue) }
            }
            LabeledContent(ui("连接状态"), value: monitor.state.labelKey.map { ui($0.key, arguments: $0.arguments) } ?? ui("在线"))
            if !monitor.waitingForNetwork.isEmpty { Text(ui("等待网络 · 联网后自动发送")).font(.footnote) }
            Text(ui("只在服务端已同意的免费路由间选择；繁忙时是否切换由服务端配置决定。永不使用付费路由。")).font(.footnote)
        }
    }
}
