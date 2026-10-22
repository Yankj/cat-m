import SwiftUI

/// A2 `create_task` (catpaw.task-tools.v1) rendered as a task card, styled like the PR #27 proactive cards.
/// Pending call row: `content` = tool arguments `{title, due_at?, recurrence?, …}`.
/// Result row: `content` = tool result `{ok, created, task:{id,title,due_at,time_zone,status,recurrence,next_fire_at,revision}}`,
/// or `{status:"denied", reason}` / `{status:"error", code}`.
struct CreateTaskCardModel: Equatable {
    enum State: Equatable { case pending, created(existing: Bool), denied(reason: String?), failed }
    var state: State
    var taskID: String?
    var title: String
    var dueAt: Date?
    var status: String?
    var recurrence: String?

    init?(message: ConversationTranscriptMessage) {
        guard message.toolName == "create_task", let raw = try? JSONSerialization.jsonObject(with: Data(message.content.utf8)) as? [String: Any] else { return nil }
        let isResult = message.role == .tool
        let task = raw["task"] as? [String: Any]
        let fields = task ?? raw
        title = (fields["title"] as? String) ?? ""
        dueAt = (fields["due_at"] as? String).flatMap(catProactiveClient.date)
        status = fields["status"] as? String
        recurrence = ((fields["recurrence"] as? [String: Any])?["freq"] as? String)
        taskID = task?["id"] as? String
        if !isResult { state = message.failure == nil ? .pending : .failed }
        else if (raw["status"] as? String) == "denied" || ((raw["result"] as? [String: Any])?["status"] as? String) == "denied" {
            state = .denied(reason: (raw["reason"] as? String) ?? ((raw["result"] as? [String: Any])?["reason"] as? String))
        } else if task != nil, (raw["ok"] as? Bool) != false { state = .created(existing: (raw["created"] as? Bool) == false) }
        else { state = .failed }
    }
}

@MainActor struct CreateTaskCardView: View {
    let message: ConversationTranscriptMessage
    @State private var detail = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }

    var body: some View {
        if let card = CreateTaskCardModel(message: message) { content(card) }
    }

    private func content(_ card: CreateTaskCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: card.dueAt == nil ? "checklist" : "bell.fill").foregroundStyle(catBrand.paw).accessibilityHidden(true)
                Text(card.dueAt == nil ? ui("任务") : ui("提醒")).font(catTypography.Role.caption.font.weight(.semibold)).foregroundStyle(catColors.secondary)
                Spacer()
                Text(stateText(card)).font(catTypography.Role.caption.font).foregroundStyle(stateIsProblem(card) ? catColors.attention : catColors.secondary)
                    .accessibilityIdentifier("chat.taskCard.state")
            }
            if !card.title.isEmpty {
                Text(card.title).font(catTypography.Role.body.font.weight(.semibold)).foregroundStyle(catColors.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.taskCard.title")
            }
            if let due = card.dueAt {
                Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                    .accessibilityIdentifier("chat.taskCard.due")
            }
            if let freq = card.recurrence { Label(recurrenceText(freq), systemImage: "repeat").font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary) }
            if let id = card.taskID, case .created = card.state {
                Button { detail = true } label: { Text(card.dueAt == nil ? ui("查看任务") : ui("查看提醒")).frame(maxWidth: .infinity) }
                    .primaryAction().accessibilityIdentifier("chat.taskCard.open")
                    .sheet(isPresented: $detail) { CreateTaskDetailSheet(taskID: id, fallback: card).presentationDetents([.medium]) }
            }
        }
        .padding(14)
        .background(catColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.taskCard." + (message.toolCallID ?? message.id.uuidString))
    }

    private func stateIsProblem(_ card: CreateTaskCardModel) -> Bool { if case .failed = card.state { return true }; return false }
    private func stateText(_ card: CreateTaskCardModel) -> String {
        switch card.state {
        case .pending: return ui("正在创建…")
        case .created(let existing): return existing ? ui("已存在") : CreateTaskDetailSheet.statusText(card.status, ui)
        case .denied(let reason): return reason == "approval_expired" ? ui("确认超时，未创建") : ui("未创建")
        case .failed: return ui("创建失败")
        }
    }
    private func recurrenceText(_ freq: String) -> String {
        switch freq { case "daily": ui("每天重复"); case "weekly": ui("每周重复"); case "monthly": ui("每月重复"); default: ui("定期重复") }
    }
}

/// "Link to the reminder": live task from `GET /tasks/:id` (catpaw-proactive) with a 完成 action.
@MainActor struct CreateTaskDetailSheet: View {
    let taskID: String
    let fallback: CreateTaskCardModel
    @State private var task: catProactiveTask?
    @State private var loading = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }

    static func statusText(_ status: String?, _ ui: (String, [String]) -> String) -> String {
        switch status { case "done": ui("已完成", []); case "cancelled": ui("已取消", []); case "snoozed": ui("已推迟", []); default: ui("已创建", []) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(task?.title ?? fallback.title).font(catTypography.Role.heading.font).foregroundStyle(catColors.ink)
                if let due = task?.due_at.flatMap(catProactiveClient.date) ?? fallback.dueAt {
                    Label(due.formatted(date: .complete, time: .shortened), systemImage: "clock").foregroundStyle(catColors.ink)
                }
                Label(Self.statusText(task?.status ?? fallback.status, ui), systemImage: "circle.dashed").foregroundStyle(catColors.secondary)
                    .accessibilityIdentifier("chat.taskCard.detail.status")
                if let error { Text(error).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.taskCard.detail.error") }
                Spacer()
                if (task?.status ?? fallback.status) == "open" || (task?.status ?? fallback.status) == "snoozed" {
                    Button { complete() } label: { Text(ui("完成")).frame(maxWidth: .infinity) }
                        .primaryAction().disabled(loading).accessibilityIdentifier("chat.taskCard.detail.done")
                }
            }
            .padding(20)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("好")) { dismiss() } } }
            .accessibilityIdentifier("chat.taskCard.detail")
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { task = try await catProactiveClient.shared.task(taskID); error = nil }
        catch { self.error = ui("暂时无法读取最新状态") }
    }
    private func complete() {
        Task {
            loading = true; defer { loading = false }
            do { task = try await catProactiveClient.shared.update(taskID: taskID, fields: ["status": "done"]); error = nil; catProactiveFeed.shared.refreshSoon() }
            catch { self.error = ui("操作未完成，请稍后重试") }
        }
    }
}
