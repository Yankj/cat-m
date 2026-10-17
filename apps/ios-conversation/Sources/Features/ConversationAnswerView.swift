import SwiftUI
import UIKit

/// Message actions operate on the currently visible text, including a partial reply.
/// Quoting changes a draft only; the normal explicit Send still owns admission.
/// Layout (grok-reply refs, structure only): no bubble — body sits on the background; optional
/// 「思考结果 ›」 above; action row + generation time + follow-ups below, last reply only (#60).
@MainActor struct ConversationAnswerView: View {
    let message: ConversationTranscriptMessage
    var canQuote = true
    let quote: (String) -> Void
    /// Action row renders only under the last assistant reply (host decides); `actions` adds regenerate + ‹ n/m ›.
    var showsActions = true
    var actions: ReplyActionControl? = nil
    /// Persisted thought (turn.reasoningSummary / thinkingMs). Nil → no 「思考结果」 row.
    var thoughtSummary: String? = nil
    var thoughtSeconds: Int? = nil
    /// Hook: trailing generation time; nil hides it (persisted turns don't record it yet).
    var generationSeconds: Double? = nil
    /// Hook: follow-up suggestions; empty hides the list. `onFollowUp` should fill the draft, never auto-send.
    var followUps: [String] = []
    var onFollowUp: ((String) -> Void)? = nil
    @State private var thoughtOpen = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thoughtSummary, !thoughtSummary.isEmpty {
                Button { thoughtOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(ui("思考结果"))
                        if let thoughtSeconds, thoughtSeconds > 0 { Text("· \(thoughtSeconds)s").monospacedDigit() }
                        Image(systemName: "chevron.right").font(CatpawTypography.Role.caption.font.weight(.semibold))
                            .rotationEffect(.degrees(thoughtOpen ? 90 : 0)).accessibilityHidden(true)
                    }
                    .font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                    .frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(CatpawPressButtonStyle())
                .accessibilityValue(thoughtOpen ? ui("已展开") : ui("已收起"))
                .accessibilityIdentifier("chat.answer.thoughtChip")
                if thoughtOpen {
                    Text(thoughtSummary).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                        .fixedSize(horizontal: false, vertical: true).transition(.opacity)
                }
            }
            StreamingConversationText(text: message.content, complete: message.complete)
            if showsActions, !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReplyActionRow(text: message.content, id: message.id.uuidString, canQuote: canQuote, onQuote: quote,
                               control: actions, generationSeconds: generationSeconds)
                if !followUps.isEmpty, let onFollowUp { FollowUpList(items: followUps, onSelect: onFollowUp) }
            }
        }
        .animation(CatpawMotion.resolved(CatpawMotion.thinkingCollapse, reduceMotion), value: thoughtOpen)
    }
}

/// Shared reply action row (persisted + phased): copy · share · 👍 · 👎 · read aloud · retry · … , trailing pager or time.
/// Glyphs are bare (no circles) in secondary ink — quieter than the body, never brand orange.
@MainActor struct ReplyActionRow: View {
    let text: String
    let id: String
    var canQuote = true
    var onQuote: (String) -> Void
    var control: ReplyActionControl? = nil
    var onRegenerate: (() -> Void)? = nil
    var generationSeconds: Double? = nil
    /// Hook: rating sink (no backend yet; local state only when nil).
    var onFeedback: ((Bool?) -> Void)? = nil
    @State private var rating: Bool?
    @State private var copied = 0
    @ObservedObject private var speaker = MessageSpeaker.shared
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var regenerate: (() -> Void)? { control?.onRegenerate ?? onRegenerate }
    private var speaking: Bool { speaker.speakingID == "reply." + id }

    var body: some View {
        HStack(spacing: 6) {
            Button { UIPasteboard.general.string = text; copied += 1 } label: {
                Image(systemName: copied > 0 ? "checkmark" : "doc.on.doc").replyActionGlyph()
            }
            .accessibilityLabel(ui("复制回复")).sensoryFeedback(.success, trigger: copied)
            .accessibilityIdentifier("chat.answer.copy." + id)
            ShareLink(item: text) { Image(systemName: "square.and.arrow.up").replyActionGlyph() }
                .accessibilityLabel(ui("分享回复"))
                .accessibilityIdentifier("chat.answer.share." + id)
            Button { rate(true) } label: { Image(systemName: rating == true ? "hand.thumbsup.fill" : "hand.thumbsup").replyActionGlyph() }
                .accessibilityLabel(ui("有帮助")).accessibilityAddTraits(rating == true ? .isSelected : [])
                .accessibilityIdentifier("chat.answer.like." + id)
            Button { rate(false) } label: { Image(systemName: rating == false ? "hand.thumbsdown.fill" : "hand.thumbsdown").replyActionGlyph() }
                .accessibilityLabel(ui("没帮助")).accessibilityAddTraits(rating == false ? .isSelected : [])
                .accessibilityIdentifier("chat.answer.dislike." + id)
            Button { speaker.toggle(text, id: "reply." + id, locale: locale) } label: {
                Image(systemName: speaking ? "speaker.wave.2.fill" : "speaker.wave.2").replyActionGlyph()
            }
            .accessibilityLabel(speaking ? ui("停止朗读") : ui("朗读"))
            .accessibilityIdentifier("chat.answer.speak." + id)
            if let regenerate {
                Button(action: regenerate) { Image(systemName: "arrow.clockwise").replyActionGlyph() }
                    .accessibilityLabel(ui("重新生成")).disabled(!(control?.canRegenerate ?? true))
                    .accessibilityIdentifier("chat.answer.regenerate." + id)
            }
            Menu {
                Button { onQuote(text) } label: { Label(ui("引用到草稿"), systemImage: "quote.bubble") }
                    .disabled(!canQuote)
                    .accessibilityHint(ui("保留现有草稿，不自动发送"))
                    .accessibilityIdentifier("chat.answer.quote." + id)
            } label: { Image(systemName: "ellipsis").replyActionGlyph() }
                .accessibilityLabel(ui("更多操作"))
                .accessibilityIdentifier("chat.answer.more." + id)
            Spacer(minLength: 0)
            if let control, control.count > 1 { ReplyVariantPager(control: control) }
            else if let generationSeconds {
                Text(String(format: "%.2fs", generationSeconds))
                    .font(CatpawTypography.Role.caption.font).monospacedDigit().foregroundStyle(CatpawColors.secondary)
                    .accessibilityIdentifier("chat.answer.duration")
            }
        }
        .buttonStyle(CatpawPressButtonStyle())
        .sensoryFeedback(.selection, trigger: rating)
    }

    private func rate(_ up: Bool) {
        rating = rating == up ? nil : up
        onFeedback?(rating)
    }
}

/// Follow-up suggestions under the last reply: ↳ + one line each, hairline separated. Tapping fills the draft.
@MainActor struct FollowUpList: View {
    let items: [String]
    let onSelect: (String) -> Void
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider().overlay(CatpawColors.hairline) }
                Button { onSelect(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.down.right").font(CatpawTypography.Role.caption.font)
                            .foregroundStyle(CatpawColors.secondary).accessibilityHidden(true)
                        Text(item).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(CatpawPressButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLanguage(locale: locale).ui("追问建议"))
        .accessibilityIdentifier("chat.answer.followUps")
    }
}

extension View {
    /// Bare action glyph: 32pt hit box, secondary ink, no circle (quieter than `answerActionIcon`).
    func replyActionGlyph() -> some View {
        self.font(CatpawTypography.Role.secondary.font).imageScale(.medium).foregroundStyle(CatpawColors.secondary)
            .frame(width: 32, height: 32).contentShape(Rectangle().inset(by: -4))
    }
}
