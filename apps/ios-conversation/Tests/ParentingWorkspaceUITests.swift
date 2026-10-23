import XCTest

/// Real host UI, SwiftData repository, AES parenting store and inline intake controller.
/// Only the consent/reply/deletion transport is injected. No probes or controller calls replace UI actions.
final class ParentingWorkspaceUITests: XCTestCase {
    private var currentApp: XCUIApplication?
    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if testRun?.hasSucceeded == false, let app = currentApp { capture(app, "failure") }
        currentApp?.terminate()
        currentApp = nil
        super.tearDown()
    }

    func testSyntheticParentingJourneyPersistsAcrossColdRelaunch() {
        let app = launch("p0-ui-parenting-success")
        let child = "Synthetic Child"
        let goal = "Synthetic shared reading goal"
        let source = "Read a short story together and ask which page was interesting."
        let note = "Synthetic parent observed a question about the story."
        assertEmpty(app)
        capture(app, "success-empty")
        addChild(app, name: child)
        tab(app, "growth")
        tap(app, app.buttons["parenting.addGoal"])
        enter(app, id: "parenting.goal.title", text: goal)
        tap(app, app.buttons["parenting.name.save"])
        wait { !self.inputExists(app, "parenting.goal.title") }
        let goalButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.goal.")).firstMatch
        reveal(app, goalButton)
        let goalIdentifier = goalButton.identifier
        XCTAssertNotNil(UUID(uuidString: String(goalIdentifier.dropFirst("parenting.goal.".count))))
        capture(app, "success-created-child-and-goal")

        tab(app, "today")
        tap(app, app.buttons["parenting.addArrangement"])
        tap(app, element(app, "parenting.editor.goal"))
        let option = app.buttons.matching(NSPredicate(format: "label == %@", goal)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
        enter(app, id: "parenting.arrangement.source", text: source)
        requestAndAllow(app)
        let candidate = element(app, "parenting.inline.candidate")
        reveal(app, candidate)
        XCTAssertTrue(candidate.exists, app.debugDescription)
        XCTAssertFalse(input(app, "parenting.arrangement.title").value as? String == "Synthetic reading together",
                       "A candidate must not apply itself to the arrangement.")
        assertSaveDisabled(app)
        reveal(app, candidate)
        capture(app, "success-candidate-not-saved")
        tap(app, app.buttons["parenting.inline.adopt"])
        let title = input(app, "parenting.arrangement.title")
        reveal(app, title)
        XCTAssertEqual(title.value as? String, "Synthetic reading together")
        assertSaveDisabled(app)
        reveal(app, title)
        title.tap()
        title.typeText(" parent-reviewed")
        let reviewedTitle = title.value as? String ?? ""
        XCTAssertTrue(reviewedTitle.contains("parent-reviewed"))
        chooseExplicitTime(app)
        tap(app, app.buttons["parenting.arrangement.save"])
        wait { !self.inputExists(app, "parenting.arrangement.source") }
        let confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.confirm.")).firstMatch
        reveal(app, confirm)
        let arrangementID = String(confirm.identifier.dropFirst("parenting.confirm.".count))
        XCTAssertNotNil(UUID(uuidString: arrangementID))
        XCTAssertTrue(app.staticTexts[reviewedTitle].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["parenting.complete." + arrangementID].exists)
        capture(app, "success-draft-awaiting-explicit-confirmation")
        tap(app, confirm)
        let complete = app.buttons["parenting.complete." + arrangementID]
        wait { complete.exists && complete.isEnabled }
        XCTAssertFalse(app.buttons["parenting.confirm." + arrangementID].exists)
        tap(app, app.buttons["parenting.adjust." + arrangementID])
        let adjusted = input(app, "parenting.arrangement.title")
        reveal(app, adjusted)
        XCTAssertEqual(adjusted.value as? String, reviewedTitle)
        adjusted.tap()
        adjusted.typeText(" adjusted")
        let adjustedTitle = adjusted.value as? String ?? ""
        XCTAssertTrue(adjustedTitle.contains("adjusted"))
        chooseExplicitTime(app)
        tap(app, app.buttons["parenting.arrangement.save"])
        wait { !self.inputExists(app, "parenting.arrangement.title") }
        reveal(app, complete)
        XCTAssertTrue(app.staticTexts[adjustedTitle].exists, app.debugDescription)
        capture(app, "success-today-confirmed-and-adjusted")
        tap(app, complete)
        enter(app, id: "parenting.record.text", text: note)
        tap(app, app.buttons["parenting.record.save"])
        wait { !self.inputExists(app, "parenting.record.text") }
        XCTAssertFalse(app.buttons["parenting.complete." + arrangementID].exists)

        tab(app, "records")
        let recordBody = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).firstMatch
        reveal(app, recordBody)
        XCTAssertEqual(recordBody.label, note)
        let recordID = String(recordBody.identifier.dropFirst("parenting.record.body.".count))
        XCTAssertNotNil(UUID(uuidString: recordID))
        assertRecordGoal(app, recordID: recordID, goal: goal)
        capture(app, "success-completion-record-and-goal-link")
        tab(app, "growth")
        tap(app, app.buttons[goalIdentifier])
        XCTAssertTrue(app.staticTexts["Reviewing this goal"].exists, app.debugDescription)
        let linkedBody = app.staticTexts["parenting.record.body." + recordID]
        reveal(app, linkedBody)
        XCTAssertEqual(linkedBody.label, note, "The same saved record must appear inside the selected goal review.")
        assertRecordGoal(app, recordID: recordID, goal: goal)
        capture(app, "success-selected-goal-review")

        // The exact UUID, scope and subject are retained. Fixture make() never resets or seeds this store.
        app.terminate()
        app.launch()
        ready(app)
        XCTAssertFalse(app.buttons["parenting.firstChild"].exists)
        tab(app, "records")
        let reopenedBody = app.staticTexts["parenting.record.body." + recordID]
        reveal(app, reopenedBody)
        XCTAssertEqual(reopenedBody.label, note)
        assertRecordGoal(app, recordID: recordID, goal: goal)
        tab(app, "growth")
        XCTAssertTrue(app.staticTexts[child].exists, app.debugDescription)
        tap(app, app.buttons[goalIdentifier])
        reveal(app, app.staticTexts["parenting.record.body." + recordID])
        XCTAssertEqual(app.staticTexts["parenting.record.body." + recordID].label, note)
        capture(app, "success-cold-relaunch-real-ledger-restored")
    }

    func testSyntheticPreparationFailureCancelCleanupAndNewIntake() {
        let app = launch("p0-ui-parenting-preparation-failure")
        assertEmpty(app)
        addChild(app, name: "Synthetic Failure Child")
        tap(app, app.buttons["parenting.addArrangement"])
        let source = "Synthetic input retained after preparation was refused."
        enter(app, id: "parenting.arrangement.source", text: source)
        tap(app, app.buttons["parenting.arrangement.aiIntake"])
        let issue = app.staticTexts.matching(identifier: "parenting.form.error").firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(element(app, "parenting.inline.candidate").exists)
        XCTAssertFalse(app.buttons["chat.modelConsent.allow"].exists)
        XCTAssertEqual(input(app, "parenting.arrangement.source").value as? String, source)
        assertSaveDisabled(app)
        capture(app, "failure-preparation-refused-source-retained")
        closeUnsavedArrangement(app)
        assertNoArrangement(app)
        tap(app, app.buttons["parenting.addArrangement"])
        let pending = element(app, "parenting.inline.cleanupPending")
        reveal(app, pending)
        XCTAssertTrue(pending.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["parenting.arrangement.aiIntake"].isEnabled)
        capture(app, "failure-reopened-cleanup-pending")
        tap(app, app.buttons["parenting.inline.retryCleanup"])
        wait { !pending.exists }
        enter(app, id: "parenting.arrangement.source", text: "Synthetic new request after explicit cleanup.")
        requestAndAllow(app)
        tap(app, app.buttons["parenting.inline.adopt"])
        XCTAssertEqual(input(app, "parenting.arrangement.title").value as? String, "Synthetic reading together")
        assertSaveDisabled(app)
        capture(app, "failure-new-request-explicitly-adopted-not-saved")
        closeUnsavedArrangement(app)
        assertNoArrangement(app)
        capture(app, "failure-cancel-created-no-arrangement")
    }

    func testSyntheticDarkLargeTextEmptyAndEditorSmoke() {
        let app = launch("p0-ui-parenting-success", display: [
            "CATPAW_UI_TEST_TEXT_SIZE": "accessibility5",
            "CATPAW_PARENTING_UI_COLOR_SCHEME": "dark"
        ])
        assertEmpty(app)
        capture(app, "dark-accessibility5-empty")
        addChild(app, name: "Synthetic Large Text Child")
        tap(app, app.buttons["parenting.addArrangement"])
        enter(app, id: "parenting.arrangement.source", text: "Synthetic large text form remains editable and can be discarded.")
        assertSaveDisabled(app)
        capture(app, "dark-accessibility5-real-editor")
        closeUnsavedArrangement(app)
        assertNoArrangement(app)
        capture(app, "dark-accessibility5-discarded-no-draft")
    }

    private func launch(_ scenario: String, display: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM.ConversationFirst.Auth")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": scenario]
        for (key, value) in display { app.launchEnvironment[key] = value }
        currentApp = app
        app.launch()
        ready(app)
        return app
    }
    private func ready(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["parenting.fixture.identity"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(element(app, "parenting.fixture.error").exists, app.debugDescription)
        wait { app.buttons["parenting.tab.today"].exists && !self.element(app, "parenting.loadState").exists }
        XCTAssertFalse(app.textViews["chat.input"].exists, "A normal launch must lead to the actual parenting workspace.")
    }
    private func assertEmpty(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["parenting.firstChild"].exists, app.debugDescription)
        assertNoArrangement(app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.goal.")).count, 0)
    }
    private func assertNoArrangement(_ app: XCUIApplication) {
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.arrangement.")).count, 0,
                       "Closing an unsaved form must not create a draft or a confirmed arrangement.")
    }
    private func addChild(_ app: XCUIApplication, name: String) {
        tap(app, app.buttons["parenting.firstChild"])
        enter(app, id: "parenting.child.name", text: name)
        tap(app, app.buttons["parenting.name.save"])
        wait { !self.inputExists(app, "parenting.child.name") }
        XCTAssertTrue(app.buttons["parenting.addArrangement"].exists, app.debugDescription)
    }
    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons["parenting.tab." + name]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
        // The tabs share one real ScrollView. Return it to the header before locating a new section.
        for _ in 0..<3 { drag(app, towardBottom: false) }
    }
    private func requestAndAllow(_ app: XCUIApplication) {
        tap(app, app.buttons["parenting.arrangement.aiIntake"])
        let allow = app.buttons["chat.modelConsent.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(app.staticTexts["chat.modelConsent.title"].label, "Synthetic parenting UI consent")
        wait { allow.isEnabled }
        allow.tap()
        reveal(app, app.buttons["parenting.inline.adopt"])
        XCTAssertTrue(app.buttons["parenting.inline.adopt"].exists, app.debugDescription)
    }
    private func chooseExplicitTime(_ app: XCUIApplication) {
        tap(app, app.buttons["parenting.arrangement.time"])
        XCTAssertTrue(element(app, "parenting.timePicker").waitForExistence(timeout: 5), app.debugDescription)
        // This explicit native confirmation adopts the currently displayed date/time; nil AI time remains nil until this tap.
        tap(app, app.buttons["parenting.time.confirm"])
        wait { !app.buttons["parenting.time.confirm"].exists }
        reveal(app, app.buttons["parenting.arrangement.save"])
        wait { app.buttons["parenting.arrangement.save"].isEnabled }
    }
    private func assertSaveDisabled(_ app: XCUIApplication) {
        let save = app.buttons["parenting.arrangement.save"]
        reveal(app, save)
        XCTAssertTrue(save.exists, app.debugDescription)
        XCTAssertFalse(save.isEnabled, "An unreviewed or timeless candidate cannot become a saved arrangement.")
    }
    private func closeUnsavedArrangement(_ app: XCUIApplication) {
        tap(app, app.buttons["parenting.arrangement.cancel"])
        let discardID = app.alerts.buttons["parenting.arrangement.discard"]
        let discard = discardID.exists ? discardID : app.alerts.buttons["Discard and close"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        discard.tap()
        wait { !self.inputExists(app, "parenting.arrangement.source") }
    }
    private func assertRecordGoal(_ app: XCUIApplication, recordID: String, goal: String) {
        let label = element(app, "parenting.record.goal." + recordID)
        reveal(app, label)
        XCTAssertTrue(label.label.contains(goal), app.debugDescription)
    }
    private func inputExists(_ app: XCUIApplication, _ id: String) -> Bool {
        app.textViews[id].exists || app.textFields[id].exists
    }
    private func input(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        // Form can virtualize a field outside the current viewport. Source/name fields live above the intake section.
        if !inputExists(app, id), ["parenting.arrangement.source", "parenting.child.name", "parenting.goal.title"].contains(id) {
            for _ in 0..<3 { drag(app, towardBottom: false) }
        }
        reveal(app, element(app, id))
        wait { self.inputExists(app, id) }
        return app.textViews[id].exists ? app.textViews[id] : app.textFields[id]
    }
    private func enter(_ app: XCUIApplication, id: String, text: String) {
        let field = input(app, id)
        reveal(app, field)
        field.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, app.debugDescription)
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tap(_ app: XCUIApplication, _ target: XCUIElement) {
        reveal(app, target)
        wait { target.exists && target.isEnabled && target.isHittable }
        target.tap()
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Synthetic native UI condition timed out", file: file, line: line)
    }
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<16 {
            let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame }
            let top = bars.map { $0.maxY }.max() ?? app.frame.minY + 90
            let keyboard = app.keyboards.firstMatch
            let tabTop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.tab.")).allElementsBoundByIndex
                .filter { $0.isHittable }.map { $0.frame.minY }.min() ?? app.frame.maxY - 20
            let bottom = min(tabTop, keyboard.exists ? keyboard.frame.minY : app.frame.maxY - 20) - 5
            if target.exists && target.isHittable {
                let rect = target.frame
                let inToolbar = bars.contains { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
                if inToolbar || (rect.midY > top + 4 && rect.midY < bottom) { return }
            }
            let above = target.exists && target.frame.midY < top + 20
            drag(app, towardBottom: !above)
        }
        XCTFail("Synthetic native UI target is unreachable: \(target.identifier)\n" + app.debugDescription, file: file, line: line)
    }
    private func drag(_ app: XCUIApplication, towardBottom: Bool) {
        let frame = app.frame
        let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? frame.minY + 90
        let top = max(frame.minY + 90, navigationBottom) + 18
        let tabTop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.tab.")).allElementsBoundByIndex
            .filter { $0.isHittable }.map { $0.frame.minY }.min() ?? frame.maxY - 24
        let keyboard = app.keyboards.firstMatch
        let bottom = min(tabTop - 12, keyboard.exists ? keyboard.frame.minY - 12 : frame.maxY - 30)
        guard bottom - top > 80 else { return }
        let x = frame.minX + 14
        let startY = towardBottom ? bottom - 10 : top + 10
        let endY = towardBottom ? top + 10 : bottom - 10
        let start = app.coordinate(withNormalizedOffset: .init(dx: x / frame.width, dy: startY / frame.height))
        let end = app.coordinate(withNormalizedOffset: .init(dx: x / frame.width, dy: endY / frame.height))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func capture(_ app: XCUIApplication, _ stage: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Synthetic-Parenting-M1-" + stage
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
