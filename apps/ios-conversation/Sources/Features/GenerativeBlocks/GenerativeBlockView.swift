import SwiftUI

/// r10 §4.2 native block renderer. One shell for every kind; `sheet` (or `presentation: sheet`, or forms with
/// more than four fields) shows a summary card that opens the content in a bottom sheet.
@MainActor struct GenerativeBlockView: View {
    let block: GenerativeBlock
    @ObservedObject var store: GenerativeBlockStore
    var validationError: GenerativeBlockError? = nil
    @State private var sheet = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var live: GenerativeBlock { store.current(block) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let expired = live.isExpired(at: context.date)
            GenerativeBlockShell(block: live) {
                if live.opensAsSheet && store.responses[live.id] == nil {
                    GenerativeSheetSummary(block: live, expired: expired) { sheet = true }
                } else {
                    GenerativeBlockContent(block: live, store: store, expired: expired, onDone: { sheet = false })
                }
            }
            .sheet(isPresented: $sheet) {
                ScrollView { GenerativeBlockContent(block: live, store: store, expired: expired, onDone: { sheet = false }).padding(20) }
                    .presentationDetents([.medium, .large]).accessibilityIdentifier("chat.block.sheet")
            }
        }
        .onAppear { store.adopt(block, error: validationError) }
    }
}

/// r10 shell: radius 16, warm panel, 0.5pt ink-8% stroke, padding 16, enters with opacity + y8.
@MainActor struct GenerativeBlockShell<Content: View>: View {
    let block: GenerativeBlock
    @ViewBuilder var content: Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CatpawColors.ink.opacity(0.08), lineWidth: 0.5))
            .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { appeared = true } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.block." + block.id)
    }
}

@MainActor struct GenerativeBlockContent: View {
    let block: GenerativeBlock
    @ObservedObject var store: GenerativeBlockStore
    let expired: Bool
    var onDone: () -> Void = {}
    private var kind: GenerativeBlock.Kind {
        guard block.kind == .sheet else { return block.kind }
        return block.content ?? ((block.fields ?? []).isEmpty ? ((block.items ?? []).isEmpty ? .card : .choices) : .form)
    }
    var body: some View {
        let respond: (GenerativeBlockResponse) -> Void = { store.respond($0); onDone() }
        switch kind {
        case .choices: GenerativeChoicesView(block: block, response: store.responses[block.id], locked: store.resolved.contains(block.id), expired: expired, respond: respond, reopen: { store.reopen(block.id) })
        case .confirm: GenerativeConfirmView(block: block, response: store.responses[block.id], expired: expired, respond: respond)
        case .form: GenerativeFormView(block: block, response: store.responses[block.id], expired: expired, respond: respond)
        case .list: GenerativeListView(block: block, expired: expired, respond: respond)
        case .progress: GenerativeProgressView(block: block)
        case .card, .sheet: GenerativeCardView(block: block, response: store.responses[block.id], expired: expired, respond: respond)
        }
    }
}

// MARK: Shared pieces

@MainActor struct GenerativeBlockHeader: View {
    let block: GenerativeBlock
    var icon: String? = nil
    var body: some View {
        if block.title != nil || icon != nil {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(CatpawBrand.paw).accessibilityHidden(true) }
                if let title = block.title { Text(title).font(CatpawTypography.Role.heading.font.weight(.semibold)).foregroundStyle(CatpawColors.ink).accessibilityAddTraits(.isHeader) }
            }
        }
        if let text = block.body, !text.isEmpty {
            Text(LocalizedStringKey(text)).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.block.body")
        }
    }
}

@MainActor struct GenerativeExpiredLabel: View {
    @Environment(\.locale) private var locale
    var body: some View {
        Label(AppLanguage(locale: locale).ui("已过期"), systemImage: "clock").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            .accessibilityIdentifier("chat.block.expired")
    }
}

@MainActor struct GenerativeActionRow: View {
    let actions: [GenerativeBlock.Action]
    var disabled = false
    let tap: (GenerativeBlock.Action) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(actions) { action in
                switch action.style ?? .secondary {
                case .primary:
                    Button { tap(action) } label: { Text(action.label).frame(maxWidth: .infinity) }.primaryAction()
                        .accessibilityIdentifier("chat.block.action." + action.id)
                case .destructive:
                    Button(role: .destructive) { tap(action) } label: { Text(action.label).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).tint(.red).accessibilityIdentifier("chat.block.action." + action.id)
                case .secondary:
                    Button { tap(action) } label: { Text(action.label).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered).tint(CatpawColors.ink).accessibilityIdentifier("chat.block.action." + action.id)
                }
            }
        }
        .disabled(disabled)
    }
}

@MainActor struct GenerativeResolvedRow: View {
    let text: String
    var icon = "checkmark.circle.fill"
    var edit: (() -> Void)? = nil
    var body: some View {
        let label = Label(text, systemImage: icon).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        if let edit { Button(action: edit) { label }.buttonStyle(.plain).accessibilityIdentifier("chat.block.summary") }
        else { label.accessibilityIdentifier("chat.block.summary") }
    }
}

@MainActor struct GenerativeSheetSummary: View {
    let block: GenerativeBlock
    let expired: Bool
    let open: () -> Void
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GenerativeBlockHeader(block: block, icon: block.kind == .form || !(block.fields ?? []).isEmpty ? "square.and.pencil" : "rectangle.bottomhalf.inset.filled")
            if expired { GenerativeExpiredLabel() }
            Button(action: open) { Text(!(block.fields ?? []).isEmpty ? ui("填写") : ui("打开")).frame(maxWidth: .infinity) }
                .primaryAction().disabled(expired).accessibilityIdentifier("chat.block.openSheet")
        }
    }
}

@MainActor struct GenerativeBlockPlaceholder: View {
    @Environment(\.locale) private var locale
    var body: some View {
        HStack(spacing: 8) { ProgressView(); Text(AppLanguage(locale: locale).ui("正在准备卡片…")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("chat.block.placeholder")
    }
}

func generativeTime(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
