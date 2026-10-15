import Foundation
import Observation
import SwiftUI

/// Regenerate pager (‹ 1/2 ›). The backend has no variant API yet, so variants are kept client-side:
/// a regenerate re-sends the original prompt as a new turn, and that turn is recorded as a variant of the
/// original. The timeline shows the original user prompt once and only the selected variant's reply rows.
/// Persisted per conversation in UserDefaults (`catpaw.replyVariants.v1.<conversationID>`).
/// API needed for server-side variants: `POST /conversations/{c}/turns/{t}/regenerate` returning a variant id,
/// plus `variants[]` on the turn so other devices see the same pager.
@MainActor @Observable final class ReplyVariantStore {
    struct Group: Codable, Equatable { var turns: [UUID]; var selected: Int }
    private(set) var groups: [UUID: Group] = [:]      // key = original turn ID
    private var owner: [UUID: UUID] = [:]              // any variant turn → original
    private var conversationID: UUID?

    func activate(_ id: UUID?) {
        guard id != conversationID else { return }
        conversationID = id; groups = [:]; owner = [:]
        guard let id, let data = UserDefaults.standard.data(forKey: key(id)),
              let saved = try? JSONDecoder().decode([UUID: Group].self, from: data) else { return }
        groups = saved; reindex()
    }

    func original(of turn: UUID) -> UUID { owner[turn] ?? turn }
    func group(for turn: UUID) -> Group? { groups[original(of: turn)] }

    func addVariant(original turn: UUID, newTurn: UUID) {
        let root = original(of: turn)
        var g = groups[root] ?? Group(turns: [root], selected: 0)
        guard !g.turns.contains(newTurn) else { return }
        g.turns.append(newTurn); g.selected = g.turns.count - 1
        groups[root] = g; reindex(); save()
    }

    func step(_ turn: UUID, by delta: Int) {
        let root = original(of: turn)
        guard var g = groups[root] else { return }
        g.selected = min(max(0, g.selected + delta), g.turns.count - 1)
        groups[root] = g; save()
    }

    /// Prompt rows of regenerated turns are hidden; reply rows show only for the selected variant.
    func isVisible(turnID: UUID?, isUserPrompt: Bool) -> Bool {
        guard let turnID, let root = owner[turnID], let g = groups[root] else { return true }
        if isUserPrompt { return turnID == root }
        return g.turns[g.selected] == turnID
    }

    private func reindex() { owner = [:]; for (root, g) in groups { for t in g.turns { owner[t] = root } } }
    private func key(_ id: UUID) -> String { "catpaw.replyVariants.v1." + id.uuidString }
    private func save() {
        guard let conversationID, let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key(conversationID))
    }
}

/// Inputs for the action row under the last assistant reply.
struct ReplyActionControl {
    var index: Int          // 0-based selected variant
    var count: Int
    var canRegenerate: Bool
    var onRegenerate: () -> Void
    var onStep: (Int) -> Void
}

/// ‹ 1/2 › pager, trailing in the action row (Grok-style).
@MainActor struct ReplyVariantPager: View {
    let control: ReplyActionControl
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    var body: some View {
        HStack(spacing: 2) {
            Button { control.onStep(-1) } label: { Image(systemName: "chevron.left").answerActionIcon() }
                .disabled(control.index == 0).accessibilityLabel(ui("上一个回答")).accessibilityIdentifier("chat.answer.variant.prev")
            Text(verbatim: "\(control.index + 1)/\(control.count)")
                .font(CatpawTypography.Role.secondary.font.monospacedDigit()).foregroundStyle(CatpawColors.ink)
                .accessibilityLabel(ui("第 {0} 个回答，共 {1} 个", [String(control.index + 1), String(control.count)]))
                .accessibilityIdentifier("chat.answer.variant.position")
            Button { control.onStep(1) } label: { Image(systemName: "chevron.right").answerActionIcon() }
                .disabled(control.index >= control.count - 1).accessibilityLabel(ui("下一个回答")).accessibilityIdentifier("chat.answer.variant.next")
        }
    }
}
