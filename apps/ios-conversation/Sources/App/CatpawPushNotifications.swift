import Foundation

/// The local, version-independent context carried by pre-scheduled meeting notifications. Parsing
/// never reads calendars or evaluates a new suggestion; malformed or expired dates cannot create work.
struct CatpawScheduledMeetingNotification: Equatable, Sendable {
    let eventID: String
    let title: String
    let start: Date
    let due: Date
    let place: String

    init?(userInfo: [AnyHashable: Any], defaultLeadMinutes: Int, now: Date) {
        guard let eventID = userInfo["catpaw_proactive_event"] as? String,
              !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let title = userInfo["catpaw_proactive_title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let seconds = userInfo["catpaw_proactive_start"] as? TimeInterval, seconds.isFinite else { return nil }
        let start = Date(timeIntervalSince1970: seconds)
        guard start > now, start <= now.addingTimeInterval(24 * 3600) else { return nil }
        let due: Date
        if let value = userInfo["catpaw_proactive_due"] {
            guard let seconds = value as? TimeInterval, seconds.isFinite else { return nil }
            due = Date(timeIntervalSince1970: seconds)
        } else {
            // Older local notifications did not carry their lead time.
            guard (1...180).contains(defaultLeadMinutes) else { return nil }
            due = start.addingTimeInterval(TimeInterval(-defaultLeadMinutes * 60))
        }
        guard due <= start, due >= start.addingTimeInterval(-180 * 60) else { return nil }
        self.eventID = eventID
        self.title = title
        self.start = start
        self.due = due
        self.place = userInfo["catpaw_proactive_place"] as? String ?? ""
    }
}

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
        center.setNotificationCategories(CatpawPushAction.categories.union(ProactiveEngine.categories))
        ProactiveSuggestionHub.backend = ProactiveLocalBackend(); DeviceCallHub.executor = DeviceToolRouter(); DevicePermissionHub.provider = SystemDevicePermissionProvider()
        ProactiveSignalHub.engine = ProactiveEngineSignalAdapter()
        ProactiveEngine.registerBackgroundRefresh()
        ProactiveEngine.scheduleBackgroundRefresh()
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

    /// Foreground: show Catpaw's own floating capsule instead of the system banner (V4 / #47).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        // AccountEpoch (b): local + APNs proactive notifications pass the account check and the same device gate.
        nonisolated(unsafe) let gateInfo = content.userInfo
        let verdict: ProactiveAccountGate.Verdict = await MainActor.run {
            var q = ProactiveEngine.shared.quota
            let v = ProactiveAccountGate.verdict(gateInfo, epoch: .shared, now: .now, quota: &q)
            ProactiveEngine.shared.quota = q; return v
        }
        switch verdict {
        case .drop(let why): await MainActor.run { ProactiveEngine.shared.note("notification dropped: \(why)") }; return []
        case .inboxOnly: await MainActor.run { CatpawProactiveFeed.shared.refreshSoon() }; return []
        case .present: break
        }
        let isProactive = content.userInfo["catpaw_proactive_id"] is String || content.userInfo["catpaw_proactive_event"] is String
        let link = CatpawNotificationPayload(userInfo: content.userInfo)?.conversationURL
            ?? (isProactive ? URL(string: "catpawm://proactive") : nil)
        let title = content.title, body = content.body
        await MainActor.run { CatpawInAppBannerCenter.shared.show(CatpawInAppBanner(title: title, body: body, deepLink: link)) }
        return [.list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo, actionID = response.actionIdentifier
        nonisolated(unsafe) let sendableInfo = info
        guard ProactiveAccountGate.belongsToCurrent(sendableInfo, epoch: .shared) else { return }  // other / stale account: no navigation, no action
        if await ProactiveEngine.shared.handleNotification(actionIdentifier: actionID, userInfo: sendableInfo) { return }
        guard let payload = CatpawNotificationPayload(userInfo: response.notification.request.content.userInfo) else { return }
        // Category buttons write back through /push/action; a plain tap counts as `open`.
        let action = CatpawPushAction.serverAction(for: response.actionIdentifier)
        if let action { await CatpawPushTokenUploader.shared.sendPushAction(eventID: payload.eventID, action: action) }
        guard action == "open" else { await MainActor.run { CatpawProactiveFeed.shared.refreshSoon() }; return }
        await MainActor.run {
            CatpawAppDelegate.lastOpened = payload
            CatpawProactiveFeed.shared.refreshSoon()
            if let url = payload.conversationURL { UIApplication.shared.open(url) }
        }
    }
}

/// M2 notification categories → `POST /push/action`.
enum CatpawPushAction {
    static let done = "CATPAW_DONE", snooze10 = "CATPAW_SNOOZE_10M", snooze60 = "CATPAW_SNOOZE_1H"
    static let taskCategory = "CATPAW_TASK"
    static var categories: Set<UNNotificationCategory> {
        let doneA = UNNotificationAction(identifier: done, title: AppLanguage(locale: .current).ui("完成"), options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        let s10 = UNNotificationAction(identifier: snooze10, title: AppLanguage(locale: .current).ui("10 分钟后提醒"), options: [], icon: UNNotificationActionIcon(systemImageName: "clock"))
        let s60 = UNNotificationAction(identifier: snooze60, title: AppLanguage(locale: .current).ui("1 小时后提醒"), options: [], icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        return [UNNotificationCategory(identifier: CatpawNotificationPayload.reminderCategory, actions: [doneA, s10, s60], intentIdentifiers: [], options: [.customDismissAction]),
                UNNotificationCategory(identifier: taskCategory, actions: [doneA, s10], intentIdentifiers: [], options: [.customDismissAction])]
    }
    static func serverAction(for identifier: String) -> String? {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: return "open"
        case UNNotificationDismissActionIdentifier: return "dismiss"
        case done: return "done"
        case snooze10: return "snooze_10m"
        case snooze60: return "snooze_1h"
        default: return nil
        }
    }
}
#endif
