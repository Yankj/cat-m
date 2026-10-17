import SwiftUI

/// In-chat proactive card (reminder / task event) with 完成 and 稍后提醒 actions.
@MainActor struct ProactiveReminderCardView: View {
    let entry: CatpawProactiveFeed.Entry
    @ObservedObject var feed: CatpawProactiveFeed
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var state: CatpawProactiveFeed.ActionState { feed.actionStates[entry.id] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: entry.event.kind == "reminder_due" ? "bell.fill" : "checklist").foregroundStyle(CatpawBrand.paw).accessibilityHidden(true)
                Text(entry.event.kind == "reminder_due" ? ui("提醒") : ui("任务")).font(CatpawTypography.Role.caption.font.weight(.semibold)).foregroundStyle(CatpawColors.secondary)
                Spacer()
                Text(entry.event.createdAt, style: .time).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            }
            Text(entry.event.title).font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.ink)
            if !entry.event.body.isEmpty {
                Text(entry.event.body).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
            }
            if entry.event.offersTaskActions { actions }
        }
        .padding(14)
        .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.proactive." + entry.event.id)
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .done:
            Label(ui("已完成"), systemImage: "checkmark.circle.fill").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.proactive.doneState")
        case .snoozed(let until):
            Label(ui("将在 {0} 再提醒你", [until.formatted(date: .omitted, time: .shortened)]), systemImage: "clock").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.proactive.snoozedState")
        default:
            HStack(spacing: 10) {
                Button { feed.complete(entry) } label: { Text(ui("完成")).frame(maxWidth: .infinity) }
                    .primaryAction().accessibilityIdentifier("chat.proactive.done")
                Menu {
                    Button(ui("10 分钟后")) { feed.snooze(entry, minutes: 10) }
                    Button(ui("1 小时后")) { feed.snooze(entry, minutes: 60) }
                } label: { Text(ui("稍后提醒")).frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityIdentifier("chat.proactive.snooze")
            }
            .disabled(state == .working)
            if case .failed(let message) = state {
                Text(message).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.proactive.error")
            }
        }
    }
}
