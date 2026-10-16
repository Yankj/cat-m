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
    static let tools: Set<String> = Set(DeviceToolContract.clientTools)
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
        func handoff(_ o: DeviceHandoffOutcome, _ extra: [String: DeviceCallValue] = [:], refused: String? = nil) -> DeviceCallResult {
            DeviceToolContract.handoffResult(o, callID: call.call_id, extra: extra, refusedReason: refused)
        }
        switch call.tool {
        case "places_search":
            return await NearbyPlaces.search(call: call)
        case "calendar_list":
            guard await access(.event) else { return done(.denied) }
            let from = d("from") ?? Date(), to = d("to") ?? from.addingTimeInterval(86400)
            guard to > from, to.timeIntervalSince(from) <= 31 * 86400 else { return done(.error, ["reason": .string("invalid_range"), "retryable": .bool(false)]) }
            let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).sorted { $0.startDate < $1.startDate }.prefix(50)
            return done(.ok, ["events": .array(events.map { e in .object(["title": .string(e.title ?? ""), "start": .string(DeviceCallDates.format(e.startDate)),
                "end": .string(DeviceCallDates.format(e.endDate)), "all_day": .bool(e.isAllDay), "location": .string(e.location ?? "")]) }),
                "count": .number(Double(events.count))])
        case "contacts_search":
            let cs = CNContactStore()
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try? await cs.requestAccess(for: .contacts) }
            let st = CNContactStore.authorizationStatus(for: .contacts)
            var ok = st == .authorized
            if #available(iOS 18.0, *) { ok = ok || st == .limited }
            guard ok else { return done(.denied) }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let found = ((try? cs.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: s("query")), keysToFetch: keys)) ?? []).prefix(10)
            let includeEmail: Bool = { if case .bool(let b)? = a["include_email"] { return b }; return false }()
            return done(.ok, ["contacts": .array(found.map { c in .object(DeviceToolContract.minimalContact(name: (c.familyName + c.givenName).trimmingCharacters(in: .whitespaces),
                phones: c.phoneNumbers.map(\.value.stringValue), emails: c.emailAddresses.map { $0.value as String }, includeEmail: includeEmail)) }),
                "count": .number(Double(found.count))])
        case "calendar_create":
            guard await access(.event) else { return done(.denied) }
            let marker = DeviceToolContract.callMarker(call.call_id)
            let start = d("start") ?? Date().addingTimeInterval(3600), end = d("end") ?? start.addingTimeInterval(3600)
            // NoBug P0-3: dedupe by call_id — a relaunch after kill must not write a second event.
            let window = store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: end.addingTimeInterval(86400), calendars: nil)
            if let existing = store.events(matching: window).first(where: { $0.notes?.contains(marker) == true }) {
                return done(.ok, ["event_id": .string(existing.eventIdentifier ?? ""), "deduped": .bool(true)], open: "calshow:\(Int(existing.startDate.timeIntervalSinceReferenceDate))")
            }
            let e = EKEvent(eventStore: store)
            e.title = s("title"); e.location = s("location").isEmpty ? nil : s("location")
            e.notes = (s("notes").isEmpty ? "" : s("notes") + "\n") + marker
            e.startDate = start; e.endDate = end
            if case .array(let alarms)? = a["alarms"] { for case .number(let m) in alarms { e.addAlarm(EKAlarm(relativeOffset: m * 60)) } }
            e.calendar = store.defaultCalendarForNewEvents
            do { try store.save(e, span: .thisEvent, commit: true) } catch { return done(.error) }
            return done(.ok, ["event_id": .string(e.eventIdentifier ?? "")], open: "calshow:\(Int(e.startDate.timeIntervalSinceReferenceDate))")
        case "reminder_create", "alarm_set":
            // No public alarm API: alarm_set becomes a reminder with an absolute alarm (stated on the card).
            guard await access(.reminder) else { return done(.denied) }
            if let existing = await existingReminder(call.call_id) {   // NoBug P0-3 dedupe
                return done(.ok, ["reminder_id": .string(existing), "deduped": .bool(true)], open: "x-apple-reminderkit://")
            }
            let r = EKReminder(eventStore: store)
            r.title = call.tool == "alarm_set" ? (s("label").isEmpty ? "闹钟" : s("label")) : s("title")
            if let due = d(call.tool == "alarm_set" ? "time" : "due") {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due); r.addAlarm(EKAlarm(absoluteDate: due))
            }
            r.calendar = store.calendars(for: .reminder).first { $0.title == s("list") } ?? store.defaultCalendarForNewReminders()
            r.notes = "Catpaw · " + DeviceToolContract.callMarker(call.call_id)
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
                return handoff(await open(c.url), ["via": .string("mailto")], refused: "mail_unavailable")
            }
            let vc = MFMailComposeViewController(); vc.mailComposeDelegate = self
            vc.setToRecipients(s("to").split(whereSeparator: { "、, ".contains($0) }).map(String.init))
            vc.setCcRecipients(s("cc").split(whereSeparator: { "、, ".contains($0) }).map(String.init))
            vc.setSubject(s("subject")); vc.setMessageBody(s("body"), isHTML: false)
            return done(await present(vc))
        case "phone_call":
            let digits = s("number").filter { $0.isNumber || $0 == "+" }
            return handoff(await open(URL(string: "tel:\(digits)")), refused: "tel_unavailable")
        case "maps_open":
            func num(_ k: String) -> Double? { if case .number(let n)? = a[k] { return n }; return nil }
            return handoff(await open(DeviceToolContract.mapsURL(query: s("query"), lat: num("lat"), lng: num("lng"), mode: s("mode"))))
        case "shop_open":
            if let direct = DeviceToolContract.shopDirectURL(s("url")) { return handoff(await open(direct), ["via": .string("url")]) }
            let (app, web) = DeviceToolContract.shopURLs(platform: s("platform"), query: s("query"))   // meituan → imeituan:// (P0-4)
            // Prefer installed app only when canOpenURL is true; otherwise go straight to https
            // so Simulator / devices without 淘宝 don't stall on a dead custom scheme.
            if let app, UIApplication.shared.canOpenURL(app) { let o = await open(app); if o != .refused { return handoff(o) } }
            return handoff(await open(web), ["via": .string("web")])
        case "shortcut_run":
            return handoff(await open(DeviceToolContract.shortcutURL(name: s("name"), input: s("input"))))
        default:
            return DeviceToolContract.unsupported(call)
        }
    }

    private func existingReminder(_ callID: String) async -> String? {
        let marker = DeviceToolContract.callMarker(callID)
        let predicate = store.predicateForReminders(in: nil)
        let ids: [String] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { rs in c.resume(returning: (rs ?? []).filter { $0.notes?.contains(marker) == true }.map(\.calendarItemIdentifier)) }
        }
        return ids.first
    }


    /// Proactive 「告诉参会人」: present MessageUI. Never invent sent/done — Simulator `canSendText=false` → `.unavailable`.
    enum NotifyComposeOutcome: String, Sendable { case sent, cancelled, unavailable, error }
    func notifyAttendeesCompose(body: String, recipients: [String] = []) async -> NotifyComposeOutcome {
        guard MFMessageComposeViewController.canSendText() else { return .unavailable }
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = self
        if !recipients.isEmpty { vc.recipients = recipients }
        vc.body = body
        switch await present(vc) {
        case .ok: return .sent
        case .cancelled: return .cancelled
        case .denied: return .unavailable
        case .error: return .error
        }
    }

    private func access(_ type: EKEntityType) async -> Bool {
        if EKEventStore.authorizationStatus(for: type) == .fullAccess { return true }
        if type == .event { return (try? await store.requestFullAccessToEvents()) ?? false }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }
    /// Opens an external URL. Must not await return-to-foreground: on Simulator, `https`/`tel`/
    /// store schemes hand off to Safari/Phone and the async open continuation can stall for minutes
    /// (UITests then miss `chat.deviceCall.receipt`). Race a short timeout; Codex P0-4: a timeout is `.timedOut`
    /// (outcome unknown), never success.
    private func open(_ url: URL?) async -> DeviceHandoffOutcome {
        guard let url else { return .refused }
        let scheme = (url.scheme ?? "").lowercased()
        let allowed = UIApplication.shared.canOpenURL(url)
            || ["https", "http", "tel", "maps", "mailto"].contains(scheme)
        guard allowed else { return .refused }
        return await withTaskGroup(of: DeviceHandoffOutcome?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (cont: CheckedContinuation<DeviceHandoffOutcome?, Never>) in
                    UIApplication.shared.open(url, options: [:]) { cont.resume(returning: $0 ? .opened : .refused) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return .timedOut // handed off but unconfirmed — outcome unknown
            }
            var result: DeviceHandoffOutcome = .timedOut
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
