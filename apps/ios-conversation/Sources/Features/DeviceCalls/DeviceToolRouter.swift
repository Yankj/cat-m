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
    private let store: EKEventStore
    /// Additive: tests share one store (many EKEventStore instances → EventKit error 1021).
    /// p89i-1: creation receipts (trusted identity source for restore / dedupe). Tests may inject an isolated one.
    var receipts: DeviceCreationReceipts
    init(store: EKEventStore = EKEventStore(), receipts: DeviceCreationReceipts? = nil) { self.store = store; self.receipts = receipts ?? .shared; super.init() }
    private var composeContinuation: CheckedContinuation<DeviceCallStatus, Never>?
    /// p89g-4 test seams (production: real MessageUI availability / controllers / top-controller presentation).
    /// Tests use them to drive sms_compose / mail_compose through the REAL commit-gated `present` on a simulator without MessageUI.
    var canCompose: (_ tool: String) -> Bool = { $0 == "sms_compose" ? MFMessageComposeViewController.canSendText() : MFMailComposeViewController.canSendMail() }
    var makeComposer: ((_ tool: String) -> UIViewController)?
    var presentOverride: (@MainActor (UIViewController) -> Void)?
    /// p89g-4: branch trace ("dedupe-hit:calendar", "dedupe-hit:reminder", "present:<tool>") so tests prove the target path ran.
    static var trace: ((String) -> Void)?
    /// Completes a presented compose sheet (delegate path; tests call it for a seam-presented controller).
    func completeCompose(_ controller: UIViewController, _ status: DeviceCallStatus) { finish(controller, status) }

    func canExecute(_ tool: String) -> Bool { Self.tools.contains(tool) }

    func execute(_ call: DeviceCall, credential: DeviceCallGate.Credential) async -> DeviceCallResult {
        // Codex p89b-1: refuse without the execution credential minted by DeviceCallGate.authorize for THIS grant, tool and
        // final args (writes: only after the one-shot tap was consumed). Re-checked synchronously before every system effect.
        // p89b-2: the check is per call (captured credential), never a shared "active call" field.
        // p89d-1: consume the one-shot credential at the execution boundary (a second execute with it is refused).
        if let why = DeviceCallGate.consume(credential, call) { return DeviceCallGate.rejected(call, why) }
        defer { DeviceCallGate.retire(credential) }
        func gate() -> DeviceCallResult? { DeviceCallGate.commitCheck(credential, call).map { DeviceCallGate.rejected(call, $0) } }
        // p89d-2: final effects run INSIDE the commit gate (revoked-set + generation + epoch checked under one lock).
        let commit: @MainActor (() -> Void) -> Bool = { effect in
            if case .done = DeviceCallGate.commitEffect(credential, call, effect) { return true }; return false
        }
        func save(_ write: () throws -> Void) -> DeviceCallResult? {
            do {
                switch try DeviceCallGate.commitEffect(credential, call, write) {
                case .done: return nil
                case .refused(let why): return DeviceCallGate.rejected(call, why)
                }
            } catch { return DeviceCallResult(call_id: call.call_id, status: .error, data: nil) }
        }
        func open(_ url: URL?) async -> DeviceHandoffOutcome { await self.open(url, commit: commit) }
        let a = call.args
        func s(_ k: String) -> String { a[k]?.text ?? "" }
        func d(_ k: String) -> Date? { DeviceCallDates.parse(s(k)) }
        func done(_ status: DeviceCallStatus, _ data: [String: DeviceCallValue]? = nil, open: String? = nil) -> DeviceCallResult {
            var r = DeviceCallResult(call_id: call.call_id, status: status, data: data); r.openURL = open; return r
        }
        func handoff(_ o: DeviceHandoffOutcome, _ extra: [String: DeviceCallValue] = [:], refused: String? = nil) -> DeviceCallResult {
            // p89b-2 kept: a refused handoff reports the gate rejection first (revoked / signed out), fail closed.
            if o == .refused, let rejected = gate() { return rejected }
            return DeviceToolContract.handoffResult(o, callID: call.call_id, extra: extra, refusedReason: refused)
        }
        switch call.tool {
        case "places_search":
            return await NearbyPlaces.search(call: call, gate: gate)   // p89b-5: re-checked after location, before every map query
        case "calendar_list":
            guard await access(.event) else { return done(.denied) }
            if let refused = gate() { return refused }   // p89b-5: revoked / signed out during the permission prompt
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
            if let refused = gate() { return refused }   // p89b-5
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let found = ((try? cs.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: s("query")), keysToFetch: keys)) ?? []).prefix(10)
            let includeEmail: Bool = { if case .bool(let b)? = a["include_email"] { return b }; return false }()
            return done(.ok, ["contacts": .array(found.map { c in .object(DeviceToolContract.minimalContact(name: (c.familyName + c.givenName).trimmingCharacters(in: .whitespaces),
                phones: c.phoneNumbers.map(\.value.stringValue), emails: c.emailAddresses.map { $0.value as String }, includeEmail: includeEmail)) }),
                "count": .number(Double(found.count))])
        case "calendar_create":
            guard await access(.event) else { return done(.denied) }
            if let refused = gate() { return refused }   // p89d-5: no dedupe read after a revoke during the permission prompt
            let marker = DeviceToolContract.callMarker(call.call_id)
            let start = d("start") ?? Date().addingTimeInterval(3600), end = d("end") ?? start.addingTimeInterval(3600)
            // NoBug P0-3: dedupe by call_id — a relaunch after kill must not write a second event.
            // p89i-2: marker search uses DeviceEventKitRule (±1 year around the requested start); uniqueness only refuses.
            let account = credential.token.account
            let marked = DeviceEventKitRule.markedEvents(store, marker: marker, around: start)
            if marked.count > 1 {   // p89h-3: a copy exists — never pick one, never write another
                Self.trace?("dedupe-ambiguous:calendar")
                return done(.error, ["reason": .string("duplicate_marker_ambiguous"), "retryable": .bool(false)])
            }
            if let rc = receipts.receipt(call.call_id, account: account) {
                // p89i-1: created before (receipt) → never written again; trusted only as the receipt's own object.
                guard let e = store.event(withIdentifier: rc.itemID), e.notes?.contains(marker) == true,
                      DeviceEventKitRule.matches(rc.identity, title: e.title, start: e.startDate) else {
                    Self.trace?("dedupe-unverified:calendar")
                    return done(.error, ["reason": .string("original_unverifiable"), "retryable": .bool(false)])
                }
                Self.trace?("dedupe-hit:calendar")
                if let refused = save({}) { return refused }   // p89e-2: a dedupe hit reports success only through the commit gate
                var r = done(.ok, ["event_id": .string(rc.itemID), "deduped": .bool(true)], open: "calshow:\(Int(e.startDate.timeIntervalSinceReferenceDate))")
                r.savedIdentity = rc.identity; return r
            }
            if let existing = marked.first {
                // p89i-1: marker match without a receipt (crash between save and receipt) → not written again, but the
                // matched object gets NO trusted identity: the ledger can show it, undo stays unknown.
                Self.trace?("dedupe-untrusted:calendar")
                if let refused = save({}) { return refused }
                return done(.ok, ["event_id": .string(existing.eventIdentifier ?? ""), "deduped": .bool(true)], open: "calshow:\(Int(existing.startDate.timeIntervalSinceReferenceDate))")
            }
            let e = EKEvent(eventStore: store)
            e.title = s("title"); e.location = s("location").isEmpty ? nil : s("location")
            e.notes = (s("notes").isEmpty ? "" : s("notes") + "\n") + marker
            e.startDate = start; e.endDate = end
            if case .array(let alarms)? = a["alarms"] { for case .number(let m) in alarms { e.addAlarm(EKAlarm(relativeOffset: m * 60)) } }
            e.calendar = store.defaultCalendarForNewEvents
            // p89i: permission turned off while the card / dedupe ran → stop, nothing written; the card asks the user.
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return done(.denied, ["reason": .string("permission_revoked")]) }
            let receipts = self.receipts
            if let refused = save({
                try store.save(e, span: .thisEvent, commit: true)
                // p89i-1: the receipt is written in the same gated closure, from the object just saved.
                receipts.put(.init(callID: call.call_id, kind: .event, itemID: e.eventIdentifier ?? "", identity: .init(title: e.title ?? "", start: e.startDate), account: account, createdAt: Date()))
            }) { return refused }   // p89d-2 single commit gate
            var created = done(.ok, ["event_id": .string(e.eventIdentifier ?? "")], open: "calshow:\(Int(e.startDate.timeIntervalSinceReferenceDate))")
            created.savedIdentity = .init(title: e.title ?? "", start: e.startDate)   // p89h-2: the saved object's identity, not the args
            return created
        case "reminder_create", "alarm_set":
            // No public alarm API: alarm_set becomes a reminder with an absolute alarm (stated on the card).
            guard await access(.reminder) else { return done(.denied) }
            if let refused = gate() { return refused }   // p89d-5
            let account = credential.token.account, marker = DeviceToolContract.callMarker(call.call_id)
            let found = await DeviceEventKitRule.markedReminders(store, marker: marker)   // p89i-2: all reminders, no window
            if found.count > 1 {   // p89h-3 uniqueness
                Self.trace?("dedupe-ambiguous:reminder")
                return done(.error, ["reason": .string("duplicate_marker_ambiguous"), "retryable": .bool(false)])
            }
            if let rc = receipts.receipt(call.call_id, account: account) {
                guard let e = store.calendarItem(withIdentifier: rc.itemID) as? EKReminder, e.notes?.contains(marker) == true,
                      DeviceEventKitRule.matches(rc.identity, title: e.title, start: DeviceSavedIdentity.due(e.dueDateComponents)) else {
                    Self.trace?("dedupe-unverified:reminder")
                    return done(.error, ["reason": .string("original_unverifiable"), "retryable": .bool(false)])
                }
                Self.trace?("dedupe-hit:reminder")
                if let refused = save({}) { return refused }   // p89e-2: revoked while the fetch was suspended → refused, not "ok"
                var r = done(.ok, ["reminder_id": .string(rc.itemID), "deduped": .bool(true)], open: "x-apple-reminderkit://")
                r.savedIdentity = rc.identity; return r
            }
            if let existing = found.first {   // p89i-1: no receipt → not rewritten, no trusted identity
                Self.trace?("dedupe-untrusted:reminder")
                if let refused = save({}) { return refused }
                return done(.ok, ["reminder_id": .string(existing.id), "deduped": .bool(true)], open: "x-apple-reminderkit://")
            }
            let r = EKReminder(eventStore: store)
            r.title = call.tool == "alarm_set" ? (s("label").isEmpty ? "闹钟" : s("label")) : s("title")
            if let due = d(call.tool == "alarm_set" ? "time" : "due") {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due); r.addAlarm(EKAlarm(absoluteDate: due))
            }
            r.calendar = store.calendars(for: .reminder).first { $0.title == s("list") } ?? store.defaultCalendarForNewReminders()
            r.notes = "Catpaw · " + DeviceToolContract.callMarker(call.call_id)
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return done(.denied, ["reason": .string("permission_revoked")]) }   // p89i
            let receipts = self.receipts
            if let refused = save({
                try store.save(r, commit: true)
                receipts.put(.init(callID: call.call_id, kind: .reminder, itemID: r.calendarItemIdentifier, identity: .init(title: r.title ?? "", start: DeviceSavedIdentity.due(r.dueDateComponents)), account: account, createdAt: Date()))   // p89i-1
            }) { return refused }   // p89d-2 single commit gate
            var created = done(.ok, ["reminder_id": .string(r.calendarItemIdentifier)], open: "x-apple-reminderkit://")
            created.savedIdentity = .init(title: r.title ?? "", start: DeviceSavedIdentity.due(r.dueDateComponents))   // p89h-2
            return created
        case "sms_compose":
            guard canCompose(call.tool) else { return done(.error, ["reason": .string("sms_unavailable")]) }
            let vc: UIViewController
            if let make = makeComposer { vc = make(call.tool) } else {
                let m = MFMessageComposeViewController(); m.messageComposeDelegate = self
                if case .list(let to)? = a["to"] { m.recipients = to } else if !s("to").isEmpty { m.recipients = [s("to")] }
                m.body = s("body"); vc = m
            }
            if let refused = gate() { return refused }
            guard let st = await present(vc, tool: call.tool, commit: commit) else { return gate() ?? done(.error) }   // p89e-2: present inside the commit gate
            return done(st)
        case "mail_compose":
            guard canCompose(call.tool) else {
                var c = URLComponents(); c.scheme = "mailto"; c.path = s("to").replacingOccurrences(of: "、", with: ",")
                c.queryItems = [.init(name: "subject", value: s("subject")), .init(name: "body", value: s("body"))]
                return handoff(await open(c.url), ["via": .string("mailto")], refused: "mail_unavailable")
            }
            let vc: UIViewController
            if let make = makeComposer { vc = make(call.tool) } else {
                let m = MFMailComposeViewController(); m.mailComposeDelegate = self
                m.setToRecipients(s("to").split(whereSeparator: { "、, ".contains($0) }).map(String.init))
                m.setCcRecipients(s("cc").split(whereSeparator: { "、, ".contains($0) }).map(String.init))
                m.setSubject(s("subject")); m.setMessageBody(s("body"), isHTML: false); vc = m
            }
            if let refused = gate() { return refused }
            guard let st = await present(vc, tool: call.tool, commit: commit) else { return gate() ?? done(.error) }   // p89e-2: present inside the commit gate
            return done(st)
        case "phone_call":
            let digits = s("number").filter { $0.isNumber || $0 == "+" }
            return handoff(await open(URL(string: "tel:\(digits)")), refused: "tel_unavailable")
        case "maps_open":
            let q = s("query").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let mode = ["walk": "w", "walking": "w", "transit": "r", "drive": "d", "driving": "d"][s("mode")] ?? "d"
            return handoff(await open(URL(string: "maps://?daddr=\(q)&dirflg=\(mode)")))
        case "shop_open":
            let (app, web) = DeviceToolContract.shopURLs(platform: s("platform"), query: s("query"))   // meituan → imeituan:// (P0-4)
            // Prefer installed app only when canOpenURL is true; otherwise go straight to https
            // so Simulator / devices without 淘宝 don't stall on a dead custom scheme.
            if let app, UIApplication.shared.canOpenURL(app) { let o = await open(app); if o != .refused { return handoff(o) } }
            if let refused = gate() { return refused }   // p89b-2: web fallback never skips the check (fail closed)
            return handoff(await open(web), ["via": .string("web")])
        case "shortcut_run":
            var c = URLComponents(string: "shortcuts://run-shortcut")!
            c.queryItems = [.init(name: "name", value: s("name"))] + (s("input").isEmpty ? [] : [.init(name: "input", value: "text"), .init(name: "text", value: s("input"))])
            return handoff(await open(c.url))
        default:
            return DeviceToolContract.unsupported(call)
        }
    }

    /// Restart recovery (Codex PR #89): find the original item; never prompts, never writes.
    /// p89i-1: trust comes ONLY from the creation receipt of the signed-in account: the receipt's own object (same id, our
    /// marker, identity equal to the one read back at creation) and a unique marker under DeviceEventKitRule. No receipt,
    /// id gone, identity changed (moved / edited) or a copy in range → nil (unknown). A marker match alone is never enough.
    func lookup(_ call: DeviceCall) async -> DeviceCallResult? {
        let marker = DeviceToolContract.callMarker(call.call_id)
        guard let rc = receipts.receipt(call.call_id, account: DeviceCallGate.currentAccount()) else { return nil }
        switch call.tool {
        case "calendar_create":
            guard rc.kind == .event, EKEventStore.authorizationStatus(for: .event) == .fullAccess, let start = rc.identity.start,
                  DeviceEventKitRule.markedEvents(store, marker: marker, around: start).count == 1,
                  let e = store.event(withIdentifier: rc.itemID), e.notes?.contains(marker) == true,
                  DeviceEventKitRule.matches(rc.identity, title: e.title, start: e.startDate) else { return nil }
            var r = DeviceCallResult(call_id: call.call_id, status: .ok, data: ["event_id": .string(rc.itemID), "deduped": .bool(true), "recovered": .bool(true)])
            r.savedIdentity = rc.identity; return r
        case "reminder_create", "alarm_set":
            guard rc.kind == .reminder, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return nil }
            let found = await DeviceEventKitRule.markedReminders(store, marker: marker)
            guard found.count == 1, found[0].id == rc.itemID,
                  let e = store.calendarItem(withIdentifier: rc.itemID) as? EKReminder, e.notes?.contains(marker) == true,
                  DeviceEventKitRule.matches(rc.identity, title: e.title, start: DeviceSavedIdentity.due(e.dueDateComponents)) else { return nil }
            var r = DeviceCallResult(call_id: call.call_id, status: .ok, data: ["reminder_id": .string(rc.itemID), "deduped": .bool(true), "recovered": .bool(true)])
            r.savedIdentity = rc.identity; return r
        default: return nil
        }
    }

    /// Proactive 「告诉参会人」: present MessageUI. Never invent sent/done — Simulator `canSendText=false` → `.unavailable`.
    enum NotifyComposeOutcome: String, Sendable { case sent, cancelled, unavailable, error }
    func notifyAttendeesCompose(body: String, recipients: [String] = []) async -> NotifyComposeOutcome {
        guard MFMessageComposeViewController.canSendText() else { return .unavailable }
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = self
        if !recipients.isEmpty { vc.recipients = recipients }
        vc.body = body
        // Local user action (proactive card tap), not an agent device call: no credential to gate on.
        switch await present(vc, commit: { $0(); return true }) ?? .error {
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
    /// p89d-2: `commit` runs the handoff inside DeviceCallGate.commitEffect (same lock as revocation); refused → nothing opened.
    private func open(_ url: URL?, commit: @escaping @MainActor (() -> Void) -> Bool) async -> DeviceHandoffOutcome {
        guard let url else { return .refused }
        let scheme = (url.scheme ?? "").lowercased()
        let schemeAllowed = UIApplication.shared.canOpenURL(url)
            || ["https", "http", "tel", "maps", "mailto"].contains(scheme)
        guard schemeAllowed else { return .refused }
        return await DeviceToolContract.raceHandoff(timeoutNanoseconds: 1_200_000_000) { done in
            let issued = commit { UIApplication.shared.open(url, options: [:]) { ok in done(ok ? .opened : .refused) } }
            if !issued { done(.refused) }   // refused under the commit gate: nothing opened
        }
    }
    /// p89e-2: the system draft sheet is shown INSIDE the commit gate (same lock as revoke / sign-out). Refused → nil, nothing shown.
    private func present(_ vc: UIViewController, tool: String = "notify", commit: @MainActor (() -> Void) -> Bool) async -> DeviceCallStatus? {
        let override = presentOverride
        let top = Self.topController()
        guard override != nil || top != nil else { return .error }
        var shown = false
        let status: DeviceCallStatus = await withCheckedContinuation { c in
            composeContinuation = c
            shown = commit {
                Self.trace?("present:" + tool)
                if let override { override(vc) } else { top?.present(vc, animated: true) }
            }
            if !shown { composeContinuation = nil; c.resume(returning: .error) }
        }
        return shown ? status : nil
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
