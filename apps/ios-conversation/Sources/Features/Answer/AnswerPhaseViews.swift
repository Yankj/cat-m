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
            ThinkingHeader(model: model)
            if model.phase != .thinking {
                FadingStreamText(text: model.text, complete: model.phase == .settled)
                    .transition(.opacity)
            }
            switch model.phase {
            case .settled:
                SettledFooter(text: model.text, sources: model.sources, canQuote: canQuote, onQuote: onQuote, onRegenerate: onRegenerate)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case let .interrupted(reason, reconciliation):
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

// MARK: A/B — thinking row ↔ "thought for Xs · N steps" chip

@MainActor private struct ThinkingHeader<Model: AnswerPhaseProviding>: View {
    @ObservedObject var model: Model
    @State private var expanded = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var thinking: Bool { model.phase == .thinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if thinking { liveRow } else { chip }
            if thinking || expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(thinking ? Array(model.steps.suffix(3)) : model.steps) { ToolStepRow(step: $0) }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(CatpawMotion.resolved(CatpawMotion.thinkingCollapse, reduceMotion), value: expanded)
        .accessibilityIdentifier("chat.answer.thinking")
    }

    private var liveRow: some View {
        HStack(spacing: 8) {
            BreathingPaw(active: true)
            ShimmerText(text: ui("思考中"), active: !reduceMotion)
                .font(CatpawTypography.Role.secondary.font.weight(.semibold))
            Text(model.thinkingSummary ?? model.steps.last?.title ?? "")
                .font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                .lineLimit(1).contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: model.thinkingSummary)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: model.thinkingStartedAt, by: 1)) { ctx in
                Text(Self.elapsed(from: model.thinkingStartedAt, to: ctx.date))
                    .font(CatpawTypography.Role.caption.font).monospacedDigit().foregroundStyle(CatpawColors.secondary)
            }
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ui("思考中") + " " + (model.thinkingSummary ?? ""))
    }

    private var chip: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                PawShape().fill(CatpawBrand.paw).frame(width: 12, height: 12).accessibilityHidden(true)
                Text(chipTitle).font(CatpawTypography.Role.caption.font.weight(.medium))
                if !model.steps.isEmpty {
                    Image(systemName: "chevron.right").font(CatpawTypography.Role.caption.font.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(CatpawColors.secondary)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(CatpawColors.panel, in: Capsule())
            .touchTarget()
        }
        .buttonStyle(CatpawPressButtonStyle())
        .disabled(model.steps.isEmpty)
        .accessibilityValue(expanded ? ui("已展开") : ui("已收起"))
        .accessibilityIdentifier("chat.answer.thoughtChip")
    }

    private var chipTitle: String {
        let seconds = String(model.thoughtSeconds ?? 0)
        return model.steps.isEmpty ? ui("思考了 {0} 秒", [seconds]) : ui("思考了 {0} 秒 · {1} 个步骤", [seconds, String(model.steps.count)])
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor private struct ToolStepRow: View {
    let step: AnswerToolStep
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if step.state == .running { ProgressView().controlSize(.mini) }
                else { Image(systemName: "checkmark").font(CatpawTypography.Role.caption.font.weight(.bold)).foregroundStyle(CatpawColors.success) }
            }.frame(width: 14)
            Text(step.title).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).lineLimit(1)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

/// Gradient sweep across the "思考中" label. Reduce Motion → plain text.
private struct ShimmerText: View {
    let text: String
    let active: Bool
    var body: some View {
        if active {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Text(text).foregroundStyle(CatpawColors.secondary)
                    .overlay {
                        LinearGradient(stops: [.init(color: .clear, location: t - 0.25), .init(color: CatpawColors.ink, location: t), .init(color: .clear, location: t + 0.25)],
                                       startPoint: .leading, endPoint: .trailing)
                            .mask(Text(text))
                    }
            }
        } else {
            Text(text).foregroundStyle(CatpawColors.ink)
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            StreamingConversationText(text: text, complete: complete)
                .opacity(pulse)
        }
        .overlay(alignment: .bottomTrailing) {
            if !complete { StreamCursor().offset(x: 0, y: -4) }
        }
        .onChange(of: text) { _, _ in
            guard !complete, !reduceMotion else { return }
            pulse = 0.85
            withAnimation(CatpawMotion.batchFade) { pulse = 1 }
        }
    }
}

private struct StreamCursor: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(CatpawBrand.paw).frame(width: 7, height: 7)
            .opacity(reduceMotion ? 0.8 : (on ? 1 : 0.3))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.55).repeatForever(), value: on)
            .onAppear { on = true }.accessibilityHidden(true)
    }
}

// MARK: C — settled

@MainActor private struct SettledFooter: View {
    let text: String
    let sources: [AnswerSource]
    let canQuote: Bool
    let onQuote: (String) -> Void
    let onRegenerate: (() -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var copied = 0
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { i, s in
                            Button { if let u = s.url { openURL(u) } } label: {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(CatpawTypography.Role.caption.font.weight(.bold)).monospacedDigit()
                                        .frame(width: 18, height: 18).background(CatpawColors.separator, in: Circle())
                                    Text(s.host.isEmpty ? s.title : s.host).font(CatpawTypography.Role.caption.font).lineLimit(1)
                                }
                                .padding(.horizontal, 10).frame(minHeight: 32)
                                .background(CatpawColors.panel, in: Capsule())
                            }
                            .buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.ink)
                            .accessibilityLabel(s.title)
                        }
                    }
                }
                .accessibilityIdentifier("chat.answer.sources")
            }
            HStack(spacing: 4) {
                Button { UIPasteboard.general.string = text; copied += 1 } label: { Image(systemName: "doc.on.doc").touchTarget() }
                    .accessibilityLabel(ui("复制回复")).sensoryFeedback(.success, trigger: copied)
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up").touchTarget() }
                    .accessibilityLabel(ui("分享回复"))
                Button { onQuote(text) } label: { Image(systemName: "quote.bubble").touchTarget() }
                    .accessibilityLabel(ui("引用到草稿")).disabled(!canQuote)
                if let onRegenerate {
                    Button(action: onRegenerate) { Image(systemName: "arrow.clockwise").touchTarget() }
                        .accessibilityLabel(ui("重新生成"))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(CatpawColors.secondary).buttonStyle(CatpawPressButtonStyle())
        }
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
            StatusLabel(text: reason, symbol: "exclamationmark.circle", tone: .attention)
            Spacer(minLength: 4)
            // Uncertain outcome → only "verify", never resend (R5 rule).
            if reconciliationRequired, let onVerify {
                Button(ui("核对执行结果"), action: onVerify).font(CatpawTypography.Role.caption.font.weight(.semibold))
            } else if let onRegenerate {
                Button(ui("重试"), action: onRegenerate).font(CatpawTypography.Role.caption.font.weight(.semibold))
            }
        }
        .foregroundStyle(CatpawColors.action)
        .accessibilityIdentifier("chat.answer.interrupted")
    }
}
