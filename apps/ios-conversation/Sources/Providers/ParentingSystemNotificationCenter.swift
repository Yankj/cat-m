import Foundation
#if canImport(UserNotifications)
import UserNotifications

/// Production adapter over `UNUserNotificationCenter`. It only ever lists or removes requests whose
/// identifier starts with the parenting prefix, so other notifications are never touched.
struct ParentingSystemNotificationCenter: ParentingNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> ParentingNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pending() async -> [ParentingPendingNotification] {
        await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(ParentingReminderPayload.identifierPrefix) }
            .map { request in
                let fire = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                    ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                return ParentingPendingNotification(
                    id: request.identifier,
                    signature: request.content.userInfo[ParentingReminderPayload.signatureKey] as? String,
                    fireAt: fire)
            }
    }

    func add(_ request: ParentingNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "mimi.parenting"
        content.userInfo = request.userInfo
        let interval = max(1, request.fireAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) async {
        let owned = ids.filter { $0.hasPrefix(ParentingReminderPayload.identifierPrefix) }
        guard !owned.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: owned)
        center.removeDeliveredNotifications(withIdentifiers: owned)
    }

    /// Sign-out / account wipe: no reminder of any account may stay on the lock screen or in the queue.
    static func removeAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ParentingReminderPayload.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
            .filter { $0.hasPrefix(ParentingReminderPayload.identifierPrefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
}
#endif
