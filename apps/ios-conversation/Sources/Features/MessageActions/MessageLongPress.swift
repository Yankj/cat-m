import SwiftUI
import AVFoundation
import Photos
import UIKit

// Message long-press (Grok-style): the message lifts (scale + shadow) over a dimmed, blurred backdrop, an emoji
// reaction bar sits above it and a menu below. Text: 回复 / 复制 / 选择 / 朗读. Image: 回复 / 保存到照片 / 复制图像 / 分享.
// Attached to transcript rows with `.messageLongPress(...)`; the row itself is not restructured.

enum MessageLongPressContent {
    case text(String)
    case image(UIImage)
}

/// Local, per-message reactions (UserDefaults; not synced).
@MainActor final class MessageReactionStore: ObservableObject {
    static let shared = MessageReactionStore()
    static let palette = ["👍", "👎", "❤️", "😂", "🎉", "😮"]
    private let key = "catpaw.messageReactions.v1"
    @Published private(set) var reactions: [String: String]
    init() { reactions = (UserDefaults.standard.dictionary(forKey: "catpaw.messageReactions.v1") as? [String: String]) ?? [:] }
    func reaction(_ id: String) -> String? { reactions[id] }
    func toggle(_ emoji: String, for id: String) {
        reactions[id] = reactions[id] == emoji ? nil : emoji
        UserDefaults.standard.set(reactions, forKey: key)
    }
    func reset() { reactions = [:]; UserDefaults.standard.removeObject(forKey: key) }
}

/// One shared synthesizer so a second 朗读 stops the first.
@MainActor final class MessageSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = MessageSpeaker()
    @Published private(set) var speakingID: String?
    private let synth = AVSpeechSynthesizer()
    override init() { super.init(); synth.delegate = self }
    func toggle(_ text: String, id: String, locale: Locale) {
        if speakingID == id { synth.stopSpeaking(at: .immediate); speakingID = nil; return }
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        let u = AVSpeechUtterance(string: text)
        let zh = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        u.voice = AVSpeechSynthesisVoice(language: zh ? "zh-CN" : (locale.language.languageCode?.identifier == "zh" ? "zh-CN" : "en-US"))
        speakingID = id; synth.speak(u)
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.speakingID = nil } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in self.speakingID = nil } }
}

extension View {
    /// `preview` re-renders the message inside the lifted overlay (pass the same bubble/answer view).
    func messageLongPress<Preview: View>(id: String, content: MessageLongPressContent, alignment: HorizontalAlignment = .leading,
                                        enabled: Bool = true, onReply: ((String) -> Void)? = nil, onEdit: ((String) -> Void)? = nil,
                                        @ViewBuilder preview: @escaping () -> Preview) -> some View {
        // #62: the long-press overlay owns the gesture (it has 选择文本), so inline system selection is off inside the row.
        modifier(MessageLongPressModifier(id: id, content: content, alignment: alignment, enabled: enabled, onReply: onReply, onEdit: onEdit, preview: preview))
            .environment(\.catpawInlineSelection, !enabled)
    }
}

private struct CatpawInlineSelectionKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False inside rows that attach `.messageLongPress`; documents and readers keep system text selection.
    var catpawInlineSelection: Bool { get { self[CatpawInlineSelectionKey.self] } set { self[CatpawInlineSelectionKey.self] = newValue } }
}
private struct CatpawTextSelectionModifier: ViewModifier {
    @Environment(\.catpawInlineSelection) private var selectable
    func body(content: Content) -> some View {
        if selectable { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
extension View { func catpawTextSelection() -> some View { modifier(CatpawTextSelectionModifier()) } }

@MainActor struct MessageLongPressModifier<Preview: View>: ViewModifier {
    let id: String
    let content: MessageLongPressContent
    let alignment: HorizontalAlignment
    let enabled: Bool
    let onReply: ((String) -> Void)?
    var onEdit: ((String) -> Void)? = nil
    let preview: () -> Preview
    @State private var presented = false
    @ObservedObject private var reactions = MessageReactionStore.shared
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content view: Content) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            view
                // Hold feedback: the bubble sinks while the finger rests. The sink waits ~90 ms
                // so a scroll that starts on a bubble never flickers it.
                .scaleEffect(pressing && enabled && !reduceMotion ? CatpawInteractionMotion.messagePressScale : 1,
                             anchor: alignment == .trailing ? .trailing : .leading)
                .animation(pressing ? .easeOut(duration: 0.25).delay(0.09) : CatpawInteractionMotion.pressOut, value: pressing)
                // simultaneous: assistant Markdown keeps .textSelection, which would otherwise swallow the press
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).updating($pressing) { value, state, _ in state = value }.onEnded { _ in
                    guard enabled else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(); setPresented(true)
                })
                .accessibilityAction(named: Text(AppLanguage(locale: .current).ui("更多操作"))) { if enabled { setPresented(true) } }
            if let r = reactions.reaction(id) {
                Button { reactions.toggle(r, for: id) } label: {
                    Text(r).font(CatpawTypography.Role.body.font).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(CatpawColors.panel, in: Capsule()).overlay(Capsule().strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
                }.buttonStyle(.plain).accessibilityLabel(Text(r)).accessibilityIdentifier("chat.message.reaction." + id)
            }
        }
        .fullScreenCover(isPresented: $presented) {
            MessageLongPressOverlay(id: id, content: content, alignment: alignment, onReply: onReply, onEdit: onEdit, preview: preview) { setPresented(false) }
                .presentationBackground(.clear)
        }
    }
    /// The overlay animates itself; the system cover slide is suppressed.
    private func setPresented(_ value: Bool) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { presented = value }
    }
}

@MainActor struct MessageLongPressOverlay<Preview: View>: View {
    let id: String
    let content: MessageLongPressContent
    let alignment: HorizontalAlignment
    let onReply: ((String) -> Void)?
    var onEdit: ((String) -> Void)? = nil
    let preview: () -> Preview
    let close: () -> Void
    @State private var shown = false
    @State private var selecting = false
    @State private var sharing = false
    @State private var toastKey: String?
    @ObservedObject private var reactions = MessageReactionStore.shared
    @ObservedObject private var speaker = MessageSpeaker.shared
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private var frameAlignment: Alignment { alignment == .trailing ? .trailing : .leading }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(CatpawColors.background.opacity(0.45)).ignoresSafeArea()
                .opacity(shown ? 1 : 0).onTapGesture { dismiss() }.accessibilityHidden(true)
            ScrollView {
                VStack(alignment: alignment, spacing: 12) {
                    reactionBar
                    preview()
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                        // Long answers: show the head only (Grok-style), so the menu stays on screen without scrolling.
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.42, alignment: .top).clipped()
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .black.opacity(0.15), location: 1)], startPoint: .top, endPoint: .bottom))
                        .scaleEffect(shown ? 1.03 : 1, anchor: alignment == .trailing ? .trailing : .leading)
                        .shadow(color: .black.opacity(shown ? 0.28 : 0), radius: 18, y: 8)
                    menu
                    if let toastKey { Text(ui(toastKey)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.ink).padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule()) }
                }
                .padding(.horizontal, 16).padding(.vertical, 48)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .frame(minHeight: UIScreen.main.bounds.height - 120)
                .contentShape(Rectangle()).onTapGesture { dismiss() }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.78)) { shown = true } }
        .sheet(isPresented: $selecting) { if case .text(let t) = content { MessageSelectTextSheet(text: t) } }
        .sheet(isPresented: $sharing) { if case .image(let img) = content { MessageShareSheet(items: [img]) } }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
    }

    private var reactionBar: some View {
        HStack(spacing: 4) {
            ForEach(MessageReactionStore.palette, id: \.self) { e in
                Button { reactions.toggle(e, for: id); UISelectionFeedbackGenerator().selectionChanged(); dismiss() } label: {
                    Text(e).font(.title2).frame(minWidth: 44, minHeight: 44)
                        .background(reactions.reaction(id) == e ? CatpawColors.ink.opacity(0.12) : .clear, in: Circle())
                }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(Text(e))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
        .scaleEffect(shown ? 1 : 0.85, anchor: .bottom).opacity(shown ? 1 : 0)
        .accessibilityIdentifier("chat.message.reactionBar")
    }

    private struct Item: Identifiable { let id: String; let titleKey: String; let symbol: String; let run: () -> Void }

    private var items: [Item] {
        switch content {
        case .text(let text):
            return [
                .init(id: "reply", titleKey: "回复", symbol: "arrowshape.turn.up.left") { onReply?(text); dismiss() },
                .init(id: "edit", titleKey: "编辑", symbol: "pencil") { let edit = onEdit; dismiss(); edit?(text) },
                .init(id: "copy", titleKey: "复制", symbol: "doc.on.doc") { UIPasteboard.general.string = text; flash("已复制") },
                .init(id: "select", titleKey: "选择", symbol: "character.cursor.ibeam") { selecting = true },
                .init(id: "speak", titleKey: speaker.speakingID == id ? "停止朗读" : "朗读", symbol: speaker.speakingID == id ? "stop.circle" : "speaker.wave.2") {
                    speaker.toggle(text, id: id, locale: locale); dismiss() },
            ].filter { ($0.id != "reply" || onReply != nil) && ($0.id != "edit" || onEdit != nil) }
        case .image(let image):
            return [
                .init(id: "reply", titleKey: "回复", symbol: "arrowshape.turn.up.left") { onReply?(""); dismiss() },
                .init(id: "save", titleKey: "保存到照片", symbol: "square.and.arrow.down") { save(image) },
                .init(id: "copyImage", titleKey: "复制图像", symbol: "doc.on.doc") { UIPasteboard.general.image = image; flash("已复制") },
                .init(id: "share", titleKey: "分享", symbol: "square.and.arrow.up") { sharing = true },
            ].filter { $0.id != "reply" || onReply != nil }
        }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button(action: item.run) {
                    Label { Text(ui(item.titleKey)).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink) } icon: {
                        Image(systemName: item.symbol).foregroundStyle(CatpawColors.ink)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 18).contentShape(Rectangle())
                }
                .buttonStyle(CatpawPressButtonStyle()).accessibilityIdentifier("chat.message.menu." + item.id)
                if item.id != items.last?.id { Divider().padding(.leading, 52) }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
        .scaleEffect(shown ? 1 : 0.9, anchor: .top).opacity(shown ? 1 : 0)
        .accessibilityIdentifier("chat.message.menu")
    }

    private func flash(_ key: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        toastKey = key
        Task { try? await Task.sleep(for: .milliseconds(700)); dismiss() }
    }
    /// Needs NSPhotoLibraryAddUsageDescription in Info.plist (add-only access).
    private func save(_ image: UIImage) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { toastKey = "没有照片权限，请在设置中允许"; return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil); flash("已保存到照片")
        }
    }
    private func dismiss() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { shown = false }
        Task { try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 180)); close() }
    }
}

@MainActor struct MessageSelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    var body: some View {
        NavigationStack {
            ScrollView { Text(text).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                .navigationTitle(AppLanguage(locale: locale).ui("选择文本")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLanguage(locale: locale).ui("完成")) { dismiss() } } }
        }
        .accessibilityIdentifier("chat.message.selectSheet")
    }
}

struct MessageShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// chat-ux #1: edit your own prompt and resend; the old answer stays as a switchable version (ReplyVariantStore).
@MainActor struct MessageEditSheet: View {
    let original: String
    let send: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    init(original: String, send: @escaping (String) -> Void) { self.original = original; self.send = send; _text = State(initialValue: original) }
    static func canSend(_ text: String, original: String) -> Bool { MessageEditRules.canSend(text, original: original) }
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).focused($focused).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                .padding(12).accessibilityLabel(ui("编辑消息")).accessibilityIdentifier("chat.edit.field")
                .navigationTitle(ui("编辑消息")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() }.accessibilityIdentifier("chat.edit.cancel") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(ui("发送")) { let t = MessageEditRules.normalized(text); dismiss(); send(t) }
                            .disabled(!Self.canSend(text, original: original)).accessibilityIdentifier("chat.edit.send")
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
