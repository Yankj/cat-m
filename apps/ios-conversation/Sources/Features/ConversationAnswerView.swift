import SwiftUI
import UIKit

/// Message actions operate on the currently visible text, including a partial reply.
/// Quoting changes a draft only; the normal explicit Send still owns admission.
@MainActor struct ConversationAnswerView: View {
    let message: ConversationTranscriptMessage
    var canQuote = true
    let quote: (String) -> Void
    /// Action row renders only under the last assistant reply (host decides); `actions` adds regenerate + ‹ n/m ›.
    var showsActions = true
    var actions: ReplyActionControl? = nil
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StreamingConversationText(text: message.content, complete: message.complete)
            if showsActions, !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 14) {
                    Button { UIPasteboard.general.string = message.content } label: {
                        Image(systemName: "doc.on.doc").answerActionIcon()
                    }.accessibilityLabel(ui("复制回复"))
                        .accessibilityIdentifier("chat.answer.copy." + message.id.uuidString)
                    ShareLink(item: message.content) {
                        Image(systemName: "square.and.arrow.up").answerActionIcon()
                    }.accessibilityLabel(ui("分享回复"))
                        .accessibilityIdentifier("chat.answer.share." + message.id.uuidString)
                    Button { quote(message.content) } label: {
                        Image(systemName: "quote.bubble").answerActionIcon()
                    }.accessibilityLabel(ui("引用到草稿"))
                        .accessibilityHint(ui("保留现有草稿，不自动发送"))
                        .disabled(!canQuote)
                        .accessibilityIdentifier("chat.answer.quote." + message.id.uuidString)
                    if let actions {
                        Button(action: actions.onRegenerate) { Image(systemName: "arrow.clockwise").answerActionIcon() }
                            .accessibilityLabel(ui("重新生成")).disabled(!actions.canRegenerate)
                            .accessibilityIdentifier("chat.answer.regenerate." + message.id.uuidString)
                    }
                    Spacer(minLength: 0)
                    if let actions, actions.count > 1 { ReplyVariantPager(control: actions) }
                }.foregroundStyle(CatpawColors.secondary).buttonStyle(CatpawPressButtonStyle())
            }
        }
    }
}
