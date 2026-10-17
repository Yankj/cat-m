import SwiftUI
import UIKit

/// Four-phase assistant answer (design.md §4). Drop-in for `ConversationAnswerView` once a provider exists;
/// the existing view keeps working for transcript messages that have no phase data.
@MainActor struct PhasedAnswerView<Model: AnswerPhaseProviding>: View {
    @ObservedObject var model: Model
    var canQuote = true
    var onQuote: (String) -> Void = { _ in }
    var onRegenerate: (() -> Void)? = nil
    var onVerify: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThinkingHeader(model: model, onRegenerate: onRegenerate, onVerify: onVerify)
            if model.phase != .thinking {
                FadingStreamText(text: model.text, complete: model.phase == .settled)
                    .transition(.opacity)
            }
            switch model.phase {
            case .settled:
                SettledFooter(text: model.text, sources: model.sources, canQuote: canQuote, onQuote: onQuote, onRegenerate: onRegenerate,
                              generationSeconds: model.generationSeconds)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case let .interrupted(reason, reconciliation) where !model.usesStatusLine:
                // status-line SPEC §8: one failure surface — with the status row, the row carries reason + button.
                InterruptedFooter(reason: reason, reconciliationRequired: reconciliation, onVerify: onVerify, onRegenerate: onRegenerate)
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(CatpawMotion.resolved(CatpawMotion.thinkingCollapse, reduceMotion), value: model.phase)
    }
}

/// Adapts a persisted row to the projection while the projection itself consumes
/// the service's authoritative live event broadcast.
@MainActor struct LivePhasedAnswerView: View {
    let service: ConversationSessionService
    let message: ConversationTranscriptMessage
    let turn: ConversationTurnRecord
    var canQuote = true
    var onQuote: (String) -> Void
    var onVerify: (() -> Void)? = nil
    @StateObject private var projection: AnswerPhaseProjection

    init(service: ConversationSessionService, message: ConversationTranscriptMessage, turn: ConversationTurnRecord,
         canQuote: Bool = true, onQuote: @escaping (String) -> Void, onVerify: (() -> Void)? = nil) {
        self.service = service
        self.message = message
        self.turn = turn
        self.canQuote = canQuote
        self.onQuote = onQuote
        self.onVerify = onVerify
        _projection = StateObject(wrappedValue: AnswerPhaseProjection(service: service, operationID: turn.id, message: message, turn: turn))
    }

    var body: some View {
        PhasedAnswerView(model: projection, canQuote: canQuote, onQuote: onQuote, onVerify: onVerify)
            .onAppear { projection.reconcile(message: message, turn: turn) }
            .onChange(of: message.content) { _, _ in projection.reconcile(message: message, turn: turn) }
            .onChange(of: turn.state) { _, _ in projection.reconcile(message: message, turn: turn) }
            .onChange(of: turn.error) { _, _ in projection.reconcile(message: message, turn: turn) }
            .onChange(of: turn.reasoningSummary) { _, _ in projection.reconcile(message: message, turn: turn) }
            .onChange(of: turn.thinkingMs) { _, _ in projection.reconcile(message: message, turn: turn) }
    }
}

/// Pre-token thinking row: shown while a turn is dispatched/running and no assistant message exists yet.
/// Subscribes to turnEvents so reasoning_summary lands before the first text delta.
@MainActor struct PendingThinkingRow: View {
    let service: ConversationSessionService
    let turn: ConversationTurnRecord
    @StateObject private var projection: AnswerPhaseProjection
    init(service: ConversationSessionService, turn: ConversationTurnRecord) {
        self.service = service; self.turn = turn
        _projection = StateObject(wrappedValue: AnswerPhaseProjection(service: service, operationID: turn.id))
    }
    var body: some View {
        PhasedAnswerView(model: projection, canQuote: false)
            .onAppear { if let s = turn.reasoningSummary { projection.thinkingSummary = s }; projection.restoreStatus(turn: turn) }
            .onChange(of: turn.awaitingApproval) { _, _ in projection.restoreStatus(turn: turn) }
            .onChange(of: turn.reasoningSummary) { _, s in if let s { projection.thinkingSummary = s } }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: A/B — thinking row ↔ "thought for Xs · N steps" chip

@MainActor private struct ThinkingHeader<Model: AnswerPhaseProviding>: View {
    @ObservedObject var model: Model
    var onRegenerate: (() -> Void)? = nil
    var onVerify: (() -> Void)? = nil
    @Environment(\.statusLineScrollToCard) private var scrollToCard
    /// nil = follow the phase (open while thinking with steps, closed once text arrives); set once the user taps.
    @State private var userExpanded: Bool?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var thinking: Bool { model.phase == .thinking }
    private var expanded: Bool { userExpanded ?? thinking }
    private var hasDetail: Bool { !model.steps.isEmpty || !(model.thinkingSummary ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // status-line v1.0: nothing in the first second of a turn (fast turns never flash a row).
            // status-line: nothing in the first 0.6 s of a turn (visual SPEC §6); terminal rows stay in place (§8).
            if thinking {
                if !model.usesStatusLine { liveRow } else if let line = model.statusLine { statusRow(line) }
            } else if model.usesStatusLine, let terminal = terminalStatus { terminalRow(terminal) }
            else if hasDetail { resultRow }
            if expanded && !model.steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    // Visual SPEC v2 §1: glyph centre x 12 (= kitten slot centre), step text at x 32.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.steps) { step in
                            ReplyStepRow(step: step, current: thinking && step.id == currentStepID)
                        }
                    }
                    .padding(.leading, 4)
                    if !model.sources.isEmpty { SourceCapsuleStrip(sources: Array(model.sources.prefix(4))) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !thinking && expanded, let summary = model.thinkingSummary, !summary.isEmpty {
                Text(summary).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(CatpawMotion.resolved(CatpawMotion.thinkingCollapse, reduceMotion), value: expanded)
        .animation(CatpawMotion.resolved(CatpawMotion.thinkingCollapse, reduceMotion), value: model.steps.count)
        .accessibilityIdentifier("chat.answer.thinking")
    }

    private var currentStepID: String? { model.steps.last(where: { $0.state == .running })?.id }

    /// Stage 1: one quiet line — paw presence + 「思考中 · Ns」, ticking once a second (no shimmer pile).
    /// With steps, the line carries the running step's title instead and becomes the collapse toggle.
    private var liveRow: some View {
        Button { if !model.steps.isEmpty { userExpanded = !expanded } } label: {
            HStack(spacing: 8) {
                PlushMascot(pose: model.thinkingSummary != nil ? .thinking : .idle, size: 22)
                    .frame(width: 24, height: 24)
                // chat-ux-1505 #3: mascot + 「Catpaw 正在工作」 (or the running tool step) with a shimmer sweep.
                Text(workingTitle)
                    .font(CatpawTypography.Role.secondary.font)
                    .foregroundStyle(CatpawColors.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .workingShimmer(statusAnimated)   // waiting on the user / failed / stopped: static
                    .contentTransition(.opacity)
                    .animation(CatpawMotion.resolved(CatpawMotion.thinkingCollapse, reduceMotion), value: workingTitle)
                    .accessibilityIdentifier(statusIdentifier)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workingTitle)
        .accessibilityValue(Self.elapsed(from: model.thinkingStartedAt, to: Date()))
        .onChange(of: workingTitle) { _, title in
            // VoiceOver: announce state changes, at most once every 2 s.
            guard UIAccessibility.isVoiceOverRunning, announcer.allow(at: Date()) else { return }
            UIAccessibility.post(notification: .announcement, argument: title)
        }
    }
    @State private var announcer = StatusLineAnnouncementThrottle()
    private var statusIdentifier: String {
        if case .awaitingUser? = model.statusLine { return "chat.answer.awaitingUser" }
        return "chat.answer.working"
    }
    private var statusAnimated: Bool { model.usesStatusLine ? (model.statusLine?.animated ?? false) : true }

    private var en: Bool { AppLanguage(locale: locale) == .english }
    /// Working / waiting row (visual SPEC). Tap: waiting → scroll to the card; otherwise expand/collapse the steps.
    private func statusRow(_ line: StatusLinePhase) -> some View {
        StatusLineRow(phase: line, en: en, startedAt: model.thinkingStartedAt, onTap: {
            if line.kind == .waiting { scrollToCard?() } else if !model.steps.isEmpty { userExpanded = !expanded }
        }) {
            if line.kind != .waiting && !model.steps.isEmpty { chevron }
        }
        .accessibilityIdentifier(line.kind == .waiting ? "chat.answer.awaitingUser" : "chat.answer.working")
    }
    /// SPEC §8: failed / stopped become static rows in place of the interrupted footer.
    private var terminalStatus: StatusLinePhase? {
        guard case let .interrupted(reason, _) = model.phase else { return nil }
        if model.statusLine == .stopped || reason == "已停止接收此轮回复" || reason == "cancelled" { return .stopped }
        if case .failed? = model.statusLine { return model.statusLine }
        return .failed(reason: StatusLinePhase.failureReason(reason))
    }
    private var reconciliation: Bool { if case let .interrupted(_, r) = model.phase { return r } else { return false } }
    private func terminalRow(_ line: StatusLinePhase) -> some View {
        let n = model.steps.filter { $0.state != .running }.count
        let suffix: String? = line == .stopped && n > 0 ? (en ? " · \(n) steps done" : " · 已完成 \(n) 步") : nil
        return StatusLineRow(phase: line, en: en, startedAt: model.thinkingStartedAt, suffix: suffix,
                             onTap: { if !model.steps.isEmpty { userExpanded = !expanded } }) {
            HStack(spacing: 8) {
                if line.kind == .failed {
                    // Uncertain outcome → only "verify", never resend (R5 rule). Separate VO element (SPEC §11).
                    if reconciliation, let onVerify {
                        Button(ui("核对执行结果"), action: onVerify).font(CatpawTypography.Role.caption.font.weight(.semibold))
                            .foregroundStyle(CatpawColors.ink)
                    } else if let onRegenerate {
                        Button(ui("重试"), action: onRegenerate).font(CatpawTypography.Role.caption.font.weight(.semibold))
                            .foregroundStyle(CatpawColors.ink)
                    }
                }
                if !model.steps.isEmpty { chevron }
            }
        }
        .accessibilityIdentifier("chat.answer.interrupted")
    }
    private var chevron: some View {
        Image(systemName: "chevron.right").font(CatpawTypography.Role.caption.font.weight(.semibold))
            .foregroundStyle(CatpawColors.calmSecondary)
            .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
    }

    /// Running tool step title (e.g. 「正在查日历」) else 「Catpaw 正在工作」.
    private var workingTitle: String {
        if model.usesStatusLine, let line = model.statusLine { return ui(line.title) }
        return model.steps.last(where: { $0.state == .running })?.title ?? ui("Catpaw 正在工作")
    }
    private func liveTitle(now: Date) -> String {
        let secs = String(max(0, Int(now.timeIntervalSince(model.thinkingStartedAt))))
        if let running = model.steps.last(where: { $0.state == .running }) { return running.title + " · " + secs + "s" }
        return ui("思考中 · {0} 秒", [secs])
    }

    /// Stage 4: 「思考结果 ›」 — plain secondary text row, no capsule, chevron rotates when open.
    private var resultRow: some View {
        Button { userExpanded = !expanded } label: {
          HStack(spacing: 8) {
            // Visual SPEC v2 §8: done chip led by the happy kitten, no badge; text stays at x 32.
            if model.usesStatusLine { StatusKitten(pose: .done, badge: nil, tone: .neutral) }
            HStack(spacing: 4) {
                Text(ui("思考结果")).font(CatpawTypography.Role.secondary.font)
                if let s = model.thoughtSeconds, s > 0 {
                    Text("· \(s)s").font(CatpawTypography.Role.secondary.font).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(CatpawTypography.Role.caption.font.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
            }
            .foregroundStyle(CatpawColors.secondary)
          }
          .frame(minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(CatpawPressButtonStyle())
        .accessibilityValue(expanded ? ui("已展开") : ui("已收起"))
        .accessibilityIdentifier("chat.answer.thoughtChip")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Stage 2 step row: glyph + one-line title + duration. Only the running step is ink; finished ones recede.
@MainActor private struct ReplyStepRow: View {
    let step: AnswerToolStep
    let current: Bool
    private var glyph: String {
        if ToolStepCopy.table[step.kind] != nil { return ToolStepCopy.symbol(step.kind) }
        let k = step.kind.lowercased()
        if k.contains("search") { return "magnifyingglass" }
        if k.contains("fetch") || k.contains("browse") || k.contains("web") || k.contains("url") { return "globe" }
        if k.contains("image") || k.contains("vision") { return "photo" }
        return "sparkle"
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: glyph).font(CatpawTypography.Role.caption.font)
                .frame(width: 16).accessibilityHidden(true)
            Text(step.title).font(CatpawTypography.Role.secondary.font.weight(current ? .medium : .regular))
                .lineLimit(1).truncationMode(.tail)
            if let d = duration { Text(d).font(CatpawTypography.Role.caption.font).monospacedDigit().foregroundStyle(CatpawColors.secondary) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(current ? CatpawColors.ink : CatpawColors.secondary)
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
    private var duration: String? {
        guard let start = step.startedAt, let end = step.endedAt else { return nil }
        let s = end.timeIntervalSince(start)
        return s < 10 ? String(format: "%.1fs", s) : "\(Int(s))s"
    }
}

/// Small host capsules under search/browse steps (favicon slot = host initial; no network fetch).
@MainActor struct SourceCapsuleStrip: View {
    let sources: [AnswerSource]
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources) { s in
                    Button { if let u = s.url { openURL(u) } } label: {
                        HStack(spacing: 5) {
                            Text(String((s.host.isEmpty ? s.title : s.host).prefix(1)).uppercased())
                                .font(CatpawTypography.Role.caption.font.weight(.bold))
                                .frame(width: 18, height: 18).background(CatpawColors.separator, in: Circle())
                            Text(s.host.isEmpty ? s.title : s.host).font(CatpawTypography.Role.caption.font).lineLimit(1)
                        }
                        .padding(.horizontal, 8).frame(minHeight: 28)
                        .background(CatpawColors.panel, in: Capsule())
                    }
                    .buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.secondary)
                    .accessibilityLabel(s.title)
                }
            }
            .padding(.leading, 32)
        }
        .accessibilityIdentifier("chat.answer.stepSources")
    }
}

// MARK: B — full-width body, per-batch fade

/// Keeps the repo's 50ms batching contract and TextKit-backed body (`StreamingConversationText`), and adds a
/// 160ms fade on the newest batch only, via a SwiftUI overlay of the tail. No per-token view churn.
/// NOTE (uncertain): the tail overlay assumes the tail sits on the last line fragment; for a first pass we fade the
/// whole text view's opacity 0.85→1 per batch instead, which is cheap and visually close. Swap to a TextKit
/// attribute-alpha animation in `IncrementalConversationTextView.apply` if real-device review asks for it.
@MainActor struct FadingStreamText: View {
    let text: String
    let complete: Bool
    @State private var pulse = 1.0
    /// IOS-NOTE rule 6: a failed/cancelled turn retracts the live `text_preview` tail it never saved. The previous
    /// display stays on top and fades out, so only the unsaved tail disappears (the shared prefix renders identically).
    @State private var retracted: String?
    @State private var retractOpacity = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ZStack(alignment: .topLeading) {
                StreamingConversationText(text: text, complete: complete)
                    .opacity(pulse)
                if let retracted {
                    StreamingConversationText(text: retracted, complete: false)
                        .opacity(retractOpacity).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .onChange(of: text) { old, new in
            // Retraction only: the new text is a strict UTF-16 prefix of the old one (persisted text under a dropped preview).
            guard !reduceMotion, new.utf16.count < old.utf16.count, old.utf16.starts(with: new.utf16) else { return }
            retracted = old; retractOpacity = 1
            withAnimation(.easeOut(duration: 0.35)) { retractOpacity = 0 } completion: { withAnimation(.easeOut(duration: 0.2)) { retracted = nil } }
        }
        .overlay {
            if !complete && !reduceMotion { BubbleShimmerSweep().allowsHitTesting(false) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !complete { StreamShimmerEllipsis(active: !reduceMotion).offset(x: 2, y: 2) }
        }
        .accessibilityAddTraits(complete ? [] : .updatesFrequently)
    }
}


// MARK: C — settled

@MainActor private struct SettledFooter: View {
    let text: String
    let sources: [AnswerSource]
    let canQuote: Bool
    let onQuote: (String) -> Void
    let onRegenerate: (() -> Void)?
    var generationSeconds: Double? = nil
    @State private var sourcesOpen = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sources.isEmpty {
                // 「N 个来源」 summary pill; tap reveals the host capsules.
                Button { sourcesOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: -5) {
                            ForEach(sources.prefix(3)) { s in
                                Text(String((s.host.isEmpty ? s.title : s.host).prefix(1)).uppercased())
                                    .font(CatpawTypography.Role.caption.font.weight(.bold))
                                    .frame(width: 18, height: 18).background(CatpawColors.separator, in: Circle())
                                    .overlay(Circle().strokeBorder(CatpawColors.card, lineWidth: 1))
                            }
                        }.accessibilityHidden(true)
                        Text(ui("{0} 个来源", [String(sources.count)])).font(CatpawTypography.Role.caption.font)
                    }
                    .padding(.horizontal, 10).frame(minHeight: 32)
                    .overlay(Capsule().strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
                }
                .buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.ink)
                .accessibilityValue(sourcesOpen ? ui("已展开") : ui("已收起"))
                .accessibilityIdentifier("chat.answer.sources")
                if sourcesOpen { SourceCapsuleStrip(sources: sources).padding(.leading, -26).transition(.opacity) }
            }
            ReplyActionRow(text: text, id: "phased", canQuote: canQuote, onQuote: onQuote,
                           onRegenerate: onRegenerate, generationSeconds: generationSeconds)
                .modifier(ActionRowEntrance())
        }
        .animation(.easeOut(duration: 0.2), value: sourcesOpen)
    }
}

@MainActor private struct InterruptedFooter: View {
    let reason: String
    let reconciliationRequired: Bool
    let onVerify: (() -> Void)?
    let onRegenerate: (() -> Void)?
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        HStack(spacing: 10) {
            StatusLabel(text: AnswerFailureCopy.friendly(reason), symbol: "exclamationmark.circle", tone: .attention)
            Spacer(minLength: 4)
            // Uncertain outcome → only "verify", never resend (R5 rule).
            if reconciliationRequired, let onVerify {
                Button(ui("核对执行结果"), action: onVerify).font(CatpawTypography.Role.caption.font.weight(.semibold))
            } else if let onRegenerate {
                Button(ui("重试"), action: onRegenerate).font(CatpawTypography.Role.caption.font.weight(.semibold))
            }
        }
        .foregroundStyle(CatpawColors.ink)
        .accessibilityIdentifier("chat.answer.interrupted")
    }
}

/// status-line SPEC §7: tapping the waiting row scrolls to the pending confirmation card.
enum StatusLineCardAnchor { static let id = "chat.status.pendingCard" }
private struct StatusLineScrollToCardKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var statusLineScrollToCard: (() -> Void)? {
        get { self[StatusLineScrollToCardKey.self] } set { self[StatusLineScrollToCardKey.self] = newValue }
    }
}

/// Maps raw provider/back-end failure codes to calm, user-facing copy (never show raw codes).
enum AnswerFailureCopy {
    static func friendly(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("provider_timeout") || r.contains("free_model_unavailable") || r.contains("timed out") || r.contains("timeout") {
            return "模型暂时繁忙，请稍后重试"
        }
        if r.contains("rate_limit") || r.contains("429") { return "请求有点多，稍等片刻再试" }
        if r.contains("_") && !r.contains(" ") && raw.unicodeScalars.allSatisfy({ $0.isASCII }) { return "此轮回复未完成，可以重试" }
        return raw
    }
}


/// r10 §2.6: the action row arrives 120ms after the reply completes, opacity 0→1 and y −4→0 (.easeOut 0.2).
private struct ActionRowEntrance: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : -4)
            .onAppear { withAnimation(.easeOut(duration: 0.2).delay(0.12)) { shown = true } }
    }
}
