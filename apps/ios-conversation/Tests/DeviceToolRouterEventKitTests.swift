import XCTest
import EventKit
@testable import CatpawM

/// NoBug P1-5: real EventKit on the BE5C simulator — the call_id marker dedupes calendar_create / reminder_create,
/// so re-running the same device_call after a kill never writes a second item.
@MainActor final class DeviceToolRouterEventKitTests: XCTestCase {
    private let store = EKEventStore()

    private func need(_ type: EKEntityType) throws {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
            throw XCTSkip("EventKit \(type == .event ? "calendar" : "reminders") not granted; run `xcrun simctl privacy <udid> grant \(type == .event ? "calendar" : "reminders") <bundle>` first")
        }
    }

    func testCalendarCreateDedupesByCallID() async throws {
        try need(.event)
        let id = "xctest-cal-" + UUID().uuidString, start = Date().addingTimeInterval(3 * 86400)
        let call = DeviceCall(call_id: id, tool: "calendar_create", args: ["title": .string("NoBug dedupe"), "start": .string(DeviceCallDates.format(start)),
                                                                          "end": .string(DeviceCallDates.format(start.addingTimeInterval(1800)))], confirm: .card, ttl_sec: 600)
        let router = DeviceToolRouter()
        let first = await router.execute(call), second = await router.execute(call)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(first.data?["event_id"], second.data?["event_id"])
        XCTAssertEqual(second.data?["deduped"], .bool(true))
        let marker = DeviceToolContract.callMarker(id)
        store.reset()
        let matches = store.events(matching: store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: nil))
            .filter { $0.notes?.contains(marker) == true }
        print("nobug.eventkit calendar call_id=\(id) events_with_marker=\(matches.count) event_id=\(first.data?["event_id"]?.text ?? "")")
        XCTAssertEqual(matches.count, 1)
        for e in matches { try? store.remove(e, span: .thisEvent, commit: true) }
    }

    func testReminderCreateDedupesByCallID() async throws {
        try need(.reminder)
        let id = "xctest-rem-" + UUID().uuidString
        let call = DeviceCall(call_id: id, tool: "reminder_create", args: ["title": .string("NoBug dedupe reminder")], confirm: .card, ttl_sec: 600)
        let router = DeviceToolRouter()
        let first = await router.execute(call), second = await router.execute(call)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(second.data?["deduped"], .bool(true))
        XCTAssertEqual(first.data?["reminder_id"], second.data?["reminder_id"])
        let marker = DeviceToolContract.callMarker(id)
        store.reset()
        let all: [EKReminder] = await withCheckedContinuation { c in store.fetchReminders(matching: store.predicateForReminders(in: nil)) { c.resume(returning: $0 ?? []) } }
        let matches = all.filter { $0.notes?.contains(marker) == true }
        print("nobug.eventkit reminder call_id=\(id) reminders_with_marker=\(matches.count)")
        XCTAssertEqual(matches.count, 1)
        for r in matches { try? store.remove(r, commit: true) }
    }
}
