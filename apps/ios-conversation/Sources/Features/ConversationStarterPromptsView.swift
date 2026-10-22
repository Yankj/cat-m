import SwiftUI
import UIKit

/// Starter cards under the empty-conversation title. One tap sends the full prompt as the user's message
/// (bubble appears at once through the normal send path). The parent removes the whole empty state as soon as
/// the conversation has a message.
struct ConversationStarterPromptsView: View {
    let enabled: Bool
    let send: (String) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 26   // tracks the title size (Dynamic Type)
    @State private var prompts = ConversationStarterPrompts.ordered()
    @State private var appeared = false
    @State private var tapped = 0   // chat-ux-1505 #2: .sensoryFeedback respects system haptic settings
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }

    private var columns: Int { textSize.isAccessibilitySize ? 1 : 2 }
    private var rows: [[ConversationStarterPrompt]] {
        let width = columns
        return stride(from: 0, to: prompts.count, by: width).map { Array(prompts[$0..<min($0 + width, prompts.count)]) }
    }

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.element.id) { column, prompt in
                        card(prompt, index: rowIndex * columns + column)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ui("试试这些"))
        .accessibilityIdentifier("chat.starters")
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        .onAppear { appeared = true }   // per-card staggered spring below; Reduce Motion shows them at once
    }

    private func card(_ prompt: ConversationStarterPrompt, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            tapped += 1
            send(ui(prompt.prompt))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // v1.1: small 3D soft-clay scene icon before the title (asset catalog "starter-<id>", original
                    // colors, light+dark safe). Decorative: the card's accessibility label already carries the prompt.
                    Image(decorative: "starter-" + prompt.id)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .padding(.vertical, -iconSize * 0.12)   // keep the row at the title's line height (original card height)
                        .accessibilityHidden(true)
                    Text(ui(prompt.title))
                        .font(catTypography.Role.secondary.font.weight(.semibold))
                        .foregroundStyle(catColors.ink)
                        .lineLimit(1)
                }
                Text(ui(prompt.prompt))
                    .font(catTypography.Role.caption.font)
                    .foregroundStyle(catColors.secondary)
                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(catColors.card, in: shape)
            .overlay(shape.strokeBorder(catColors.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(catPressButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(ui(prompt.prompt))
        .accessibilityHint(ui("轻点立即发送"))
        .accessibilityIdentifier("chat.starter." + prompt.id)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86).delay(0.05 * Double(index)), value: appeared)
    }
}
