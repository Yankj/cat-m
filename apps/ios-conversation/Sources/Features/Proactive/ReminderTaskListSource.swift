import EventKit
import Foundation

/// Real `catTaskListSource` for the demo: the reminders cat itself wrote (url `catpawm://op/…`).
/// "Pause" maps to completing / reopening the reminder, which is the only state Reminders has.
actor ReminderTaskListSource: catTaskListSource {
    private let store = EKEventStore()
    func tasks() async throws -> [catTaskRow] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw CocoaError(.featureUnsupported) }
        let reminders: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { c.resume(returning: $0 ?? []) }
        }
        return reminders.filter { $0.url?.scheme == "catpawm" }.map { r in
            catTaskRow(id: r.calendarItemIdentifier, title: r.title ?? "", dueAt: r.dueDateComponents?.date ?? r.alarms?.first?.absoluteDate,
                          recurrence: nil, status: r.isCompleted ? .done : .scheduled,
                          runs: r.completionDate.map { [.init(id: "done", at: $0, ok: true, summary: "已完成")] } ?? [])
        }
    }
    func setPaused(_ paused: Bool, taskID: String) async throws {
        guard let r = store.calendarItem(withIdentifier: taskID) as? EKReminder else { throw CocoaError(.fileNoSuchFile) }
        r.isCompleted = paused
        try store.save(r, commit: true)
    }
}
