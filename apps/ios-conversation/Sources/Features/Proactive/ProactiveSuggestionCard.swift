import SwiftUI

/// In-chat proactive suggestion: title, one-line reason, used-memory chips (→ memory page), and
/// 创建提醒 / 通知参会人 / 稍后 / 不用了. Rendered for catpaw-card kind `proactive_suggestion`.
@MainActor struct ProactiveSuggestionCard: View {
    let suggestion: ProactiveSuggestion
    @ObservedObject private var store = ProactiveSuggestionStore.shared
    @State private var memoryOpen = false
    @State private var inboxOpen = false
    @State private var whyOpen = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var s: ProactiveSuggestion { store.current(suggestion) }
    private var busy: Bool { store.busy.contains(s.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CategoryPaw(category: s.actions?.contains(.create_reminder) == true ? .reminder : (s.signals?.first?.kind.contains("mail") == true ? .email : .calendar)).accessibilityHidden(true)
                Text(ui("小猫主动提醒")).font(CatpawTypography.Role.caption.font.weight(.semibold)).foregroundStyle(CatpawColors.secondary)
                Spacer(minLength: 0)
                Button(ui("为什么找你")) { whyOpen = true }.font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    .touchTarget().accessibilityIdentifier("chat.proactiveSuggestion.why")
            }
            Text(s.title).font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
            Text(s.reason).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
            if !s.usedMemories.isEmpty { memoryChips }
            switch s.effectiveStatus {
            case .pending:
                if s.snoozeRestoreFailed { ProactiveStatusRow(textKey: "没能恢复稍后提醒", symbol: "exclamationmark.circle", accent: false) }
                actions
            case .done: ProactiveStatusRow(textKey: "已处理", symbol: "checkmark.circle.fill", accent: true)
            case .snoozed: ProactiveStatusRow(textKey: "稍后再提醒你", symbol: "clock", accent: false)
            case .dismissed: ProactiveStatusRow(textKey: "已忽略", symbol: "minus.circle", accent: false)
            }
            if let key = store.errorKey { Text(ui(key)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention) }
            Button(ui("查看全部主动提醒")) { inboxOpen = true }.font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                .touchTarget().accessibilityIdentifier("chat.proactiveSuggestion.inbox")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CatpawColors.ink.opacity(0.08), lineWidth: 0.5))
        .onAppear { store.adopt(suggestion) }
        .sheet(isPresented: $memoryOpen) { NavigationStack { MemoryLibraryView(backend: MemoryLibraryHub.pageBackend) } }
        .sheet(isPresented: $inboxOpen) { NavigationStack { ProactiveInboxView() } }
        .sheet(isPresented: $whyOpen) { ProactiveWhyHost(suggestion: s) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.proactiveSuggestion." + s.id)
    }

    private var memoryChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ui("参考了 {0} 条记忆", [String(s.usedMemories.count)])).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(s.usedMemories) { m in
                        Button { memoryOpen = true } label: {
                            Label(m.content, systemImage: "pawprint.fill").labelStyle(PawLabelStyle())
                                .font(CatpawTypography.Role.caption.font).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(CatpawColors.ink.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain).frame(minHeight: 44)
                        .accessibilityHint(ui("打开记忆页")).accessibilityIdentifier("chat.proactiveSuggestion.memory." + m.id)
                    }
                }
            }
        }
    }

    private var actions: some View {
        let list = s.remainingActions   // Codex P0-5: per-action state
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(list, id: \.self) { button($0) } }
            VStack(alignment: .leading, spacing: 6) { ForEach(list, id: \.self) { button($0) } }
        }
        .disabled(busy)
    }

    @ViewBuilder private func button(_ a: ProactiveSuggestion.Action) -> some View {
        switch a {
        case .create_reminder, .notify_attendees:
            Button(ui(Self.label(a))) { Task { await store.perform(a, s) } }
                .buttonStyle(CatpawPrimaryButtonStyle()).accessibilityIdentifier("chat.proactiveSuggestion." + a.rawValue)
        case .snooze, .dismiss:
            Button(ui(Self.label(a))) { Task { await store.perform(a, s) } }
                .font(CatpawTypography.Role.body.font).foregroundStyle(a == .dismiss ? CatpawColors.secondary : CatpawColors.ink)
                .touchTarget().accessibilityIdentifier("chat.proactiveSuggestion." + a.rawValue)
        }
    }

    static func label(_ a: ProactiveSuggestion.Action) -> String {
        switch a { case .create_reminder: "创建提醒"; case .notify_attendees: "告诉参会人"; case .snooze: "稍后"; case .dismiss: "不用了" }
    }
}

struct ProactiveStatusRow: View {
    let textKey: String
    let symbol: String
    let accent: Bool
    @Environment(\.locale) private var locale
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(accent ? CatpawBrand.paw : CatpawColors.secondary).accessibilityHidden(true)
            Text(AppLanguage(locale: locale).ui(textKey)).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
        }.frame(minHeight: 44)
    }
}

/// 主动 inbox: 待处理 / 已处理 / 已忽略.
@MainActor struct ProactiveInboxView: View {
    @ObservedObject private var store = ProactiveSuggestionStore.shared
    @State private var tab: ProactiveSuggestion.Status = .pending
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        List {
            Section {
                Picker(ui("状态"), selection: $tab) {
                    Text(ui("待处理")).tag(ProactiveSuggestion.Status.pending)
                    Text(ui("已处理")).tag(ProactiveSuggestion.Status.done)
                    Text(ui("已忽略")).tag(ProactiveSuggestion.Status.dismissed)
                }.pickerStyle(.segmented)
            }
            let rows = store.sorted(tab)
            if rows.isEmpty {
                Text(ui("这里还没有内容")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary)
            }
            ForEach(rows) { s in
                ProactiveSuggestionCard(suggestion: s).listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(ui("主动")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { dismiss() } } }
        .task { await store.load() }
        .refreshable { await store.load() }
        .accessibilityIdentifier("proactive.inbox")
    }
}

@MainActor enum ProactiveSuggestionAdapter {
    private static var registered = false
    static func register() {
        guard !registered else { return }; registered = true
        MarkdownCustomBlockRegistry.shared.register(kind: "proactive_suggestion") { payload, closed in
            if closed, let s = decode(payload) { ProactiveSuggestionCard(suggestion: s) } else { EmptyView() }
        }
    }
    static func decode(_ data: Data) -> ProactiveSuggestion? {
        try? ProactiveSyncWire.decoder().decode(ProactiveSuggestion.self, from: data)   // PR90g: fractional-second ISO dates
    }
}

#Preview("主动建议") { ScrollView { ProactiveSuggestionCard(suggestion: ProactiveSuggestionMock.samples[0]).padding() } }
#Preview("主动 inbox") { NavigationStack { ProactiveInboxView() } }
