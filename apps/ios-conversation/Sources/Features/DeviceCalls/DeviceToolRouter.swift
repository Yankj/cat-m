import AVFoundation
import Contacts
import EventKit
import Foundation
import MessageUI
import Photos
import Speech
import UIKit
import UserNotifications

/// M1: real on-device executor for catpaw.device.v1. Writes only after the confirm card (the store calls us on 确认).
/// Compose-type tools open the system sheet; the user sends there (cancel → `.cancelled`).
@MainActor final class DeviceToolRouter: NSObject, DeviceToolExecuting {
    static let tools: Set<String> = ["calendar_create", "reminder_create", "alarm_set", "sms_compose", "mail_compose", "phone_call", "maps_open", "shop_open", "shortcut_run"]
    private let store = EKEventStore()
    private var composeContinuation: CheckedContinuation<DeviceCallStatus, Never>?

    func canExecute(_ tool: String) -> Bool { Self.tools.contains(tool) }

    func execute(_ call: DeviceCall) async -> DeviceCallResult {
        let a = call.args
        func s(_ k: String) -> String { a[k]?.text ?? "" }
        func d(_ k: String) -> Date? { DeviceCallDates.parse(s(k)) }
        func done(_ status: DeviceCallStatus, _ data: [String: DeviceCallValue]? = nil, open: String? = nil) -> DeviceCallResult {
            var r = DeviceCallResult(call_id: call.call_id, status: status, data: data); r.openURL = open; return r
        }
        switch call.tool {
        case "calendar_create":
            guard await access(.event) else { return done(.denied) }
            let e = EKEvent(eventStore: store)
            e.title = s("title"); e.location = s("location").isEmpty ? nil : s("location"); e.notes = s("notes").isEmpty ? nil : s("notes")
            e.startDate = d("start") ?? Date().addingTimeInterval(3600); e.endDate = d("end") ?? e.startDate.addingTimeInterval(3600)
            if case .array(let alarms)? = a["alarms"] { for case .number(let m) in alarms { e.addAlarm(EKAlarm(relativeOffset: m * 60)) } }
            e.calendar = store.defaultCalendarForNewEvents
            do { try store.save(e, span: .thisEvent, commit: true) } catch { return done(.error) }
            return done(.ok, ["event_id": .string(e.eventIdentifier ?? "")], open: "calshow:\(Int(e.startDate.timeIntervalSinceReferenceDate))")
        case "reminder_create", "alarm_set":
            // No public alarm API: alarm_set becomes a reminder with an absolute alarm (stated on the card).
            guard await access(.reminder) else { return done(.denied) }
            let r = EKReminder(eventStore: store)
            r.title = call.tool == "alarm_set" ? (s("label").isEmpty ? "闹钟" : s("label")) : s("title")
            if let due = d(call.tool == "alarm_set" ? "time" : "due") {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due); r.addAlarm(EKAlarm(absoluteDate: due))
            }
            r.calendar = store.calendars(for: .reminder).first { $0.title == s("list") } ?? store.defaultCalendarForNewReminders()
            r.notes = "Catpaw · call_id=\(call.call_id)"
            do { try store.save(r, commit: true) } catch { return done(.error) }
            return done(.ok, ["reminder_id": .string(r.calendarItemIdentifier)], open: "x-apple-reminderkit://")
        case "sms_compose":
            guard MFMessageComposeViewController.canSendText() else { return done(.error, ["reason": .string("sms_unavailable")]) }
            let vc = MFMessageComposeViewController(); vc.messageComposeDelegate = self
            if case .list(let to)? = a["to"] { vc.recipients = to } else if !s("to").isEmpty { vc.recipients = [s("to")] }
            vc.body = s("body")
            return done(await present(vc))
        case "mail_compose":
            guard MFMailComposeViewController.canSendMail() else {
                var c = URLComponents(); c.scheme = "mailto"; c.path = s("to").replacingOccurrences(of: "、", with: ",")
                c.queryItems = [.init(name: "subject", value: s("subject")), .init(name: "body", value: s("body"))]
                return await open(c.url) ? done(.ok, ["via": .string("mailto")]) : done(.error, ["reason": .string("mail_unavailable")])
            }
            let vc = MFMailComposeViewController(); vc.mailComposeDelegate = self
            vc.setToRecipients(s("to").split(whereSeparator: { "、, ".contains($0) }).map(String.init))
            vc.setCcRecipients(s("cc").split(whereSeparator: { "、, ".contains($0) }).map(String.init))
            vc.setSubject(s("subject")); vc.setMessageBody(s("body"), isHTML: false)
            return done(await present(vc))
        case "phone_call":
            let digits = s("number").filter { $0.isNumber || $0 == "+" }
            return await open(URL(string: "tel:\(digits)")) ? done(.ok) : done(.error, ["reason": .string("tel_unavailable")])
        case "maps_open":
            let q = s("query").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let mode = ["walk": "w", "walking": "w", "transit": "r", "drive": "d", "driving": "d"][s("mode")] ?? "d"
            return await open(URL(string: "maps://?daddr=\(q)&dirflg=\(mode)")) ? done(.ok) : done(.error)
        case "shop_open":
            let q = s("query").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let platform = s("platform").lowercased()
            let app: URL? = switch platform {
            case "jd", "京东": URL(string: "openapp.jdmobile://virtual?params=%7B%22des%22:%22search%22,%22keyWord%22:%22\(q)%22%7D")
            case "pdd", "拼多多": URL(string: "pinduoduo://com.xunmeng.pinduoduo/search_result.html?search_key=\(q)")
            default: URL(string: "taobao://s.taobao.com/search?q=\(q)")
            }
            let web: URL? = switch platform {
            case "jd", "京东": URL(string: "https://search.jd.com/Search?keyword=\(q)")
            case "pdd", "拼多多": URL(string: "https://mobile.yangkeduo.com/search_result.html?search_key=\(q)")
            default: URL(string: "https://s.taobao.com/search?q=\(q)")
            }
            // Prefer installed app only when canOpenURL is true; otherwise go straight to https
            // so Simulator / devices without 淘宝 don't stall on a dead custom scheme.
            if let app, UIApplication.shared.canOpenURL(app), await open(app) { return done(.ok) }
            return await open(web) ? done(.ok, ["via": .string("web")]) : done(.error)
        case "shortcut_run":
            var c = URLComponents(string: "shortcuts://run-shortcut")!
            c.queryItems = [.init(name: "name", value: s("name"))] + (s("input").isEmpty ? [] : [.init(name: "input", value: "text"), .init(name: "text", value: s("input"))])
            return await open(c.url) ? done(.ok) : done(.error)
        default:
            return done(.error)
        }
    }

    private func access(_ type: EKEntityType) async -> Bool {
        if EKEventStore.authorizationStatus(for: type) == .fullAccess { return true }
        if type == .event { return (try? await store.requestFullAccessToEvents()) ?? false }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }
    /// Opens an external URL. Must not await return-to-foreground: on Simulator, `https`/`tel`/
    /// store schemes hand off to Safari/Phone and the async open continuation can stall for minutes
    /// (UITests then miss `chat.deviceCall.receipt`). Race a short timeout and treat handoff as success.
    private func open(_ url: URL?) async -> Bool {
        guard let url else { return false }
        let scheme = (url.scheme ?? "").lowercased()
        let allowed = UIApplication.shared.canOpenURL(url)
            || ["https", "http", "tel", "maps", "mailto"].contains(scheme)
        guard allowed else { return false }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    UIApplication.shared.open(url, options: [:]) { cont.resume(returning: $0) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return true // handed off / backgrounded — count as attempted
            }
            var result = false
            for await value in group {
                if let value {
                    result = value
                    group.cancelAll()
                    break
                }
            }
            return result
        }
    }
    private func present(_ vc: UIViewController) async -> DeviceCallStatus {
        guard let top = Self.topController() else { return .error }
        return await withCheckedContinuation { c in composeContinuation = c; top.present(vc, animated: true) }
    }
    private func finish(_ controller: UIViewController, _ status: DeviceCallStatus) {
        controller.dismiss(animated: true); composeContinuation?.resume(returning: status); composeContinuation = nil
    }
    static func topController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

extension DeviceToolRouter: MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        MainActor.assumeIsolated { finish(controller, result == .sent ? .ok : result == .cancelled ? .cancelled : .error) }
    }
    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        MainActor.assumeIsolated { finish(controller, result == .sent || result == .saved ? .ok : result == .cancelled ? .cancelled : .error) }
    }
}

/// Real permission state for the permission / degrade cards.
@MainActor final class SystemDevicePermissionProvider: DevicePermissionProviding {
    func status(_ kind: DevicePermissionKind) async -> DevicePermissionStatus {
        switch kind {
        case .calendar: Self.ek(EKEventStore.authorizationStatus(for: .event))
        case .reminders: Self.ek(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) { case .authorized: .authorized; case .limited: .limited; case .denied: .denied; case .restricted: .restricted; default: .notDetermined }
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus { case .authorized, .provisional, .ephemeral: .authorized; case .denied: .denied; default: .notDetermined }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) { case .authorized: .authorized; case .limited: .limited; case .denied: .denied; case .restricted: .restricted; default: .notDetermined }
        case .microphone:
            switch AVAudioApplication.shared.recordPermission { case .granted: .authorized; case .denied: .denied; default: .notDetermined }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() { case .authorized: .authorized; case .denied: .denied; case .restricted: .restricted; default: .notDetermined }
        case .location: .unavailable
        }
    }
    func request(_ kind: DevicePermissionKind) async -> DevicePermissionStatus {
        let store = EKEventStore()
        switch kind {
        case .calendar: _ = try? await store.requestFullAccessToEvents()
        case .reminders: _ = try? await store.requestFullAccessToReminders()
        case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .microphone: _ = await AVAudioApplication.requestRecordPermission()
        case .speech: _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        case .location: break
        }
        return await status(kind)
    }
    private static func ek(_ s: EKAuthorizationStatus) -> DevicePermissionStatus {
        switch s { case .fullAccess: .authorized; case .writeOnly: .limited; case .denied: .denied; case .restricted: .restricted; default: .notDetermined }
    }
}
