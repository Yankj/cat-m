import SwiftUI

/// Navigation labels and search only. The host supplies records and handles every route.
public struct SidebarPanel: View {
    public var snapshot: SidebarSnapshot
    @Binding private var query: String
    private var theme: SidebarTheme
    private let localize:(String)->String
    private var isActive: Bool
    private var onSelect: (SidebarDestination) -> Void
    private var onClose: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var searchFocused: Bool

    public init(snapshot: SidebarSnapshot, query: Binding<String>, theme: SidebarTheme = .catpaw,localize:@escaping (String)->String = {$0},
                isActive: Bool = true, onSelect: @escaping (SidebarDestination) -> Void, onClose: @escaping () -> Void) {
        self.snapshot = snapshot; _query = query; self.theme = theme;self.localize=localize
        self.isActive = isActive; self.onSelect = onSelect; self.onClose = onClose
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Catpaw").font(theme.titleFont.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        Button(action: onClose) {
                            SidebarSymbol(name: "xmark", font: theme.bodyFont)
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel(localize("关闭侧栏")).accessibilityIdentifier("sidebar.close")
                    }
                    HStack(spacing: 4) {
                        TextField(localize("搜索对话"), text: $query)
                            .focused($searchFocused)
                            .font(theme.bodyFont).padding(.leading,12).frame(minHeight: 44)
                            .accessibilityLabel(localize("搜索对话")).accessibilityIdentifier("sidebar.search")
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                SidebarSymbol(name: "xmark.circle.fill", font: theme.bodyFont).foregroundStyle(theme.secondary)
                                    .frame(minWidth:44,minHeight:44).contentShape(Rectangle())
                            }.accessibilityLabel(localize("清除搜索")).accessibilityIdentifier("sidebar.search.clear")
                        }
                    }
                        .background(theme.input, in: RoundedRectangle(cornerRadius: 14))
                    route(localize("新对话"), icon: "square.and.pencil", destination: .newConversation, identifier: "sidebar.new")
                    route(localize("任务"), icon: "checklist", destination: .tasks, identifier: "sidebar.tasks")
                    route(localize("成果"), icon: "tray", destination: .results, identifier: "sidebar.results")
                    Divider().overlay(theme.separator).padding(.vertical, 8)
                    Text(localize("对话")).font(theme.headingFont).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 12)
                    let records = snapshot.matching(query)
                    if records.isEmpty {
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localize("还没有对话") : localize("没有找到对话"))
                            .font(theme.bodyFont).foregroundStyle(theme.secondary)
                            .padding(12).accessibilityIdentifier("sidebar.empty")
                    }
                    ForEach(records) { record in
                        let selected = snapshot.selectedConversationID == record.id
                        Button { select(.conversation(record.id)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading,spacing:4) {
                                    Text(record.title.isEmpty ? localize("未命名对话") : record.title).font(theme.bodyFont)
                                    if let preview=record.preview,!preview.isEmpty {
                                        Text(localize("草稿 · ")+preview).font(theme.captionFont).lineLimit(2)
                                            .foregroundStyle(theme.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if selected { SidebarSymbol(name: "checkmark", font: theme.bodyFont) }
                            }.padding(12).frame(minHeight: 44)
                                .background(selected ? theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                                .contentShape(Rectangle())
                        }.disabled(!snapshot.permits(.conversation(record.id)))
                            .accessibilityValue(selected ? localize("当前对话") : "")
                            .accessibilityIdentifier("sidebar.conversation.\(record.id.uuidString)")
                    }
                    Spacer(minLength: 24)
                    Divider().overlay(theme.separator)
                    route(localize("记忆"), icon: "brain", destination: .memory, identifier: "sidebar.memory")
                    route(localize("设置"), icon: "gearshape", destination: .settings, identifier: "sidebar.settings")
                }.padding(16).frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
        }.background(theme.panel).foregroundStyle(theme.ink)
            .buttonStyle(SidebarPressStyle())
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onClose)
            .onChange(of: isActive, initial: true) { _, active in
                if !active { searchFocused = false }
                headingFocused = active
            }
    }

    private func route(_ title: String, icon: String, destination: SidebarDestination, identifier: String) -> some View {
        let available = snapshot.permits(destination)
        return Button { select(destination) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SidebarSymbol(name: icon, font: theme.bodyFont)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(theme.bodyFont)
                    if !available { Text(localize("暂不可用")).font(theme.secondaryFont).foregroundStyle(theme.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).frame(minHeight: 44).contentShape(Rectangle())
        }.disabled(!available).accessibilityIdentifier(identifier)
    }
    private func select(_ destination: SidebarDestination) {
        guard snapshot.permits(destination) else { return }
        onSelect(destination)
    }
}
