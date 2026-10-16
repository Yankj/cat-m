import SwiftUI

/// 为什么找你: signals, memories used, actions taken, 撤销, and 有帮助 / 没帮上 / 打扰到我 feedback.
@MainActor struct ProactiveWhyHost: View {
    let suggestion: ProactiveSuggestion
    @ObservedObject private var store = ProactiveSuggestionStore.shared
    @State private var memoryOpen = false
    @State private var sent: ProactiveFeedback?
    @State private var feedbackState: ProactiveSuggestionStore.FeedbackOutcome?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var s: ProactiveSuggestion { store.current(suggestion) }

    var body: some View {
        NavigationStack {
            List {
                Section { Text(s.reason).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true) }
                Section(ui("小猫注意到")) {
                    if (s.signals ?? []).isEmpty { Text(ui("没有更多信号")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary) }
                    ForEach(Array((s.signals ?? []).enumerated()), id: \.offset) { _, sig in
                        Label { Text(sig.text).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink) } icon: {
                            Image(systemName: Self.symbol(sig.kind)).foregroundStyle(CatpawBrand.paw)
                        }
                    }
                }
                Section(ui("用到的记忆")) {
                    if s.usedMemories.isEmpty { Text(ui("这次没有用到记忆")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary) }
                    ForEach(s.usedMemories) { m in
                        Button { memoryOpen = true } label: {
                            Label(m.content, systemImage: "pawprint.fill").labelStyle(PawLabelStyle()).font(CatpawTypography.Role.body.font)
                        }.accessibilityHint(ui("打开记忆页"))
                    }
                }
                Section(ui("已经做了什么")) {
                    let taken = s.taken ?? []
                    if taken.isEmpty { Text(ui("还没有执行任何操作")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary) }
                    ForEach(Array(taken.enumerated()), id: \.offset) { _, t in
                        HStack {
                            Text(ui(ProactiveSuggestionCard.label(t.action))).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                            Spacer()
                            Text(t.at, style: .time).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                        }
                    }
                    if !taken.isEmpty {
                        Button(ui("撤销"), role: .destructive) { Task { await store.undo(s) } }
                            .disabled(store.busy.contains(s.id)).accessibilityIdentifier("proactive.why.undo")
                    }
                }
                Section(ui("这次提醒怎么样？")) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { feedbackButtons }
                        VStack(alignment: .leading, spacing: 6) { feedbackButtons }
                    }
                    if sent != nil { Text(ui(feedbackState == .notSaved ? "没能记下，请重试" : feedbackState == .queued ? "已记在本机，暂未同步，稍后自动重试" : feedbackState == .synced ? "谢谢，小猫记下了" : "正在记下…")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary) }
                }
            }
            .navigationTitle(ui("为什么找你")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { dismiss() } } }
            .sheet(isPresented: $memoryOpen) { NavigationStack { MemoryLibraryView(backend: MemoryLibraryHub.pageBackend) } }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("proactive.why")
    }

    @ViewBuilder private var feedbackButtons: some View {
        ForEach(ProactiveFeedback.allCases, id: \.self) { f in
            Button { sent = f; Task { feedbackState = await store.feedback(f, s) } } label: {
                Label(ui(Self.feedbackKey(f)), systemImage: sent == f ? "checkmark.circle.fill" : Self.feedbackSymbol(f))
                    .font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.ink)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(sent == f ? CatpawBrand.paw.opacity(0.16) : CatpawColors.ink.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.borderless).disabled(sent != nil).accessibilityIdentifier("proactive.why.feedback." + f.rawValue)
        }
    }
    static func feedbackKey(_ f: ProactiveFeedback) -> String { switch f { case .helpful: "有帮助"; case .not_helpful: "没帮上"; case .intrusive: "打扰到我" } }
    static func feedbackSymbol(_ f: ProactiveFeedback) -> String { switch f { case .helpful: "hand.thumbsup"; case .not_helpful: "hand.thumbsdown"; case .intrusive: "bell.slash" } }
    static func symbol(_ kind: String) -> String {
        switch kind { case "calendar": "calendar"; case "travel": "tram"; case "time": "clock"; case "location": "location"; case "weather": "cloud.sun"; default: "info.circle" }
    }
}

#Preview("为什么找你") { Color.clear.sheet(isPresented: .constant(true)) { ProactiveWhyHost(suggestion: ProactiveSuggestionMock.samples[1]) } }
