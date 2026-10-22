import Foundation
import SwiftUI
#if os(iOS)
import UserNotifications
#endif

/// In-app proactive feed: polls `GET /events` (open / foreground / notification tap), keeps events per conversation,
/// The timeline orders events by `created_at` against message `createdAt` (ConversationFirstView.interleave).
/// `anchorRowID` is kept as diagnostic metadata only.
@MainActor final class catProactiveFeed: ObservableObject {
    static let shared = catProactiveFeed()

    struct Entry: Identifiable, Equatable {
        var event: catProactiveEvent
        var anchorRowID: UUID?
        var id: String { event.id }
        var rowID: UUID { stableID("proactive-event-" + event.id) }
    }
    enum ActionState: Equatable { case idle, working, done, snoozed(Date), failed(String) }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var actionStates: [String: ActionState] = [:]
    /// Set by the visible conversation so new events anchor to its current last row.
    var currentAnchor: (@MainActor () -> UUID?)?
    private var refreshing = false
    private let defaults = UserDefaults.standard
    private let cursorKey = "catpaw.proactive.after", anchorsKey = "catpaw.proactive.anchors", askedKey = "catpaw.proactive.notificationsRequested"

    func entries(for conversationID: UUID?) -> [Entry] {
        guard let conversationID else { return [] }
        return entries.values.filter { $0.event.conversationID == conversationID }.sorted { $0.event.createdAt < $1.event.createdAt }
    }

    func refreshSoon() { Task { await refresh() } }

    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        var anchors = (defaults.dictionary(forKey: anchorsKey) as? [String: String]) ?? [:]
        var after = defaults.string(forKey: cursorKey)
        let anchorNow = currentAnchor?()
        for _ in 0..<5 {
            guard let page = try? await catProactiveClient.shared.events(after: after), !page.isEmpty else { break }
            for event in page {
                if anchors[event.id] == nil { anchors[event.id] = anchorNow?.uuidString ?? "" }
                entries[event.id] = Entry(event: event, anchorRowID: anchors[event.id].flatMap(UUID.init(uuidString:)))
                if event.kind == "task_created", event.payload?.task?.due_at != nil || event.payload?.due_at != nil { requestNotificationPermissionOnce() }
            }
            after = page.last?.created_at
            if page.count < 100 { break }
        }
        if let after { defaults.set(after, forKey: cursorKey) }
        defaults.set(anchors, forKey: anchorsKey)
    }

    /// Re-anchors already-loaded events whose anchor is unknown on this device (e.g. after reinstall).
    func ensureAnchors(lastRowID: UUID?) {
        for (id, entry) in entries where entry.anchorRowID == nil { entries[id]?.anchorRowID = lastRowID }
    }

    func complete(_ entry: Entry) { perform(entry, fields: ["status": "done"]) { _ in .done } }
    func snooze(_ entry: Entry, minutes: Int) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        perform(entry, fields: ["snooze_until": catProactiveClient.iso(until)]) { _ in .snoozed(until) }
    }

    private func perform(_ entry: Entry, fields: [String: String], success: @escaping (catProactiveTask) -> ActionState) {
        guard let taskID = entry.event.task_id, actionStates[entry.id] != .working else { return }
        actionStates[entry.id] = .working
        Task {
            do {
                let task = try await catProactiveClient.shared.update(taskID: taskID, fields: fields)
                actionStates[entry.id] = success(task)
                await catProactiveClient.shared.markRead(eventID: entry.event.id)
            } catch catProactiveError.conflict {
                actionStates[entry.id] = .failed(AppLanguage(locale: .current).ui("任务已在别处更新，已刷新。"))
                await refresh()
            } catch {
                actionStates[entry.id] = .failed(AppLanguage(locale: .current).ui("暂时没能更新，请稍后再试。"))
            }
        }
    }

    /// Ask for alert permission only after the first reminder task exists — never at launch.
    func requestNotificationPermissionOnce() {
        #if os(iOS)
        guard !defaults.bool(forKey: askedKey) else { return }
        defaults.set(true, forKey: askedKey)
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        #endif
    }
}
