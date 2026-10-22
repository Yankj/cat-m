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
                if let status = store.resolved[live.id], store.responses[live.id] == nil {
                    // Closed without a stored answer (dismissed / expired / cancelled / errored, or answered elsewhere).
                    GenerativeBlockHeader(block: live)
                    GenerativeResolvedRow(text: resolutionText(status), icon: status == "submitted" ? "checkmark.circle.fill" : "minus.circle")
                } else if live.opensAsSheet && store.responses[live.id] == nil {
                    GenerativeSheetSummary(block: live, expired: expired) { sheet = true }
                } else {
                    GenerativeBlockContent(block: live, store: store, expired: expired, onDone: { sheet = false })
                }
                submissionFooter
            }
            .onChange(of: expired, initial: true) { _, value in if value { store.markExpired(live.id) } }
            .sheet(isPresented: $sheet) {
                ScrollView { GenerativeBlockContent(block: live, store: store, expired: expired, onDone: { sheet = false }).padding(20) }
                    .presentationDetents([.medium, .large]).accessibilityIdentifier("chat.block.sheet")
            }
        }
        .onAppear { store.adopt(block, error: validationError) }
    }

    @ViewBuilder private var submissionFooter: some View {
        let needsAnswer = live.interruptId != nil && !store.isLocked(live.id)
        switch store.submissions[live.id] ?? .idle {
        case .submitting: ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("chat.block.submitting")
        case .queued:
            HStack(spacing: 8) {
                Image(systemName: "clock").accessibilityHidden(true)
                Text(ui("已排队 · 回复结束后发送")).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(ui("取消")) { store.cancelQueued(live.id) }.touchTarget().accessibilityIdentifier("chat.block.queued.cancel")
            }.font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).accessibilityIdentifier("chat.block.queued")
        case .failed(let message):
            Text(ui(message)).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.block.error")
        case .idle: EmptyView()
        }
        if needsAnswer, store.submissions[live.id] != .submitting, store.submissions[live.id] != .queued {
            Button(ui("跳过")) { store.dismiss(live.id) }.font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
                .touchTarget().accessibilityIdentifier("chat.block.dismiss")
        }
    }
    private func resolutionText(_ status: String) -> String {
        switch status {
        case "submitted", "answered": ui("已回答")
        case "dismissed": ui("已跳过")
        case "expired": ui("已过期")
        case "cancelled": ui("已取消")
        default: ui("卡片无法显示，已告知助手")
        }
    }
}

/// r10 shell: radius 16, warm panel, 0.5pt ink-8% stroke, padding 16, enters with opacity + y8.
@MainActor struct GenerativeBlockShell<Content: View>: View {
    let block: GenerativeBlock
    @ViewBuilder var content: Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(catColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(catColors.ink.opacity(0.08), lineWidth: 0.5))
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
        block.contentKind
    }
    private var disabled: Bool { store.submissions[block.id] == .submitting || store.submissions[block.id] == .queued || store.isLocked(block.id) }
    var body: some View {
        let respond: (GenerativeBlockResponse) -> Void = { store.respond($0); onDone() }
        Group { switch kind {
        case .choices: GenerativeChoicesView(block: block, response: store.responses[block.id], locked: store.isLocked(block.id) || block.interruptId != nil, expired: expired, respond: respond, reopen: { store.reopen(block.id) })
        case .confirm: GenerativeConfirmView(block: block, response: store.responses[block.id], expired: expired, respond: respond)
        case .form: GenerativeFormView(block: block, response: store.responses[block.id], expired: expired, respond: respond)
        case .list: GenerativeListView(block: block, expired: expired, respond: respond)
        case .progress: GenerativeProgressView(block: block)
        case .place: GenerativePlaceView(block: block)
        case .event: GenerativeEventView(block: block)
        case .card, .sheet: GenerativeCardView(block: block, response: store.responses[block.id], expired: expired, respond: respond)
        } }
        .disabled(disabled && store.responses[block.id] == nil)
    }
}

// MARK: Shared pieces

@MainActor struct GenerativeBlockHeader: View {
    let block: GenerativeBlock
    var icon: String? = nil
    var body: some View {
        if block.title != nil || icon != nil {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(catBrand.paw).accessibilityHidden(true) }
                if let title = block.title { Text(title).font(catTypography.Role.heading.font.weight(.semibold)).foregroundStyle(catColors.ink).accessibilityAddTraits(.isHeader) }
            }
        }
        if let text = block.body, !text.isEmpty {
            Text(GenerativeSafeMarkdown.render(text)).font(catTypography.Role.body.font).foregroundStyle(catColors.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.block.body")
        }
    }
}

@MainActor struct GenerativeExpiredLabel: View {
    @Environment(\.locale) private var locale
    var body: some View {
        Label(AppLanguage(locale: locale).ui("已过期"), systemImage: "clock").font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
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
                        .buttonStyle(.bordered).tint(catColors.ink).accessibilityIdentifier("chat.block.action." + action.id)
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
        let label = Label(text, systemImage: icon).font(catTypography.Role.body.font).foregroundStyle(catColors.ink.opacity(0.55))
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
        HStack(spacing: 8) { ProgressView(); Text(AppLanguage(locale: locale).ui("正在准备卡片…")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary) }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(catColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("chat.block.placeholder")
    }
}

func generativeTime(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

/// Block text is untrusted (contract §0.7): inline markdown only, no HTML, links are not tappable and show their host.
enum GenerativeSafeMarkdown {
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        var out = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            guard let url = run.link else { out += piece; continue }
            piece.link = nil; piece.underlineStyle = .single; out += piece
            if let host = url.host, !host.isEmpty { out += AttributedString(" (" + host + ")") }
        }
        return out
    }
}

/// https-only image without cookies or credentials (ephemeral session), contract §0.7.
@MainActor struct GenerativeRemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never; c.urlCredentialStorage = nil; c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { catColors.ink.opacity(0.05) }
        }
        .task(id: url) {
            guard url.scheme == "https", let (data, response) = try? await Self.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 5_000_000 else { return }
            image = UIImage(data: data)
        }
    }
}
