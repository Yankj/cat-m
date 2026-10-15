import SwiftUI

/// Navigation labels and search only. The host supplies records and handles every route.
/// Layout (r10 drawer): account header + glass collapse button, compact entries, section header,
/// tight lazily-paged conversation list, and a fixed floating bottom bar (settings · search · new).
public struct SidebarPanel: View {
    public var snapshot: SidebarSnapshot
    @Binding private var query: String
    private var theme: SidebarTheme
    private let localize:(String)->String
    private var isActive: Bool
    private var isModal: Bool
    private var onSelect: (SidebarDestination) -> Void
    private var onClose: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var searchFocused: Bool
    /// Client-side paging: the host hands over the full local history; render it a page at a time.
    @State private var visibleCount = SidebarPanel.pageSize
    static let pageSize = 40

    public init(snapshot: SidebarSnapshot, query: Binding<String>, theme: SidebarTheme = .catpaw,localize:@escaping (String)->String = {$0},
                isActive: Bool = true, isModal: Bool = true, onSelect: @escaping (SidebarDestination) -> Void, onClose: @escaping () -> Void) {
        self.snapshot = snapshot; _query = query; self.theme = theme;self.localize=localize
        self.isActive = isActive; self.isModal = isModal; self.onSelect = onSelect; self.onClose = onClose
    }

    public var body: some View {
        let records = snapshot.matching(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 12)
                entry(localize("任务"), icon: "checklist", destination: .tasks, identifier: "sidebar.tasks")
                if snapshot.capabilities.proactive { entry(localize("主动"), icon: "sparkles", destination: .proactive, identifier: "sidebar.proactive") }
                entry(localize("成果"), icon: "tray", destination: .results, identifier: "sidebar.results")
                entry(localize("记忆"), icon: "brain", destination: .memory, identifier: "sidebar.memory")
                Text(localize("对话")).font(theme.secondaryFont).foregroundStyle(theme.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 6)
                if records.isEmpty {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localize("还没有对话") : localize("没有找到对话"))
                        .font(theme.bodyFont).foregroundStyle(theme.secondary)
                        .padding(8).accessibilityIdentifier("sidebar.empty")
                }
                ForEach(records.prefix(visibleCount)) { record in
                    row(record)
                        .onAppear { if record.id == records.prefix(visibleCount).last?.id, visibleCount < records.count { visibleCount += Self.pageSize } }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(theme.panel).foregroundStyle(theme.ink)
        .buttonStyle(SidebarPressStyle())
        .accessibilityAddTraits(isModal ? .isModal : [])
        .accessibilityAction(.escape, onClose)
        .onChange(of: isActive, initial: true) { _, active in
            if !active { searchFocused = false }
            headingFocused = active
        }
        .onChange(of: query) { _, _ in visibleCount = Self.pageSize }
        .onChange(of: snapshot.contextID) { _, _ in visibleCount = Self.pageSize }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { select(.settings) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(theme.selection)
                        SidebarSymbol(name: "person.fill", font: theme.bodyFont).foregroundStyle(theme.secondary)
                    }.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(snapshot.account?.name ?? "Catpaw").font(theme.headingFont).lineLimit(1)
                                .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                            Image(systemName: "chevron.down").font(theme.captionFont).foregroundStyle(theme.secondary).accessibilityHidden(true)
                        }
                        if let detail = snapshot.account?.detail, !detail.isEmpty {
                            Text(detail).font(theme.captionFont).foregroundStyle(theme.secondary).lineLimit(1)
                        }
                    }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityHint(localize("账户与设置")).accessibilityIdentifier("sidebar.account")
            Spacer(minLength: 0)
            Button(action: onClose) {
                SidebarSymbol(name: "chevron.right", font: theme.bodyFont.weight(.semibold))
                    .frame(width: 44, height: 44).sidebarGlass(Circle(), fallback: theme.input)
            }.accessibilityLabel(localize("收起侧栏")).accessibilityIdentifier("sidebar.close")
        }.padding(.horizontal, 4)
    }

    // MARK: Rows

    private func entry(_ title: String, icon: String, destination: SidebarDestination, identifier: String) -> some View {
        let available = snapshot.permits(destination)
        return Button { select(destination) } label: {
            HStack(spacing: 12) {
                SidebarSymbol(name: icon, font: theme.bodyFont)
                Text(title).font(theme.bodyFont)
                Spacer(minLength: 0)
                if !available { Text(localize("暂不可用")).font(theme.captionFont).foregroundStyle(theme.secondary) }
            }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }.disabled(!available).accessibilityIdentifier(identifier)
    }

    private func row(_ record: SidebarConversation) -> some View {
        let selected = snapshot.selectedConversationID == record.id
        return Button { select(.conversation(record.id)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title.isEmpty ? localize("未命名对话") : record.title).font(theme.bodyFont)
                    .fontWeight(selected ? .semibold : .regular).lineLimit(1)
                let meta = [record.preview.flatMap { $0.isEmpty ? nil : localize("草稿") }, record.updatedAt.map(relative)]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(theme.captionFont).foregroundStyle(theme.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 8).frame(minHeight: 44)
            .background((selected ? theme.selection : Color.clear).opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }.disabled(!snapshot.permits(.conversation(record.id)))
            .accessibilityValue(selected ? localize("当前对话") : "")
            .accessibilityIdentifier("sidebar.conversation.\(record.id.uuidString)")
    }

    private func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return localize("昨天") }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { select(.settings) } label: {
                SidebarSymbol(name: "gearshape", font: theme.bodyFont).frame(width: 48, height: 48).sidebarGlass(Circle(), fallback: theme.input)
            }.disabled(!snapshot.permits(.settings)).accessibilityLabel(localize("设置")).accessibilityIdentifier("sidebar.settings")
            HStack(spacing: 6) {
                SidebarSymbol(name: "magnifyingglass", font: theme.bodyFont).foregroundStyle(theme.secondary)
                TextField(localize("搜索"), text: $query)
                    .focused($searchFocused).font(theme.bodyFont).submitLabel(.search)
                    .accessibilityLabel(localize("搜索对话")).accessibilityIdentifier("sidebar.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        SidebarSymbol(name: "xmark.circle.fill", font: theme.bodyFont).foregroundStyle(theme.secondary)
                            .frame(minWidth: 32, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel(localize("清除搜索")).accessibilityIdentifier("sidebar.search.clear")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 48).sidebarGlass(Capsule(), fallback: theme.input)
            .contentShape(Capsule()).onTapGesture { searchFocused = true }
            Button { select(.newConversation) } label: {
                SidebarSymbol(name: "square.and.pencil", font: theme.bodyFont).foregroundStyle(theme.panel).frame(width: 48, height: 48).background(theme.ink, in: Circle())
            }.disabled(!snapshot.permits(.newConversation)).accessibilityLabel(localize("新对话")).accessibilityIdentifier("sidebar.new")
        }
        .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
        .background {
            // Blurred fade so rows scroll softly under the floating bar.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [theme.panel.opacity(0), theme.panel.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            }.ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
        }
    }

    private func select(_ destination: SidebarDestination) {
        guard snapshot.permits(destination) else { return }
        searchFocused = false
        onSelect(destination)
    }
}

private extension View {
    /// Liquid Glass on iOS 26, material fallback before.
    @ViewBuilder func sidebarGlass<S: Shape>(_ shape: S, fallback: Color) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape).overlay(shape.stroke(fallback, lineWidth: 0.5))
        }
    }
}
