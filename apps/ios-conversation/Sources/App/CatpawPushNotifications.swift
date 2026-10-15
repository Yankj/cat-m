import Foundation
#if os(iOS)
import UIKit
import UserNotifications

/// `userInfo.catpaw = {event_id, task_id, conversation_id, kind}` (docs/backend/proactive-tasks.md).
struct CatpawNotificationPayload: Equatable, Sendable {
    static let reminderCategory = "CATPAW_REMINDER"
    var eventID: String
    var taskID: String?
    var conversationID: UUID?
    var kind: String

    init?(userInfo: [AnyHashable: Any]) {
        guard let catpaw = userInfo["catpaw"] as? [String: Any], let event = catpaw["event_id"] as? String, !event.isEmpty else { return nil }
        eventID = event
        taskID = (catpaw["task_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        conversationID = (catpaw["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
        kind = (catpaw["kind"] as? String) ?? "unknown"
    }
    /// Same scheme the Live Activity widget uses (`DeepLinkResolver`).
    var conversationURL: URL? { conversationID.flatMap { URL(string: "catpawm://conversation/" + $0.uuidString.lowercased()) } }
}

/// Registers the `CATPAW_REMINDER` category and the APNs device token (`PUT /devices/tokens {kind: apns}`),
/// and routes taps on proactive notifications to their conversation. Does not prompt for alert permission.
@MainActor final class CatpawAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Last tapped proactive notification; in-app feed can read it to mark `POST /events/:id/read`.
    private(set) static var lastOpened: CatpawNotificationPayload?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: CatpawNotificationPayload.reminderCategory, actions: [], intentIdentifiers: [], options: [])])
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let registration = CatpawDeviceTokenRegistration(kind: .apns, token: deviceToken)
        Task { await CatpawPushTokenUploader.shared.enqueue(registration) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No aps-environment entitlement / Simulator without push: in-app feed still works.
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let payload = CatpawNotificationPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            CatpawAppDelegate.lastOpened = payload
            if let url = payload.conversationURL { UIApplication.shared.open(url) }
        }
    }
}
#endif
