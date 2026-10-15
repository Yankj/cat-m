import SwiftUI
import UIKit
import Combine

/// Send ↔ stop morph. Idle+empty → disabled arrow; responding+empty draft → stop; responding+draft → queue (clock badge).
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
                    .foregroundStyle(mode == .disabled ? CatpawColors.secondary : CatpawColors.sendIcon)
                    .frame(width: 36, height: 36)
                    .background(mode == .disabled ? CatpawColors.separator : CatpawBrand.paw, in: Circle())
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
                Button(ui("取消"), action: model.cancelQueued).fontWeight(.semibold).foregroundStyle(CatpawColors.action)
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
        content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(CatpawColors.controlEdge.opacity(0.6)))
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
    var editor: Editor
    @State private var dropTargeted = false
    @State private var rejection: ComposerAttachmentRejection?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var multiline: Bool { lineCount > 1 || !model.attachments.isEmpty }

    init(model: Model, lineCount: Int, uploader: ComposerAttachmentUploading? = nil,
         accessory: AnyView? = nil, trailingAccessory: AnyView? = nil,
         @ViewBuilder editor: () -> Editor) {
        self.model = model
        self.lineCount = lineCount
        self.uploader = uploader
        self.accessory = accessory
        self.trailingAccessory = trailingAccessory
        self.editor = editor()
    }

    var body: some View {
        VStack(spacing: 8) {
            ComposerQueuedBanner(model: model)
            if let rejection { rejectionToast(rejection) }
            VStack(alignment: .leading, spacing: 6) {
                ComposerAttachmentStrip(attachments: $model.attachments, onRetry: retry, onRemove: remove)
                if multiline {
                    editor.frame(maxWidth: .infinity)
                    HStack { addMenu; accessory; Spacer(); sendControl }
                } else {
                    HStack(alignment: .bottom, spacing: 4) { addMenu; accessory; editor.frame(maxWidth: .infinity); sendControl }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .modifier(ComposerGlass())
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(CatpawColors.action, lineWidth: dropTargeted ? 2 : 0))
            .composerDropTarget(isTargeted: $dropTargeted, add: add)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .animation(CatpawMotion.resolved(CatpawMotion.sendMorph, reduceMotion), value: multiline)
        .animation(CatpawMotion.resolved(CatpawMotion.statusCapsule, reduceMotion), value: model.queuedDraftPreview)
    }

    private var addMenu: some View {
        ComposerAddMenu(remaining: ComposerAttachmentLimits.maxPerMessage - model.attachments.count, add: add)
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
    /// Max visible editor height = 5 lines of the conversation font + editor insets (8+8). Beyond that the text scrolls.
    static func maxHeight(for dynamicType: DynamicTypeSize) -> CGFloat {
        let font = ConversationTypeScale.font(dynamicType)
        return ceil(font.lineHeight * 5 + CatpawTypography.readingLineSpacing(for: font) * 4 + 16)
    }
}

/// UI-only bridge to the current conversation model. The current model can queue
/// another draft while a turn is active, but it does not expose a user-facing
/// cancellation API for an admitted turn; `.offlineQueued` keeps the chrome in
/// queue-only mode and therefore never presents a misleading stop control.
@MainActor final class ConversationComposerChromeAdapter: ComposerChromeModel {
    @Published var attachments: [ComposerAttachment] = []
    private weak var model: ConversationFirstModel?
    private var modelChanges: AnyCancellable?
    private let sendsEnabled: Bool
    private var sendAction: (() -> Void)?

    init(model: ConversationFirstModel, sendsEnabled: Bool = true) {
        self.model = model
        self.sendsEnabled = sendsEnabled
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var draftIsEmpty: Bool { !sendsEnabled || (model?.draft.isEmpty ?? true) }
    var isComposingMarkedText: Bool { model?.isInputComposing ?? false }
    var runState: ComposerRunState { model?.sending == true ? .offlineQueued : .idle }
    var queuedDraftPreview: String? {
        guard model?.sending == true else { return nil }
        return model?.followups.pending.last?.text
    }

    func setSendAction(_ action: @escaping () -> Void) { sendAction=action }
    func send() { guard sendsEnabled else {return};sendAction?() ?? model?.send() }
    func stop() { }
    func cancelQueued() {
        guard let pending = model?.followups.pending.last else { return }
        model?.removeFollowup(pending.id)
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
        Button { action(); taps += 1 } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.footnote.weight(.bold))
                if hasNewContent { Text(ui("新内容")).font(CatpawTypography.Role.caption.font.weight(.semibold)) }
            }
            .foregroundStyle(CatpawColors.ink)
            .padding(.horizontal, hasNewContent ? 14 : 0)
            .frame(minWidth: 40, minHeight: 40)
            .modifier(JumpGlass())
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
