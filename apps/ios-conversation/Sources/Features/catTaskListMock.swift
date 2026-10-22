import SwiftUI

// V2 demo data (task list) until the backend list/runs endpoints exist.
/// Mock until the proactive edge function exposes a list endpoint.
actor MockcatTaskListSource: catTaskListSource {
    private var rows: [catTaskRow]
    init(now: Date = .now) {
        rows = [
            .init(id: "t1", title: "喝水提醒", dueAt: now.addingTimeInterval(3600), recurrence: "daily", status: .scheduled,
                  runs: [.init(id: "r1", at: now.addingTimeInterval(-86_400), ok: true, summary: "已提醒")]),
            .init(id: "t2", title: "整理本周会议纪要", dueAt: now.addingTimeInterval(7200), recurrence: nil, status: .running, runs: []),
            .init(id: "t3", title: "提交报销单", dueAt: now.addingTimeInterval(-3600), recurrence: nil, status: .done,
                  runs: [.init(id: "r2", at: now.addingTimeInterval(-3600), ok: true, summary: "已完成")]),
            .init(id: "t4", title: "周报草稿", dueAt: now.addingTimeInterval(-7200), recurrence: "weekly", status: .failed,
                  runs: [.init(id: "r3", at: now.addingTimeInterval(-7200), ok: false, summary: "需核对")]),
        ]
    }
    func tasks() async throws -> [catTaskRow] { rows }
    func setPaused(_ paused: Bool, taskID: String) async throws {
        guard let i = rows.firstIndex(where: { $0.id == taskID }) else { return }
        rows[i].status = paused ? .paused : .scheduled
    }
}

#if DEBUG
#Preview("Task confirm") {
    TaskConfirmCardView(draft: .init(title: "明早 8 点提醒我带伞", dueAt: .now.addingTimeInterval(3600), recurrence: nil, note: nil),
                        onConfirm: { _ in }, onCancel: {}).padding()
}
#Preview("Task list") { NavigationStack { catTaskListView() } }
#endif
