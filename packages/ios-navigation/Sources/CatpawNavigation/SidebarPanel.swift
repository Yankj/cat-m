import SwiftUI

/// Navigation labels and search only. The host supplies records and handles every route.
public struct SidebarPanel: View {
    public var snapshot: SidebarSnapshot
    @Binding private var query: String
    private var theme: SidebarTheme
    private var onSelect: (SidebarDestination) -> Void
    private var onClose: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool

    public init(snapshot: SidebarSnapshot, query: Binding<String>, theme: SidebarTheme = .catpaw,
                onSelect: @escaping (SidebarDestination) -> Void, onClose: @escaping () -> Void) {
        self.snapshot = snapshot; _query = query; self.theme = theme
        self.onSelect = onSelect; self.onClose = onClose
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Catpaw").font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.body)
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel("关闭侧栏").accessibilityIdentifier("sidebar.close")
                    }
                    TextField("搜索对话", text: $query)
                        .font(.body).padding(12).frame(minHeight: 44)
                        .background(theme.input, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("搜索对话").accessibilityIdentifier("sidebar.search")
                    route("新对话", icon: "square.and.pencil", destination: .newConversation, identifier: "sidebar.new")
                    route("任务", icon: "checklist", destination: .tasks, identifier: "sidebar.tasks")
                    route("成果", icon: "tray", destination: .results, identifier: "sidebar.results")
                    Divider().overlay(theme.separator).padding(.vertical, 8)
                    Text("对话").font(.headline).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 12)
                    let records = snapshot.matching(query)
                    if records.isEmpty {
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "还没有对话" : "没有找到对话")
                            .font(.body).foregroundStyle(theme.secondary)
                            .padding(12).accessibilityIdentifier("sidebar.empty")
                    }
                    ForEach(records) { record in
                        let selected = snapshot.selectedConversationID == record.id
                        Button { select(.conversation(record.id)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(record.title.isEmpty ? "未命名对话" : record.title)
                                    .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                if selected { Image(systemName: "checkmark").font(.body).accessibilityHidden(true) }
                            }.padding(12).frame(minHeight: 44)
                                .background(selected ? theme.input : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                                .contentShape(Rectangle())
                        }.disabled(!snapshot.permits(.conversation(record.id)))
                            .accessibilityValue(selected ? "当前对话" : "")
                            .accessibilityIdentifier("sidebar.conversation.\(record.id.uuidString)")
                    }
                    Spacer(minLength: 24)
                    Divider().overlay(theme.separator)
                    route("记忆", icon: "brain", destination: .memory, identifier: "sidebar.memory")
                    route("设置", icon: "gearshape", destination: .settings, identifier: "sidebar.settings")
                }.padding(16).frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
        }.background(theme.panel).foregroundStyle(theme.ink)
            .buttonStyle(SidebarPressStyle())
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onClose)
            .onAppear { headingFocused = true }
    }

    private func route(_ title: String, icon: String, destination: SidebarDestination, identifier: String) -> some View {
        let available = snapshot.permits(destination)
        return Button { select(destination) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon).font(.body).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body)
                    if !available { Text("暂不可用").font(.subheadline).foregroundStyle(theme.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).frame(minHeight: 44).contentShape(Rectangle())
        }.disabled(!available).accessibilityIdentifier(identifier)
    }
    private func select(_ destination: SidebarDestination) {
        guard snapshot.permits(destination) else { return }
        onSelect(destination)
    }
}
