import Foundation
import XCTest
@testable import cat

/// In-memory stand-in for the system notification centre. It records every call so tests can
/// prove what was (and was not) written; it is never evidence for real delivery by iOS.
final class FakeParentingNotificationCenter: ParentingNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var status: ParentingNotificationAuthorization
    private var grantOnRequest: Bool
    private var store: [String: ParentingNotificationRequest] = [:]
    private var adds = 0
    private var removed: [String] = []
    private var prompts = 0
    var failAdds = false
    /// Accept the add call but never keep the request, as a refusing system might.
    var silentlyDropAdds = false
    /// Runs while an add is in flight, e.g. to sign the account out mid-write.
    var onAdd: (@Sendable () -> Void)?

    init(status: ParentingNotificationAuthorization, grantOnRequest: Bool = true) {
        self.status = status; self.grantOnRequest = grantOnRequest
    }
    var addCount: Int { lock.withLock { adds } }
    var removedIDs: [String] { lock.withLock { removed } }
    var authorizationRequests: Int { lock.withLock { prompts } }
    func seed(_ request: ParentingNotificationRequest) { lock.withLock { store[request.id] = request } }
    var requests: [ParentingNotificationRequest] { lock.withLock { store.values.sorted { $0.fireAt < $1.fireAt } } }

    func authorization() async -> ParentingNotificationAuthorization { lock.withLock { status } }
    func requestAuthorization() async throws -> Bool {
        lock.withLock {
            prompts += 1
            if status == .notDetermined { status = grantOnRequest ? .authorized : .denied }
            return status == .authorized
        }
    }
    func pending() async -> [ParentingPendingNotification] {
        lock.withLock { store.values.map { .init(id: $0.id, signature: $0.userInfo[ParentingReminderPayload.signatureKey], fireAt: $0.fireAt) } }
    }
    func add(_ request: ParentingNotificationRequest) async throws {
        try addSynchronously(request)
    }
    private func addSynchronously(_ request: ParentingNotificationRequest) throws {
        let hook: (@Sendable () -> Void)? = lock.withLock { adds += 1; return onAdd }
        hook?()
        if failAdds { throw catError.unavailable("Synthetic notification refusal") }
        lock.withLock { if !silentlyDropAdds { store[request.id] = request } }
    }
    func remove(ids: [String]) async {
        lock.withLock {
            removed += ids
            for id in ids { store[id] = nil }
        }
    }
}

final class ParentingReminderPlannerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private let child = UUID(uuidString: "C1000000-0000-4000-8000-000000000001")!

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func arrangement(_ n: Int, due: Date, state: ParentingArrangementState = .planned, title: String = "合成安排") -> ParentingArrangement {
        .init(id: UUID(uuidString: String(format: "A%07X-0000-4000-8000-000000000001", n))!, childID: child, title: title + String(n),
              dueAt: due, goalID: nil, state: state, sourceText: "", createdAt: date(20, 8), updatedAt: date(20, 8))
    }
    private func workspace(_ items: [ParentingArrangement]) -> ParentingWorkspace {
        ParentingWorkspace(children: [.init(id: child, name: "合成小星", createdAt: date(20, 8))], arrangements: items)
    }
    private let on = ParentingReminderSettings(enabled: true, lead: .hour1, hideContent: false)

    func testOnlyConfirmedFutureArrangementsGetReminders() {
        let now = date(25, 10)
        let items = [arrangement(1, due: date(26, 15), state: .draft), arrangement(2, due: date(26, 15), state: .cancelled),
                     arrangement(3, due: date(26, 15), state: .completed), arrangement(4, due: date(26, 15)),
                     arrangement(5, due: date(24, 15))]
        let plan = ParentingReminderPlanner.plan(workspace: workspace(items), settings: on, now: now, calendar: calendar)
        XCTAssertEqual(plan.reminders.map(\.arrangementID), [items[3].id])
        XCTAssertEqual(plan.reminders.first?.fireAt, date(26, 14))
        XCTAssertFalse(plan.reminders.first?.movedForQuietHours ?? true)
        XCTAssertTrue(plan.skipped.isEmpty, "Past, draft, cancelled and completed items are not 'skipped reminders'")
    }

    func testDisabledSettingsPlanNothing() {
        let plan = ParentingReminderPlanner.plan(workspace: workspace([arrangement(1, due: date(26, 15))]),
                                                 settings: .default, now: date(25, 10), calendar: calendar)
        XCTAssertEqual(plan, .init(reminders: [], skipped: [:], deferred: [], reminded: [:]))
    }

    func testQuietHoursMoveTheReminderToTheEveningBefore() {
        let now = date(25, 10)
        // 07:30 with a one-hour lead would ring at 06:30: move to 20:30 the evening before.
        let early = ParentingReminderPlanner.fireDate(due: date(26, 7, 30), lead: .hour1, calendar: calendar)
        XCTAssertEqual(early?.date, date(25, 20, 30)); XCTAssertEqual(early?.moved, true)
        // 22:00 with a 30-minute lead would ring at 21:30: 20:30 the same evening.
        let late = ParentingReminderPlanner.fireDate(due: date(26, 22), lead: .minutes30, calendar: calendar)
        XCTAssertEqual(late?.date, date(26, 20, 30)); XCTAssertEqual(late?.moved, true)
        // Exactly 08:00 and 20:59 are outside the quiet window.
        XCTAssertFalse(ParentingReminderPlanner.isQuiet(date(26, 8), calendar: calendar))
        XCTAssertFalse(ParentingReminderPlanner.isQuiet(date(26, 20, 59), calendar: calendar))
        XCTAssertTrue(ParentingReminderPlanner.isQuiet(date(26, 21), calendar: calendar))
        XCTAssertTrue(ParentingReminderPlanner.isQuiet(date(26, 7, 59), calendar: calendar))
        let plan = ParentingReminderPlanner.plan(workspace: workspace([arrangement(1, due: date(26, 7, 30))]), settings: on, now: now, calendar: calendar)
        XCTAssertEqual(plan.reminders.first?.movedForQuietHours, true)
        for reminder in plan.reminders { XCTAssertFalse(ParentingReminderPlanner.isQuiet(reminder.fireAt, calendar: calendar)) }
    }

    func testEveningBeforeLeadAndPastReminderTime() {
        let evening = ParentingReminderPlanner.fireDate(due: date(26, 9), lead: .eveningBefore, calendar: calendar)
        XCTAssertEqual(evening?.date, date(25, 20)); XCTAssertEqual(evening?.moved, false)
        // Already 21:30 on the 25th: the evening-before slot (20:00) has passed. Say so; never invent a time.
        let settings = ParentingReminderSettings(enabled: true, lead: .eveningBefore, hideContent: false)
        let item = arrangement(1, due: date(26, 9))
        let plan = ParentingReminderPlanner.plan(workspace: workspace([item]), settings: settings, now: date(25, 21, 30), calendar: calendar)
        XCTAssertTrue(plan.reminders.isEmpty)
        XCTAssertEqual(plan.skipped[item.id], .pastReminderTime)
        // A 30-minute lead that has already passed is skipped, not rung immediately.
        let soon = arrangement(2, due: date(25, 10, 20))
        let soonPlan = ParentingReminderPlanner.plan(workspace: workspace([soon]), settings: ParentingReminderSettings(enabled: true, lead: .minutes30, hideContent: false), now: date(25, 10), calendar: calendar)
        XCTAssertEqual(soonPlan.skipped[soon.id], .pastReminderTime)
    }

    func testAtMostTwoRemindersPerLocalDayAndTheRestAreReportedNotDropped() {
        let items = [arrangement(1, due: date(26, 9)), arrangement(2, due: date(26, 11)), arrangement(3, due: date(26, 13)),
                     arrangement(4, due: date(27, 9))]
        let plan = ParentingReminderPlanner.plan(workspace: workspace(items), settings: on, now: date(25, 10), calendar: calendar)
        XCTAssertEqual(plan.reminders.map(\.arrangementID), [items[0].id, items[1].id, items[3].id])
        XCTAssertEqual(plan.skipped, [items[2].id: .dailyLimit])
    }

    func testAReminderThatAlreadyWentOffIsNotReportedAsMissedAndCountsTowardTheDay() {
        let a = arrangement(1, due: date(26, 11)), b = arrangement(2, due: date(26, 11, 20)), c = arrangement(3, due: date(26, 15))
        // At 10:30 on the 26th: a (fire 10:00) and b (fire 10:20) were scheduled earlier and have fired.
        let remembered: [UUID: Date] = [a.id: date(26, 10), b.id: date(26, 10, 20)]
        let plan = ParentingReminderPlanner.plan(workspace: workspace([a, b, c]), settings: on, now: date(26, 10, 30), calendar: calendar, remembered: remembered)
        XCTAssertEqual(plan.reminded, remembered)
        XCTAssertNil(plan.skipped[a.id]); XCTAssertNil(plan.skipped[b.id])
        XCTAssertTrue(plan.reminders.isEmpty)
        XCTAssertEqual(plan.skipped[c.id], .dailyLimit, "Two reminders already went off today")
        // Without that memory the same items are honestly 'time has passed'.
        let forgotten = ParentingReminderPlanner.plan(workspace: workspace([a, b]), settings: on, now: date(26, 10, 30), calendar: calendar)
        XCTAssertEqual(forgotten.skipped, [a.id: .pastReminderTime, b.id: .pastReminderTime])
        XCTAssertTrue(forgotten.reminded.isEmpty)
        // A remembered time that no longer matches (the item was moved) does not count as reminded.
        let moved = ParentingReminderPlanner.plan(workspace: workspace([a]), settings: on, now: date(26, 10, 30), calendar: calendar, remembered: [a.id: date(25, 8)])
        XCTAssertEqual(moved.skipped[a.id], .pastReminderTime)
    }

    func testPlanIsDeterministicAndCapsPendingCount() {
        var items: [ParentingArrangement] = []
        for n in 0..<80 { items.append(arrangement(n + 1, due: date(26, 9).addingTimeInterval(TimeInterval(n) * 86_400))) }
        let first = ParentingReminderPlanner.plan(workspace: workspace(items), settings: on, now: date(25, 10), calendar: calendar)
        let second = ParentingReminderPlanner.plan(workspace: workspace(items.reversed()), settings: on, now: date(25, 10), calendar: calendar)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.reminders.count, ParentingReminderPlanner.maxPending)
        XCTAssertEqual(first.deferred.count, 80 - ParentingReminderPlanner.maxPending, "The rest wait for a later sync, they are not lost")
        XCTAssertTrue(first.deferred.isDisjoint(with: Set(first.reminders.map(\.arrangementID))))
        XCTAssertLessThanOrEqual(first.reminders.count, 64, "iOS keeps at most 64 pending local notifications")
    }

    func testReminderPayloadBelongsOnlyToTheSchedulingAccount() {
        let subject = UUID()
        let info: [AnyHashable: Any] = [ParentingReminderPayload.marker: "1", ParentingReminderPayload.subjectKey: subject.uuidString.lowercased()]
        XCTAssertTrue(ParentingReminderPayload.belongsToCurrent(info, currentAccount: subject.uuidString))
        XCTAssertFalse(ParentingReminderPayload.belongsToCurrent(info, currentAccount: UUID().uuidString))
        XCTAssertFalse(ParentingReminderPayload.belongsToCurrent(info, currentAccount: nil))
        XCTAssertFalse(ParentingReminderPayload.belongsToCurrent([:], currentAccount: subject.uuidString))
        XCTAssertFalse(ParentingReminderPayload.isParenting(["catpaw_proactive_event": "x"]))
    }

    func testDeleteAllRecordsClearsEverythingButKeepsTheReviewSetting() throws {
        let item = arrangement(1, due: date(26, 15), state: .planned)
        var seeded = workspace([item])
        seeded.suggestionsEnabled = true
        seeded.goals = [.init(id: UUID(), childID: child, title: "合成目标", createdAt: date(20, 8))]
        seeded.records = [.init(id: UUID(), childID: child, goalID: nil, arrangementID: nil, kind: .observation, text: "合成观察", sourceText: "合成观察", createdAt: date(20, 9), updatedAt: date(20, 9))]
        let erased = try seeded.applying(.deleteAllRecords, now: date(25, 10))
        XCTAssertTrue(erased.children.isEmpty && erased.goals.isEmpty && erased.arrangements.isEmpty && erased.records.isEmpty && erased.editHistory.isEmpty)
        XCTAssertTrue(erased.suggestionsEnabled)
        XCTAssertEqual(erased.revision, seeded.revision + 1)
        let plan = ParentingReminderPlanner.plan(workspace: erased, settings: on, now: date(25, 10), calendar: calendar)
        XCTAssertTrue(plan.reminders.isEmpty)
    }
}

final class ParentingReminderSchedulerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private let subject = UUID(uuidString: "D1000000-0000-4000-8000-000000000001")!
    private let child = UUID(uuidString: "C1000000-0000-4000-8000-000000000001")!
    private let reminderCopy = ParentingReminderCopy { key, arguments in
        arguments.enumerated().reduce(key) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element) }
    }
    private let on = ParentingReminderSettings(enabled: true, lead: .hour1, hideContent: false)

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func item(_ n: Int, due: Date, state: ParentingArrangementState = .planned, title: String = "合成绘本") -> ParentingArrangement {
        .init(id: UUID(uuidString: String(format: "A%07X-0000-4000-8000-000000000001", n))!, childID: child, title: title,
              dueAt: due, goalID: nil, state: state, sourceText: "", createdAt: date(20, 8), updatedAt: date(20, 8))
    }
    private func workspace(_ items: [ParentingArrangement]) -> ParentingWorkspace {
        ParentingWorkspace(children: [.init(id: child, name: "合成小星", createdAt: date(20, 8))], arrangements: items)
    }
    private func scheduler(_ center: FakeParentingNotificationCenter, current: @escaping @Sendable () -> Bool = { true }) -> ParentingReminderScheduler {
        ParentingReminderScheduler(center: center, subjectID: subject, calendar: calendar, copy: reminderCopy, isCurrentAccount: current)
    }

    func testSchedulesConfirmedItemsAndReportsOnlyWhatTheSystemKept() async {
        let center = FakeParentingNotificationCenter(status: .authorized)
        let items = [item(1, due: date(26, 15)), item(2, due: date(26, 16), state: .draft)]
        let status = await scheduler(center).reconcile(workspace: workspace(items), settings: on, now: date(25, 10))
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.id, ParentingReminderPayload.identifier(subject: subject, arrangement: items[0].id))
        XCTAssertEqual(status.outcomes[items[0].id], .scheduled(date(26, 14)))
        XCTAssertNil(status.outcomes[items[1].id], "A draft is never described as reminded")
        XCTAssertEqual(status.scheduledCount, 1)
        XCTAssertFalse(status.systemRefused)
        let request = try! XCTUnwrap(center.requests.first)
        XCTAssertTrue(request.body.contains("合成小星") && request.body.contains("合成绘本"))
        XCTAssertEqual(request.userInfo[ParentingReminderPayload.subjectKey], subject.uuidString.lowercased())
        XCTAssertEqual(request.userInfo[ParentingReminderPayload.marker], "1")
    }

    func testNothingIsClaimedWhenTheSystemKeepsNothingOrFails() async {
        let dropping = FakeParentingNotificationCenter(status: .authorized)
        dropping.silentlyDropAdds = true
        let a = await scheduler(dropping).reconcile(workspace: workspace([item(1, due: date(26, 15))]), settings: on, now: date(25, 10))
        XCTAssertEqual(a.scheduledCount, 0); XCTAssertTrue(a.systemRefused)
        let failing = FakeParentingNotificationCenter(status: .authorized)
        failing.failAdds = true
        let b = await scheduler(failing).reconcile(workspace: workspace([item(1, due: date(26, 15))]), settings: on, now: date(25, 10))
        XCTAssertEqual(b.scheduledCount, 0); XCTAssertTrue(b.systemRefused)
    }

    func testReconcileIsIdempotentAndFollowsEveryLedgerChange() async {
        let center = FakeParentingNotificationCenter(status: .authorized)
        let reminders = scheduler(center)
        let original = item(1, due: date(26, 15))
        _ = await reminders.reconcile(workspace: workspace([original]), settings: on, now: date(25, 10))
        _ = await reminders.reconcile(workspace: workspace([original]), settings: on, now: date(25, 10))
        XCTAssertEqual(center.addCount, 1, "Unchanged plan must not re-add")
        // Rescheduled: same identifier, new fire time and text.
        var moved = original; moved.dueAt = date(26, 17)
        let status = await reminders.reconcile(workspace: workspace([moved]), settings: on, now: date(25, 10))
        XCTAssertEqual(center.addCount, 2)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(status.outcomes[original.id], .scheduled(date(26, 16)))
        // Cancelled and completed: the pending reminder is removed.
        var cancelled = original; cancelled.state = .cancelled
        let afterCancel = await reminders.reconcile(workspace: workspace([cancelled]), settings: on, now: date(25, 10))
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(afterCancel.scheduledCount, 0)
        // Deleted from the ledger altogether.
        _ = await reminders.reconcile(workspace: workspace([original]), settings: on, now: date(25, 10))
        XCTAssertEqual(center.requests.count, 1)
        _ = await reminders.reconcile(workspace: workspace([]), settings: on, now: date(25, 10))
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testRemindersRememberedAcrossSyncsAndForgottenWhenNoLongerPlanned() async {
        let center = FakeParentingNotificationCenter(status: .authorized)
        let memory = InMemoryReminderMemory()
        let reminders = ParentingReminderScheduler(center: center, subjectID: subject, calendar: calendar, copy: reminderCopy, memory: memory, isCurrentAccount: { true })
        let one = item(1, due: date(26, 15))
        let first = await reminders.reconcile(workspace: workspace([one]), settings: on, now: date(25, 10))
        XCTAssertEqual(first.outcomes[one.id], .scheduled(date(26, 14)))
        XCTAssertEqual(memory.load(), [one.id: date(26, 14)])
        // The system delivered it (nothing pending any more), the app opens at 14:20.
        await center.remove(ids: center.requests.map(\.id))
        let later = await reminders.reconcile(workspace: workspace([one]), settings: on, now: date(26, 14, 20))
        XCTAssertEqual(later.outcomes[one.id], .reminded(date(26, 14)))
        XCTAssertEqual(later.scheduledCount, 0)
        XCTAssertEqual(center.addCount, 1, "A reminder that already went off is never scheduled again")
        // Once the arrangement is no longer planned, the memory is dropped.
        var done = one; done.state = .completed
        _ = await reminders.reconcile(workspace: workspace([done]), settings: on, now: date(26, 14, 30))
        XCTAssertTrue(memory.load().isEmpty)
    }

    func testOffDeniedAndUndeterminedScheduleNothingAndNeverPrompt() async {
        let seeded = item(1, due: date(26, 15))
        // Off removes what exists.
        let center = FakeParentingNotificationCenter(status: .authorized)
        let reminders = scheduler(center)
        _ = await reminders.reconcile(workspace: workspace([seeded]), settings: on, now: date(25, 10))
        XCTAssertEqual(center.requests.count, 1)
        let off = await reminders.reconcile(workspace: workspace([seeded]), settings: .default, now: date(25, 10))
        XCTAssertTrue(center.requests.isEmpty); XCTAssertEqual(off.scheduledCount, 0)
        // Denied.
        let denied = FakeParentingNotificationCenter(status: .denied)
        let deniedStatus = await scheduler(denied).reconcile(workspace: workspace([seeded]), settings: on, now: date(25, 10))
        XCTAssertEqual(denied.addCount, 0); XCTAssertEqual(deniedStatus.authorization, .denied); XCTAssertEqual(deniedStatus.scheduledCount, 0)
        // Not determined: reconcile alone never prompts.
        let fresh = FakeParentingNotificationCenter(status: .notDetermined)
        let freshStatus = await scheduler(fresh).reconcile(workspace: workspace([seeded]), settings: on, now: date(25, 10))
        XCTAssertEqual(fresh.authorizationRequests, 0); XCTAssertEqual(fresh.addCount, 0); XCTAssertEqual(freshStatus.authorization, .notDetermined)
        // An explicit request does prompt, once.
        let result = await scheduler(fresh).requestAuthorization()
        XCTAssertEqual(result, .authorized); XCTAssertEqual(fresh.authorizationRequests, 1)
    }

    func testHideContentKeepsChildNameAndTitleOffTheLockScreen() async throws {
        let center = FakeParentingNotificationCenter(status: .authorized)
        var hidden = on; hidden.hideContent = true
        _ = await scheduler(center).reconcile(workspace: workspace([item(1, due: date(26, 15), title: "合成私密事项")]), settings: hidden, now: date(25, 10))
        let request = try XCTUnwrap(center.requests.first)
        XCTAssertFalse(request.body.contains("合成小星")); XCTAssertFalse(request.body.contains("合成私密事项"))
        XCTAssertFalse(request.title.contains("合成小星"))
    }

    func testQuietHourMoveIsExplainedInTheReminderText() async throws {
        let center = FakeParentingNotificationCenter(status: .authorized)
        let status = await scheduler(center).reconcile(workspace: workspace([item(1, due: date(26, 7, 30))]), settings: on, now: date(25, 10))
        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.fireAt, date(25, 20, 30))
        XCTAssertTrue(request.body.contains("为避开夜间安静时段"))
        XCTAssertEqual(status.scheduledCount, 1)
    }

    func testAccountThatIsNoLongerCurrentNeverWritesAndLeavesNothingBehind() async {
        let center = FakeParentingNotificationCenter(status: .authorized)
        let status = await scheduler(center, current: { false }).reconcile(workspace: workspace([item(1, due: date(26, 15))]), settings: on, now: date(25, 10))
        XCTAssertEqual(center.addCount, 0); XCTAssertEqual(status.scheduledCount, 0)
        // Account lost while the plan is being written: whatever was added is removed again.
        let flag = AccountFlag()
        let center2 = FakeParentingNotificationCenter(status: .authorized)
        center2.onAdd = { flag.value = false }
        let racing = scheduler(center2, current: { flag.value })
        let raced = await racing.reconcile(workspace: workspace([item(1, due: date(26, 15))]), settings: on, now: date(25, 10))
        XCTAssertGreaterThanOrEqual(center2.addCount, 1)
        XCTAssertTrue(center2.requests.isEmpty, "Nothing of a signed-out account may stay queued")
        XCTAssertEqual(raced.scheduledCount, 0)
        await racing.clear()
        XCTAssertTrue(center2.requests.isEmpty)
    }

    func testOtherAccountsAndForeignNotificationsAreNeverTouched() async {
        let center = FakeParentingNotificationCenter(status: .authorized)
        let other = ParentingNotificationRequest(id: ParentingReminderPayload.identifier(subject: UUID(), arrangement: UUID()), title: "t", body: "b", fireAt: date(26, 9), userInfo: [:])
        center.seed(other)
        let reminders = scheduler(center)
        _ = await reminders.reconcile(workspace: workspace([item(1, due: date(26, 15))]), settings: on, now: date(25, 10))
        _ = await reminders.reconcile(workspace: workspace([]), settings: on, now: date(25, 10))
        await reminders.clear()
        XCTAssertEqual(center.requests.map(\.id), [other.id])
    }

    func testSettingsPersistPerAccountAndStartOff() {
        let suite = UserDefaults(suiteName: "parenting-reminder-" + UUID().uuidString)!
        let a = ParentingReminderSettingsStore(defaults: suite, subjectID: subject)
        XCTAssertEqual(a.load(), .default)
        XCTAssertFalse(a.load().enabled)
        a.save(.init(enabled: true, lead: .eveningBefore, hideContent: true))
        XCTAssertEqual(a.load(), .init(enabled: true, lead: .eveningBefore, hideContent: true))
        XCTAssertEqual(ParentingReminderSettingsStore(defaults: suite, subjectID: UUID()).load(), .default)
        a.erase()
        XCTAssertEqual(a.load(), .default)
    }
}

private final class InMemoryReminderMemory: ParentingReminderMemory, @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UUID: Date] = [:]
    func load() -> [UUID: Date] { lock.withLock { value } }
    func save(_ value: [UUID: Date]) { lock.withLock { self.value = value } }
}

private final class AccountFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

#if canImport(Combine)
/// The real model, real encrypted-ledger store (synthetic cipher) and the real scheduler over a fake system centre.
final class ParentingReminderModelTests: XCTestCase {
    private let subject = UUID(uuidString: "D2000000-0000-4000-8000-000000000001")!
    private let childID = UUID(uuidString: "C2000000-0000-4000-8000-000000000001")!
    private let itemID = UUID(uuidString: "C3000000-0000-4000-8000-000000000001")!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }()
    private let reminderCopy = ParentingReminderCopy { key, arguments in
        arguments.enumerated().reduce(key) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element) }
    }

    @MainActor private func make(center: FakeParentingNotificationCenter, now: Date) throws -> ParentingWorkspaceModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-reminder-model-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let scope = AuthenticatedLocalPartition(issuer: "https://parenting-reminder.invalid", subject: subject, serverScopeID: stableID("parenting-reminder-scope")).scope
        let epoch = AccountEpoch(account: subject.uuidString)
        let repository = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("local.json")))
        let store = ParentingWorkspaceStore(repository: repository, scope: scope, subjectID: subject, epoch: epoch, cipher: ParentingTestCipher(), clock: { now })
        let scheduler = ParentingReminderScheduler(center: center, subjectID: subject, calendar: calendar, copy: reminderCopy, isCurrentAccount: { epoch.isValid(epoch.capture()) })
        let defaults = UserDefaults(suiteName: "parenting-reminder-model-" + UUID().uuidString)!
        return ParentingWorkspaceModel(store: store, reminders: scheduler,
                                       reminderSettingsStore: ParentingReminderSettingsStore(defaults: defaults, subjectID: subject), clock: { now })
    }

    @MainActor func testLedgerChangesDriveReminderQueueAndEraseCancelsThem() async throws {
        // Fixed mid-morning "now" with a due time next afternoon, so the one-hour lead is always in daytime.
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let due = calendar.date(byAdding: .day, value: 1, to: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!)!
        let center = FakeParentingNotificationCenter(status: .notDetermined)
        let model = try make(center: center, now: now)
        await model.load()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.reminderStatus?.authorization, .notDetermined)
        let child = await model.apply(.addChild(id: childID, name: "合成小星"))
        XCTAssertTrue(child)
        let created = await model.apply(.createDraft(id: itemID, childID: childID, title: "合成绘本时间", dueAt: due, goalID: nil, sourceText: "合成原话"))
        XCTAssertTrue(created)
        XCTAssertTrue(center.requests.isEmpty, "Reminders are off until the parent turns them on")
        await model.setReminders(enabled: true)
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(model.reminderSettings.enabled)
        XCTAssertTrue(center.requests.isEmpty, "A draft is not confirmed, so it has no reminder")
        let confirmed = await model.apply(.confirmArrangement(id: itemID))
        XCTAssertTrue(confirmed)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(model.reminderStatus?.scheduledCount, 1)
        let cancelled = await model.apply(.cancelArrangement(id: itemID))
        XCTAssertTrue(cancelled)
        XCTAssertTrue(center.requests.isEmpty)
        // Erase everything: ledger empty and queue empty.
        let again = await model.apply(.createDraft(id: UUID(), childID: childID, title: "合成第二件", dueAt: due, goalID: nil, sourceText: ""))
        XCTAssertTrue(again)
        let erased = await model.apply(.deleteAllRecords)
        XCTAssertTrue(erased)
        XCTAssertTrue(model.workspace.children.isEmpty)
        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor func testDeniedPermissionIsReportedAndDoesNotBlockSavingTheLedger() async throws {
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let center = FakeParentingNotificationCenter(status: .notDetermined, grantOnRequest: false)
        let model = try make(center: center, now: now)
        await model.load()
        await model.setReminders(enabled: true)
        XCTAssertEqual(model.reminderStatus?.authorization, .denied)
        let saved = await model.apply(.addChild(id: childID, name: "合成小星"))
        XCTAssertTrue(saved, "A saved change never fails because reminders are unavailable")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.reminderStatus?.scheduledCount, 0)
        XCTAssertEqual(center.addCount, 0)
    }
}
#endif
