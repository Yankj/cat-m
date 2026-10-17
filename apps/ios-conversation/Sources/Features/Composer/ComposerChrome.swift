import SwiftUI
import UIKit
import Combine

/// Send ↔ stop morph. Idle+empty → disabled arrow; responding+empty draft → stop; responding+draft → queue (clock badge).
/// Ownership: Mac worker owns this chrome. feat/reply-chrome only needs the existing stop morph while streaming — leave styling alone.
@MainActor struct ComposerSendButton<Model: ComposerChromeModel>: View {
    @ObservedObject var model: Model
    @State private var sentCount = 0
    @State private var stopCount = 0
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    private enum Mode: Equatable { case send, stop, queue, disabled }
    private var hasContent: Bool { !model.draftIsEmpty || model.attachments.contains(where: \.isSendable) }
    private var uploadsPending: Bool { !model.attachmentsAreReady }
    private var mode: Mode {
        if model.runState == .responding { return hasContent ? .queue : .stop }
        if model.runState == .offlineQueued { return hasContent ? .queue : .disabled }
        if !hasContent || model.isComposingMarkedText || uploadsPending { return .disabled }
        return .send
    }

    var body: some View {
        Button {
            switch mode {
            case .stop: model.stop(); stopCount += 1
            case .send, .queue: model.send(); sentCount += 1
            case .disabled: break
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                    .font(CatpawTypography.Role.body.font.weight(.bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(mode == .disabled ? CatpawColors.sendIcon.opacity(0.9) : CatpawColors.sendIcon)
                    .frame(width: 36, height: 36)
                    .background(mode == .disabled ? CatpawBrand.paw.opacity(0.35) : CatpawBrand.paw, in: Circle())
                if mode == .queue {
                    Image(systemName: "clock.fill").font(CatpawTypography.Role.caption.font.weight(.bold))
                        .foregroundStyle(CatpawBrand.paw).background(CatpawColors.background, in: Circle()).offset(x: 3, y: -3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .touchTarget()
        }
        .buttonStyle(CatpawPressButtonStyle())
        .disabled(mode == .disabled)
        .animation(CatpawMotion.resolved(CatpawMotion.sendMorph, reduceMotion), value: mode)
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
        .accessibilityLabel(mode == .stop ? ui("停止回答") : (mode == .queue ? ui("回答完成后发送") : ui("发送")))
        .accessibilityIdentifier("chat.composer.send")
    }
}

/// "Will send after the current answer" strip above the input.
@MainActor struct ComposerQueuedBanner<Model: ComposerChromeModel>: View {
    @ObservedObject var model: Model
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        if let preview = model.queuedDraftPreview {
            HStack(spacing: 8) {
                Image(systemName: "clock").accessibilityHidden(true)
                Text(ui("回答完成后发送")).fontWeight(.medium)
                Text(preview).lineLimit(1).foregroundStyle(CatpawColors.secondary)
                Spacer(minLength: 4)
                Button(ui("取消"), action: model.cancelQueued).fontWeight(.semibold).foregroundStyle(CatpawColors.ink)
            }
            .font(CatpawTypography.Role.caption.font)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(CatpawColors.panel, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Floating glass container. Liquid Glass on iOS 26, material fallback on 17–25.
struct ComposerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if reduceTransparency {
            content.background(CatpawColors.input, in: shape).overlay(shape.strokeBorder(CatpawColors.controlEdge))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) { content.glassEffect(.regular, in: shape) } else { fallback(content, shape) }
            #else
            fallback(content, shape)
            #endif
        }
    }
    private func fallback(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content.background(CatpawColors.composerPill, in: shape)
            .overlay(shape.strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
            .shadow(color: CatpawColors.ink.opacity(0.06), radius: 8, y: 4)
    }
}

/// Layout: single line → [+][text][send]; ≥2 lines → full-width text on top, tools row beneath (mapping §3).
/// Switches on the editor's reported line count (not ViewThatFits) to avoid jitter during IME composition.
/// `editor` is the existing `NativeConversationComposer`, given `maximumVisibleHeight: ComposerMetrics.maxHeight(...)`.
@MainActor struct FloatingComposer<Model: ComposerChromeModel, Editor: View>: View {
    @ObservedObject var model: Model
    var lineCount: Int
    var uploader: ComposerAttachmentUploading?
    var accessory: AnyView?
    var trailingAccessory: AnyView?
    var metaText: String? = nil
    var metaWarning = false
    var onDetails: (() -> Void)? = nil
    var editor: Editor
    @State private var dropTargeted = false
    @State private var rejection: ComposerAttachmentRejection?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var multiline: Bool { lineCount > 1 || !model.attachments.isEmpty }

    init(model: Model, lineCount: Int, uploader: ComposerAttachmentUploading? = nil,
         accessory: AnyView? = nil, trailingAccessory: AnyView? = nil,
         metaText: String? = nil, metaWarning: Bool = false, onDetails: (() -> Void)? = nil,
         @ViewBuilder editor: () -> Editor) {
        self.metaText = metaText
        self.metaWarning = metaWarning
        self.onDetails = onDetails
        self.model = model
        self.lineCount = lineCount
        self.uploader = uploader
        self.accessory = accessory
        self.trailingAccessory = trailingAccessory
        self.editor = editor()
    }

    var body: some View {
        VStack(spacing: 8) {
            if let rejection { rejectionToast(rejection) }
            // r8 meta line: status lives above the pill, never inside it.
            if let metaText {
                Text(metaText).font(CatpawTypography.Role.caption.font).foregroundStyle(metaWarning ? CatpawColors.attention : CatpawColors.tertiary)
                    .frame(maxWidth: .infinity).accessibilityIdentifier("chat.composer.meta")
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            // r8: one pill. Attachment tray (inside) above the [+][text 1–6 lines][trailing] row.
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
                    ComposerAttachmentStrip(attachments: $model.attachments, onRetry: retry, onRemove: remove)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                HStack(alignment: .bottom, spacing: 2) { addMenu; editor.frame(maxWidth: .infinity); sendControl }
            }
            .padding(6)
            .overlay { ComposerDictationBarHost() }
            .modifier(ComposerGlass())
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(CatpawColors.action, lineWidth: dropTargeted ? 2 : 0))
            .firstRunAnchor(.composer).firstRunHandedOff(.composer)   // SPEC-E: 「开始使用」 morphs into this pill
            .composerDropTarget(isTargeted: $dropTargeted, add: add)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .animation(CatpawMotion.resolved(CatpawMotion.composer, reduceMotion), value: multiline)
        .animation(CatpawMotion.resolved(CatpawMotion.composer, reduceMotion), value: model.attachments.count)
        .animation(.easeOut(duration: 0.2), value: metaText)
    }

    private var addMenu: some View {
        ComposerAddMenu(remaining: ComposerAttachmentLimits.maxPerMessage - model.attachments.count, add: add, onDetails: onDetails)
    }

    @ViewBuilder private var sendControl: some View {
        if let trailingAccessory { trailingAccessory }
        else { ComposerSendButton(model:model) }
    }

    func add(_ items: [ComposerAttachment]) {
        let rej = model.addAttachments(items, using: uploader)
        if let rej { withAnimation { rejection = rej }; Task { try? await Task.sleep(nanoseconds: 2_500_000_000); withAnimation { rejection = nil } } }
    }
    private func retry(_ item: ComposerAttachment) {
        model.retryAttachment(item, using: uploader)
    }
    private func remove(_ item: ComposerAttachment) {
        model.removeAttachment(item, using: uploader)
    }
    private func rejectionToast(_ r: ComposerAttachmentRejection) -> some View {
        let text: String = switch r {
        case .tooMany: ui("每条消息最多 {0} 个附件", [String(ComposerAttachmentLimits.maxPerMessage)])
        case let .tooLarge(name): ui("{0} 超过 20 MB", [name])
        case let .unsupported(name): ui("暂不支持 {0}", [name])
        }
        return StatusLabel(text: text, symbol: "exclamationmark.circle", tone: .attention)
            .padding(.horizontal, 12).frame(minHeight: 32).background(CatpawColors.panel, in: Capsule())
            .transition(.opacity)
    }
}

@MainActor enum ComposerMetrics {
    /// Max visible editor height = 6 lines (r8) of the conversation font + editor insets (8+8). Beyond that the text scrolls.
    static func maxHeight(for dynamicType: DynamicTypeSize) -> CGFloat {
        let font = ConversationTypeScale.font(dynamicType)
        return ceil(font.lineHeight * 6 + CatpawTypography.readingLineSpacing(for: font) * 5 + 14)
    }
}

/// UI-only bridge to the current conversation model. In-progress state comes from
/// the session service's turn-event broadcast, never from broad model busy work.
@MainActor final class ConversationComposerChromeAdapter: ComposerChromeModel {
    @Published var attachments: [ComposerAttachment] = []
    private weak var model: ConversationFirstModel?
    private var modelChanges: AnyCancellable?
    private var eventTask: Task<Void, Never>?
    private var activeOperations: Set<UUID> = []
    private let sendsEnabled: Bool
    private var sendAction: (() -> Void)?

    init(model: ConversationFirstModel, sendsEnabled: Bool = true) {
        self.model = model
        self.sendsEnabled = sendsEnabled
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        eventTask = Task { [weak self, service = model.service] in
            let events = await service.turnEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    deinit { eventTask?.cancel() }

    var draftIsEmpty: Bool { !sendsEnabled || (model?.draft.isEmpty ?? true) }
    var isComposingMarkedText: Bool { model?.isInputComposing ?? false }
    var runState: ComposerRunState {
        let turns = model?.session?.turns ?? []
        // A turn suspended for the user's decision (approval / catpaw.ui.v1) is "waiting for you", not responding:
        // no stop button, send stays enabled.
        let waiting = Set(turns.filter(\.awaitingApproval).map(\.id))
        return activeOperations.subtracting(waiting).isEmpty ? .idle : .responding
    }
    var queuedDraftPreview: String? {
        guard runState == .responding else { return nil }
        return model?.followups.pending.last?.text
    }

    func setSendAction(_ action: @escaping () -> Void) { sendAction=action }
    func send() { guard sendsEnabled else {return};sendAction?() ?? model?.send() }
    /// Operations the user stopped locally. Rows for these keep the partial answer + interrupted footer.
    @Published private(set) var stoppedOperations: Set<UUID> = []
    /// Stop = server cancel (R2): `cancelCurrentTurn` ends the turn as failed{cancelled}; the partial
    /// text stays with the interrupted footer. UI flips immediately; a cancel that raced completion
    /// (`.completed`) un-stops the row so the full answer shows. Double taps (`.busy`) are ignored.
    private var cancelInFlight = false
    func stop() {
        let operationIDs = activeOperations
        guard !operationIDs.isEmpty, !cancelInFlight else { return }
        NotificationCenter.default.post(name: AnswerPhaseProjection.stopNotification, object: nil, userInfo: ["operationIDs": operationIDs])
        stoppedOperations.formUnion(operationIDs)
        activeOperations.subtract(operationIDs)
        objectWillChange.send()
        guard let model, let conversationID = model.conversationID else { return }
        cancelInFlight = true
        let service = model.service, scope = model.scope
        Task { [weak self] in
            defer { self?.cancelInFlight = false }
            do {
                let outcome = try await service.cancelCurrentTurn(scope: scope, conversationID: conversationID)
                if case let .completed(operationID) = outcome { self?.unstop(operationID) }
            } catch is CancellationError {
            } catch ConversationSessionError.busy {
            } catch {
                // Cancel route failed: the local stop stays (partial text + interrupted footer, no error).
            }
        }
    }
    private func unstop(_ operationID: UUID) {
        stoppedOperations.remove(operationID)
        NotificationCenter.default.post(name: AnswerPhaseProjection.resumeNotification, object: nil, userInfo: ["operationID": operationID])
        objectWillChange.send()
    }
    func cancelQueued() {
        guard let pending = model?.followups.pending.last else { return }
        model?.removeFollowup(pending.id)
    }

    private func apply(_ event: ConversationTurnEvent) {
        switch event.payload {
        case .started:
            guard !stoppedOperations.contains(event.operationID) else { return }
            activeOperations.insert(event.operationID)
        case .completed, .failed, .suspended:
            activeOperations.remove(event.operationID)
        default:
            return
        }
        objectWillChange.send()
    }
}

/// "Back to latest" button shown when the reader scrolls up during/after streaming. Host owns `isAwayFromBottom`
/// (e.g. via `onScrollGeometryChange` on iOS 18+ / existing `ConversationReadingAnchor` on 17).
@MainActor struct JumpToLatestButton: View {
    var hasNewContent: Bool
    var action: () -> Void
    @State private var taps = 0
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        // r10 §2.5: 36pt circle on material above the composer; pawOrange 2pt ring while a reply is streaming.
        Button { withAnimation(.smooth(duration: 0.35)) { action() }; taps += 1 } label: {
            Image(systemName: "arrow.down").font(.footnote.weight(.bold))
                .foregroundStyle(CatpawColors.ink)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(CatpawBrand.paw, lineWidth: hasNewContent ? 2 : 0))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(CatpawPressButtonStyle())
        .sensoryFeedback(.selection, trigger: taps)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityLabel(ui("回到最新"))
        .accessibilityIdentifier("chat.jumpToLatest")
    }
}

private struct JumpGlass: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 8, y: 2) }
        #else
        content.background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        #endif
    }
}


/// r8 trailing controls (one view, four modes):
/// empty → mic (dictation) + black waveform (voice) · content → paw-orange send · generating+empty → black stop · generating+draft → send with clock badge (queued).
/// In-progress state comes from turnEvents (adapter.runState), never model.busy.
@MainActor struct ComposerTrailingControls: View {
    let responding: Bool
    let draftEmpty: Bool
    let canSend: Bool
    let size: CGFloat
    let send: () -> Void
    let stop: () -> Void
    var dictate: () -> Void = {}
    var voice: () -> Void = {}
    /// Live dictation: the mic becomes a pulsing paw-orange waveform stop control; send stays available.
    var dictating = false
    /// Replaces the built-in mic/dictating button with one stable view across idle ↔ dictating, so a press-and-hold
    /// gesture that starts on the mic survives the mode change (hold-to-talk).
    var micOverride: AnyView? = nil
    @State private var sendCount = 0
    @State private var stopCount = 0
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private enum Mode: Equatable { case voice, send, stop, queue, dictating }
    private var mode: Mode {
        if dictating { return .dictating }   // the stop-dictation control must stay reachable
        if responding { return draftEmpty ? .stop : .queue }
        return draftEmpty ? .voice : .send
    }
    var body: some View {
        HStack(spacing: 2) {
            if let micOverride, mode == .voice || mode == .dictating { micOverride }
            switch mode {
            case .voice:
                if micOverride == nil { Button(action: dictate) {
                    CircleIcon(systemName: "mic", diameter: size).contentShape(Circle().inset(by: -4))
                }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("听写")).accessibilityIdentifier("chat.composer.mic")
                    .transition(.scale(scale: 0.6).combined(with: .opacity)) }
                Button(action: voice) {
                    Image(systemName: "waveform").font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.sendIcon)
                        .frame(width: size, height: size).background(CatpawColors.ink, in: Circle()).contentShape(Circle().inset(by: -4))
                }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("语音对话")).accessibilityIdentifier("chat.composer.voice")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .dictating:
                if micOverride == nil { Button(action: dictate) {
                    Image(systemName: "waveform").font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.sendIcon)
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        .frame(width: size, height: size).background(CatpawBrand.paw, in: Circle()).contentShape(Circle().inset(by: -4))
                }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("停止听写")).accessibilityIdentifier("chat.composer.dictating")
                    .transition(.scale(scale: 0.6).combined(with: .opacity)) }
                if !draftEmpty {
                    Button { sendCount += 1; send() } label: {
                        Image(systemName: "arrow.up").font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.sendIcon)
                            .frame(width: size, height: size)
                            .background(canSend ? CatpawBrand.paw : CatpawBrand.paw.opacity(0.45), in: Circle()).contentShape(Circle().inset(by: -4))
                    }.buttonStyle(CatpawPressButtonStyle()).disabled(!canSend).accessibilityLabel(ui("发送")).accessibilityIdentifier("chat.send")
                }
            case .stop:
                Button { stopCount += 1; stop() } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CatpawColors.sendIcon).frame(width: 12, height: 12)
                        .frame(width: size, height: size).background(CatpawColors.ink, in: Circle()).contentShape(Circle().inset(by: -4))
                }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("停止回答")).accessibilityIdentifier("chat.stop")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .send, .queue:
                Button { sendCount += 1; send() } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.up").font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.sendIcon)
                            .frame(width: size, height: size)
                            .background(canSend ? CatpawBrand.paw : CatpawBrand.paw.opacity(0.45), in: Circle())
                        if mode == .queue {
                            Image(systemName: "clock.fill").font(CatpawTypography.Role.caption.font.weight(.bold)).imageScale(.small).foregroundStyle(CatpawColors.ink)
                                .padding(2).background(CatpawColors.background, in: Circle()).offset(x: 3, y: -3)
                                .accessibilityIdentifier("chat.composer.queuedBadge")
                        }
                    }.contentShape(Circle().inset(by: -4))
                }.buttonStyle(CatpawPressButtonStyle()).disabled(!canSend)
                    .accessibilityLabel(mode == .queue ? ui("排队发送") : ui("发送")).accessibilityIdentifier("chat.send")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(CatpawMotion.resolved(CatpawMotion.morph, reduceMotion), value: mode)
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
    }
}
