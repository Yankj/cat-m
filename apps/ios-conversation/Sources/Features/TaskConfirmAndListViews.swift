import SwiftUI

// V2 (wave2 plan): task confirm card + task list. Demo-grade; data sits behind `catTaskListSource` so the
// backend (`GET /tasks?status=…`, `GET /tasks/:id/runs`, `POST /tasks/:id/confirm`) can replace the mock later.
// Reuses `CreateTaskCardView` (A2 create_task result card); this adds the *pre-creation* confirm step.

struct catTaskDraft: Equatable, Sendable {
    var title: String
    var dueAt: Date?
    var recurrence: String?   // daily | weekly | monthly | nil
    var note: String?
}

struct catTaskRow: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case scheduled, running, done, failed, paused }
    struct Run: Identifiable, Equatable, Sendable { let id: String; let at: Date; let ok: Bool; let summary: String }
    let id: String
    var title: String
    var dueAt: Date?
    var recurrence: String?
    var status: Status
    var runs: [Run]
}

protocol catTaskListSource: Sendable {
    func tasks() async throws -> [catTaskRow]
    func setPaused(_ paused: Bool, taskID: String) async throws
}

// MARK: - Confirm card

@MainActor struct TaskConfirmCardView: View {
    let draft: catTaskDraft
    var onConfirm: (catTaskDraft) -> Void
    var onEdit: () -> Void = {}
    var onCancel: () -> Void
    @State private var decided: Bool? = nil
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: draft.dueAt == nil ? "checklist" : "bell.badge").foregroundStyle(catBrand.paw).accessibilityHidden(true)
                Text(ui("确认创建任务")).font(catTypography.Role.caption.font.weight(.semibold)).foregroundStyle(catColors.secondary)
                Spacer()
            }
            Text(draft.title).font(catTypography.Role.body.font.weight(.semibold)).foregroundStyle(catColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let due = draft.dueAt {
                Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    .font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
            }
            if let freq = draft.recurrence {
                Label(catTaskText.recurrence(freq, ui), systemImage: "repeat").font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
            }
            if let note = draft.note, !note.isEmpty {
                Text(note).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
            }
            if let decided {
                Text(decided ? ui("已确认") : ui("已取消")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
                    .accessibilityIdentifier("task.confirm.result")
            } else {
                HStack(spacing: 10) {
                    Button { decided = false; onCancel() } label: { Text(ui("取消")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(catColors.ink).accessibilityIdentifier("task.confirm.cancel")
                    Button { onEdit() } label: { Text(ui("修改")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(catColors.ink).accessibilityIdentifier("task.confirm.edit")
                    Button { decided = true; onConfirm(draft) } label: { Text(ui("确认")).frame(maxWidth: .infinity) }
                        .primaryAction().accessibilityIdentifier("task.confirm.ok")
                }
            }
        }
        .padding(14)
        .background(catColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.confirm.card")
    }
}

enum catTaskText {
    static func recurrence(_ f: String, _ ui: (String) -> String) -> String {
        switch f { case "daily": ui("每天"); case "weekly": ui("每周"); case "monthly": ui("每月"); default: f }
    }
    static func status(_ s: catTaskRow.Status, _ ui: (String) -> String) -> String {
        switch s { case .scheduled: ui("已安排"); case .running: ui("进行中"); case .done: ui("已完成"); case .failed: ui("需核对"); case .paused: ui("已暂停") }
    }
}

// MARK: - Task list

@MainActor struct catTaskListView: View {
    enum Segment: Hashable { case upcoming, done }
    let source: any catTaskListSource
    @State private var rows: [catTaskRow] = []
    @State private var segment: Segment = .upcoming
    @State private var loadFailed = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    init(source: any catTaskListSource = MockcatTaskListSource()) { self.source = source }

    private var visible: [catTaskRow] {
        rows.filter { segment == .done ? $0.status == .done : $0.status != .done }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    var body: some View {
        List {
            Section {
                Picker(ui("任务"), selection: $segment) {
                    Text(ui("待办")).tag(Segment.upcoming)
                    Text(ui("已完成")).tag(Segment.done)
                }.pickerStyle(.segmented).accessibilityIdentifier("task.list.segment")
            }
            if loadFailed {
                Text(ui("暂时连不上服务，请稍后重试")).font(catTypography.Role.body.font).foregroundStyle(catColors.secondary)
            } else if visible.isEmpty {
                Text(ui("还没有任务")).font(catTypography.Role.body.font).foregroundStyle(catColors.secondary)
            }
            ForEach(visible) { row in
                NavigationLink { catTaskDetailView(row: row, source: source) } label: { catTaskRowView(row: row) }
                    .accessibilityIdentifier("task.list.row." + row.id)
            }
        }
        .navigationTitle(ui("任务"))
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do { rows = try await source.tasks(); loadFailed = false } catch { loadFailed = true }
    }
}

@MainActor struct catTaskRowView: View {
    let row: catTaskRow
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: row.status == .done ? "checkmark.circle.fill" : (row.recurrence == nil ? "circle" : "repeat.circle"))
                .foregroundStyle(row.status == .failed ? catColors.attention : catBrand.paw).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                if let due = row.dueAt {
                    Text(due.formatted(date: .abbreviated, time: .shortened)).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
                }
            }
            Spacer()
            Text(catTaskText.status(row.status, ui)).font(catTypography.Role.caption.font)
                .foregroundStyle(row.status == .failed ? catColors.attention : catColors.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor struct catTaskDetailView: View {
    @State var row: catTaskRow
    let source: any catTaskListSource
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        List {
            Section {
                Text(row.title).font(catTypography.Role.heading.font).foregroundStyle(catColors.ink)
                if let due = row.dueAt { Label(due.formatted(date: .complete, time: .shortened), systemImage: "clock").foregroundStyle(catColors.ink) }
                if let f = row.recurrence { Label(catTaskText.recurrence(f, ui), systemImage: "repeat").foregroundStyle(catColors.ink) }
                if row.status == .scheduled || row.status == .paused {
                    Button {
                        let pause = row.status != .paused
                        row.status = pause ? .paused : .scheduled
                        Task { try? await source.setPaused(pause, taskID: row.id) }
                    } label: { Text(row.status == .paused ? ui("恢复") : ui("暂停")).foregroundStyle(catColors.ink) }
                        .accessibilityIdentifier("task.detail.pause")
                }
            }
            Section(ui("运行历史")) {
                if row.runs.isEmpty { Text(ui("还没有运行记录")).foregroundStyle(catColors.secondary) }
                ForEach(row.runs) { run in
                    HStack {
                        Image(systemName: run.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(run.ok ? catBrand.paw : catColors.attention).accessibilityHidden(true)
                        Text(run.summary).foregroundStyle(catColors.ink)
                        Spacer()
                        Text(run.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(catColors.secondary)
                    }.font(catTypography.Role.caption.font)
                }
            }
        }
        .font(catTypography.Role.body.font)
        .navigationTitle(ui("任务详情"))
    }
}

