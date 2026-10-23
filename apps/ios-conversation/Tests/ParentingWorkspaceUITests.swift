import XCTest

/// Real host UI, SwiftData repository, AES parenting store and inline intake controller.
/// Only the consent/reply/deletion transport is injected. No probes or controller calls replace UI actions.
final class ParentingWorkspaceUITests: XCTestCase {
    private var currentApp: XCUIApplication?
    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if let app = currentApp {
            capture(app, "end-of-case")
            if (testRun?.totalFailureCount ?? 0) > 0 {
                print("Synthetic parenting UI failure hierarchy:\n" + app.debugDescription)
            }
        }
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
        openGoalEditor(app)
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
        let reviewedTitle = (title.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let confirmedTime = arrangementTime(app, arrangementID: arrangementID)
        XCTAssertFalse(confirmedTime.isEmpty)
        XCTAssertTrue(complete.exists, "The original draft must now expose its planned-state completion action.")
        capture(app, "success-original-arrangement-confirmed-with-visible-time")
        tap(app, app.buttons["parenting.adjust." + arrangementID])
        let adjusted = input(app, "parenting.arrangement.title")
        reveal(app, adjusted)
        XCTAssertEqual(adjusted.value as? String, reviewedTitle)
        adjusted.tap()
        adjusted.typeText(" adjusted")
        let adjustedTitle = (adjusted.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(adjustedTitle.contains("adjusted"))
        chooseExplicitTime(app)
        tap(app, app.buttons["parenting.arrangement.save"])
        wait { !self.inputExists(app, "parenting.arrangement.title") }
        reveal(app, complete)
        XCTAssertTrue(app.staticTexts[adjustedTitle].exists, app.debugDescription)
        let adjustedTime = arrangementTime(app, arrangementID: arrangementID)
        XCTAssertFalse(adjustedTime.isEmpty)
        capture(app, "success-today-confirmed-and-adjusted")
        tap(app, complete)
        enter(app, id: "parenting.record.text", text: note)
        assertPinnedAction(app, id: "parenting.record.save")
        tap(app, app.buttons["parenting.record.save"])
        wait { !self.inputExists(app, "parenting.record.text") }
        XCTAssertFalse(app.buttons["parenting.complete." + arrangementID].exists)
        let completedCard = showCompletedArrangement(app, arrangementID: arrangementID)
        XCTAssertTrue(completedCard.staticTexts[adjustedTitle].exists, app.debugDescription)
        XCTAssertEqual(arrangementTime(app, arrangementID: arrangementID), adjustedTime,
                       "Marking complete must retain the original arrangement's time.")
        let completedState = element(app, "parenting.arrangement.completed." + arrangementID)
        reveal(app, completedState)
        let completedStateLabel = completedState.label
        XCTAssertFalse(completedStateLabel.isEmpty)
        assertArrangementGoal(app, arrangementID: arrangementID, goal: goal)
        let completionLink = completedCard.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.completionRecord.")).firstMatch
        reveal(app, completionLink)
        let linkedRecordID = String(completionLink.identifier.dropFirst("parenting.completionRecord.".count))
        XCTAssertNotNil(UUID(uuidString: linkedRecordID))
        capture(app, "success-original-arrangement-completed-time-and-record-link")

        tab(app, "records")
        let recordBody = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).firstMatch
        reveal(app, recordBody)
        XCTAssertEqual(recordBody.label, note)
        let recordID = String(recordBody.identifier.dropFirst("parenting.record.body.".count))
        XCTAssertNotNil(UUID(uuidString: recordID))
        XCTAssertEqual(recordID, linkedRecordID, "The record list must show the exact record linked by the completed arrangement.")
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
        let reopenedArrangement = showCompletedArrangement(app, arrangementID: arrangementID)
        XCTAssertTrue(reopenedArrangement.staticTexts[adjustedTitle].exists, app.debugDescription)
        XCTAssertEqual(arrangementTime(app, arrangementID: arrangementID), adjustedTime,
                       "Cold reopening must retain the visible time of the same saved arrangement UUID.")
        let reopenedState = element(app, "parenting.arrangement.completed." + arrangementID)
        reveal(app, reopenedState)
        XCTAssertEqual(reopenedState.label, completedStateLabel)
        XCTAssertFalse(app.buttons["parenting.confirm." + arrangementID].exists)
        XCTAssertFalse(app.buttons["parenting.complete." + arrangementID].exists)
        XCTAssertFalse(app.buttons["parenting.adjust." + arrangementID].exists)
        assertArrangementGoal(app, arrangementID: arrangementID, goal: goal)
        let reopenedLink = reopenedArrangement.buttons["parenting.completionRecord." + recordID]
        tap(app, reopenedLink)
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

    func testSyntheticSelectedArrangementRescheduleAndUndoPersistAcrossColdRelaunch() {
        let app = launch("p0-ui-parenting-adjustment")
        let child = "Synthetic Reschedule Child"
        let goal = "Synthetic retained growth goal"
        let title = "Synthetic original arrangement"
        let originalSource = "Synthetic original request remains the arrangement source."
        let changeSource = "Change to 2027-02-18T17:00:00Z."
        assertEmpty(app)
        addChild(app, name: child)
        tab(app, "growth")
        openGoalEditor(app)
        enter(app, id: "parenting.goal.title", text: goal)
        tap(app, app.buttons["parenting.name.save"])
        wait { !self.inputExists(app, "parenting.goal.title") }
        tab(app, "today")
        tap(app, app.buttons["parenting.addArrangement"])
        tap(app, element(app, "parenting.editor.goal"))
        let goalOption = app.buttons.matching(NSPredicate(format: "label == %@", goal)).firstMatch
        XCTAssertTrue(goalOption.waitForExistence(timeout: 5), app.debugDescription)
        goalOption.tap()
        enter(app, id: "parenting.arrangement.source", text: originalSource)
        enter(app, id: "parenting.arrangement.title", text: title)
        chooseExplicitTime(app)
        tap(app, app.buttons["parenting.arrangement.save"])
        wait { !self.inputExists(app, "parenting.arrangement.source") }
        let confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.confirm.")).firstMatch
        reveal(app, confirm)
        let arrangementID = String(confirm.identifier.dropFirst("parenting.confirm.".count))
        XCTAssertNotNil(UUID(uuidString: arrangementID))
        tap(app, confirm)
        wait { app.buttons["parenting.complete." + arrangementID].exists }
        let originalTime = arrangementTime(app, arrangementID: arrangementID)
        assertArrangementGoal(app, arrangementID: arrangementID, goal: goal)

        tap(app, app.buttons["parenting.adjust." + arrangementID])
        XCTAssertEqual(input(app, "parenting.arrangement.source").value as? String, "",
                       "A change must not silently resend the arrangement's original source.")
        enter(app, id: "parenting.arrangement.source", text: changeSource)
        requestAndAllow(app)
        let before = app.staticTexts["parenting.adjustment.originalTime"]
        let after = app.staticTexts["parenting.adjustment.proposedTime"]
        reveal(app, before)
        XCTAssertFalse(before.label.isEmpty, app.debugDescription)
        reveal(app, after)
        XCTAssertFalse(after.label.isEmpty, app.debugDescription)
        XCTAssertNotEqual(before.label, after.label)
        XCTAssertEqual(input(app, "parenting.arrangement.title").value as? String, title,
                       "A reschedule candidate must preserve the selected title, not use the model's replacement title.")
        assertSaveDisabled(app)
        capture(app, "adjustment-candidate-not-applied")
        tap(app, app.buttons["parenting.inline.adopt"])
        let review = element(app, "parenting.adjustment.review")
        reveal(app, review)
        XCTAssertTrue(review.exists, app.debugDescription)
        assertPinnedAction(app, id: "parenting.arrangement.save")
        tap(app, app.buttons["parenting.arrangement.save"])
        wait { !self.inputExists(app, "parenting.arrangement.source") }
        let changedTime = arrangementTime(app, arrangementID: arrangementID)
        XCTAssertNotEqual(changedTime, originalTime)
        XCTAssertTrue(element(app, "parenting.arrangement." + arrangementID).staticTexts[title].exists, app.debugDescription)
        assertArrangementGoal(app, arrangementID: arrangementID, goal: goal)

        app.terminate()
        app.launch()
        ready(app)
        XCTAssertEqual(arrangementTime(app, arrangementID: arrangementID), changedTime)
        XCTAssertTrue(element(app, "parenting.arrangement." + arrangementID).staticTexts[title].exists, app.debugDescription)
        assertArrangementGoal(app, arrangementID: arrangementID, goal: goal)
        tapDisclosure(app, id: "parenting.adjustmentHistory." + arrangementID)
        let source = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.adjustment.source.")).firstMatch
        reveal(app, source)
        XCTAssertEqual(source.label, changeSource)
        let editID = String(source.identifier.dropFirst("parenting.adjustment.source.".count))
        XCTAssertNotNil(UUID(uuidString: editID))
        capture(app, "adjustment-same-id-and-source-cold-read")
        tap(app, app.buttons["parenting.arrangement.menu." + arrangementID])
        let undo = app.buttons.matching(identifier: "parenting.undoAdjustment." + arrangementID).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        wait { undo.isEnabled && undo.isHittable }
        undo.tap()
        wait { app.staticTexts["parenting.arrangement.time." + arrangementID].label == originalTime }
        XCTAssertTrue(app.buttons["parenting.complete." + arrangementID].exists)

        app.terminate()
        app.launch()
        ready(app)
        XCTAssertEqual(arrangementTime(app, arrangementID: arrangementID), originalTime)
        XCTAssertTrue(element(app, "parenting.arrangement." + arrangementID).staticTexts[title].exists, app.debugDescription)
        assertArrangementGoal(app, arrangementID: arrangementID, goal: goal)
        tapDisclosure(app, id: "parenting.adjustmentHistory." + arrangementID)
        let persistedSource = app.staticTexts["parenting.adjustment.source." + editID]
        reveal(app, persistedSource)
        XCTAssertEqual(persistedSource.label, changeSource)
        let reverted = element(app, "parenting.adjustment.reverted." + editID)
        reveal(app, reverted)
        XCTAssertFalse(reverted.label.isEmpty, app.debugDescription)
        capture(app, "adjustment-undone-same-id-time-and-history-cold-read")
        tab(app, "records")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).count, 0,
                       "Rescheduling and undo must not manufacture a completion record.")
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
        let isolatedStore = app.launchEnvironment["CF_UI_TEST_STORE"]
        XCTAssertNotNil(isolatedStore)
        app.terminate()
        // Remove only the next process's injected one-shot refusal; never replace its scope, subject or stored bytes.
        app.launchEnvironment["CF_UI_TEST_SCENARIO"] = "p0-ui-parenting-success"
        XCTAssertEqual(app.launchEnvironment["CF_UI_TEST_STORE"], isolatedStore)
        app.launch()
        ready(app)
        XCTAssertFalse(app.buttons["parenting.firstChild"].exists)
        assertNoArrangement(app)
        tap(app, app.buttons["parenting.addArrangement"])
        let coldPending = element(app, "parenting.inline.cleanupPending")
        reveal(app, coldPending)
        XCTAssertTrue(coldPending.exists, "The encrypted pending-cleanup reference must survive actual process termination.")
        enter(app, id: "parenting.arrangement.source", text: "Synthetic new request after explicit cleanup.")
        let blockedAI = app.buttons["parenting.arrangement.aiIntake"]
        reveal(app, blockedAI)
        XCTAssertTrue(blockedAI.exists, app.debugDescription)
        XCTAssertFalse(blockedAI.isEnabled, "Pending cleanup must block a new request even with valid new source text.")
        capture(app, "failure-cold-relaunch-pending-blocks-new-request")
        tap(app, app.buttons["parenting.inline.retryCleanup"])
        wait { !coldPending.exists }
        reveal(app, blockedAI)
        wait { blockedAI.isEnabled }
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
        enter(app, id: "parenting.arrangement.source", text: String(repeating: "Synthetic long text remains editable and can be discarded. ", count: 8))
        XCTAssertTrue(app.keyboards.firstMatch.exists, app.debugDescription)
        assertSaveDisabled(app)
        capture(app, "dark-accessibility5-real-editor")
        closeUnsavedArrangement(app)
        assertNoArrangement(app)
        capture(app, "dark-accessibility5-discarded-no-draft")
    }

    func testSyntheticPlannedCancellationPersistsAcrossColdRelaunch() {
        let app = launch("p0-ui-parenting-success")
        let title = "Synthetic arrangement to cancel"
        assertEmpty(app)
        addChild(app, name: "Synthetic Cancellation Child")
        tap(app, app.buttons["parenting.addArrangement"])
        enter(app, id: "parenting.arrangement.source", text: "Synthetic parent intention that can be explicitly cancelled.")
        enter(app, id: "parenting.arrangement.title", text: title)
        chooseExplicitTime(app)
        tap(app, app.buttons["parenting.arrangement.save"])
        wait { !self.inputExists(app, "parenting.arrangement.source") }
        let confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.confirm.")).firstMatch
        reveal(app, confirm)
        let arrangementID = String(confirm.identifier.dropFirst("parenting.confirm.".count))
        XCTAssertNotNil(UUID(uuidString: arrangementID))
        let boundary = element(app, "parenting.storageBoundary")
        reveal(app, boundary)
        XCTAssertTrue(boundary.label.contains("Local arrangements send no reminders"), app.debugDescription)
        capture(app, "cancellation-before-confirmation-no-reminder-disclosure")
        tap(app, confirm)
        let complete = app.buttons["parenting.complete." + arrangementID]
        wait { complete.exists && complete.isEnabled }
        let plannedTime = arrangementTime(app, arrangementID: arrangementID)
        tap(app, app.buttons["parenting.arrangement.menu." + arrangementID])
        chooseMenuAction(app, "Cancel this arrangement")
        wait { !complete.exists }
        let cancelledState = assertCancelledArrangement(app, arrangementID: arrangementID, title: title, time: plannedTime)
        capture(app, "cancellation-original-planned-arrangement-cancelled")
        tab(app, "records")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).count, 0,
                       "Cancelling a saved arrangement must not generate a completion record.")
        app.terminate()
        app.launch()
        ready(app)
        XCTAssertEqual(assertCancelledArrangement(app, arrangementID: arrangementID, title: title, time: plannedTime), cancelledState)
        capture(app, "cancellation-cold-relaunch-same-arrangement-time-and-state")
        tab(app, "records")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).count, 0)
    }

    func testSyntheticIndependentObservationEditDeleteAcrossColdReads() {
        let app = launch("p0-ui-parenting-success")
        let child = "Synthetic Observation Child"
        let goal = "Synthetic everyday observation goal"
        let original = "Synthetic parent noticed a question during a story."
        assertEmpty(app)
        addChild(app, name: child)
        tab(app, "growth")
        openGoalEditor(app)
        enter(app, id: "parenting.goal.title", text: goal)
        tap(app, app.buttons["parenting.name.save"])
        wait { !self.inputExists(app, "parenting.goal.title") }
        let goalButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.goal.")).firstMatch
        reveal(app, goalButton)
        let goalIdentifier = goalButton.identifier
        tap(app, goalButton)
        tap(app, app.buttons["parenting.addObservation.forGoal"])
        enter(app, id: "parenting.record.text", text: original)
        assertPinnedAction(app, id: "parenting.record.save")
        tap(app, app.buttons["parenting.record.save"])
        wait { !self.inputExists(app, "parenting.record.text") }
        let body = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).firstMatch
        reveal(app, body)
        XCTAssertEqual(body.label, original)
        let recordID = String(body.identifier.dropFirst("parenting.record.body.".count))
        XCTAssertNotNil(UUID(uuidString: recordID))
        assertRecordGoal(app, recordID: recordID, goal: goal)
        assertNoArrangement(app)
        capture(app, "observation-independent-created-with-goal-no-arrangement")
        tap(app, app.buttons["parenting.record.menu." + recordID])
        chooseMenuAction(app, "Edit record")
        let editor = input(app, "parenting.record.text")
        XCTAssertEqual(editor.value as? String, original)
        editor.tap()
        editor.typeText(" Corrected after checking.")
        let corrected = (editor.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(corrected != original && corrected.contains("Corrected after checking."))
        assertPinnedAction(app, id: "parenting.record.save")
        tap(app, app.buttons["parenting.record.save"])
        wait { !self.inputExists(app, "parenting.record.text") }
        reveal(app, app.staticTexts["parenting.record.body." + recordID])
        XCTAssertEqual(app.staticTexts["parenting.record.body." + recordID].label, corrected)
        let correctedAt = observationSourceAndEditTime(app, recordID: recordID, original: original)
        capture(app, "observation-corrected-body-original-source-retained")
        app.terminate()
        app.launch()
        ready(app)
        tab(app, "records")
        let reopened = app.staticTexts["parenting.record.body." + recordID]
        reveal(app, reopened)
        XCTAssertEqual(reopened.label, corrected)
        assertRecordGoal(app, recordID: recordID, goal: goal)
        XCTAssertEqual(observationSourceAndEditTime(app, recordID: recordID, original: original), correctedAt)
        assertNoArrangement(app)
        capture(app, "observation-cold-read-same-record-goal-source-and-edit-time")
        tap(app, app.buttons["parenting.record.menu." + recordID])
        chooseMenuAction(app, "Delete record")
        let delete = app.alerts.buttons.matching(NSPredicate(format: "label == %@", "Delete")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        wait { delete.exists && delete.isEnabled && delete.isHittable }
        delete.tap()
        wait { !reopened.exists }
        capture(app, "observation-explicit-delete")
        app.terminate()
        app.launch()
        ready(app)
        tab(app, "records")
        XCTAssertFalse(app.staticTexts["parenting.record.body." + recordID].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.record.body.")).count, 0)
        tab(app, "growth")
        XCTAssertTrue(app.staticTexts[child].exists, app.debugDescription)
        reveal(app, app.buttons[goalIdentifier])
        XCTAssertTrue(app.buttons[goalIdentifier].exists)
        assertNoArrangement(app)
        capture(app, "observation-cold-read-deletion-persists-child-and-goal-retained")
    }

    func testSyntheticSwiftDataRollbackRetainsInputRetriesAndColdReadsOneChild() {
        let app = launch("p0-ui-parenting-save-rollback")
        let name = "Synthetic Rollback Child"
        assertEmpty(app)
        tap(app, app.buttons["parenting.firstChild"])
        enter(app, id: "parenting.child.name", text: name)
        tap(app, app.buttons["parenting.name.save"])
        let issue = element(app, "parenting.form.error")
        wait { issue.exists }
        XCTAssertTrue(issue.label.contains("injected_swiftdata_save_failure"),
                      "Expected the real SwiftData rollback seam, not a substitute save result.\n" + app.debugDescription)
        let nameField = input(app, "parenting.child.name")
        XCTAssertEqual(nameField.value as? String, name)
        let retrySave = app.buttons["parenting.name.save"]
        wait { retrySave.isEnabled }
        capture(app, "save-rollback-error-original-input-retained")
        tap(app, retrySave)
        wait { !self.inputExists(app, "parenting.child.name") }
        XCTAssertFalse(element(app, "parenting.form.error").exists, app.debugDescription)
        XCTAssertTrue(app.buttons["parenting.addArrangement"].exists, app.debugDescription)
        assertNoArrangement(app)
        capture(app, "save-rollback-original-form-retry-succeeded")
        let store = app.launchEnvironment["CF_UI_TEST_STORE"]
        XCTAssertNotNil(store)
        app.terminate()
        // Keep the exact same UUID/scope/subject, but do not arm another first-save failure in the new process.
        app.launchEnvironment["CF_UI_TEST_SCENARIO"] = "p0-ui-parenting-success"
        XCTAssertEqual(app.launchEnvironment["CF_UI_TEST_STORE"], store)
        app.launch()
        ready(app)
        XCTAssertFalse(app.buttons["parenting.firstChild"].exists)
        tap(app, element(app, "parenting.childFilter"))
        let choices = app.buttons.matching(NSPredicate(format: "label == %@", name))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(choices.count, 1, "The real cold-read child picker must contain exactly one child from the failed-then-retried form.")
        choices.firstMatch.tap()
        assertNoArrangement(app)
        capture(app, "save-rollback-cold-read-single-child")
    }

    func testSyntheticUnknownIntakeRequiresOriginalRequestReadback() {
        let app = launch("p0-ui-parenting-unknown-readback")
        let source = "Synthetic story request whose first response is lost after submission."
        assertEmpty(app)
        addChild(app, name: "Synthetic Unknown Child")
        tap(app, app.buttons["parenting.addArrangement"])
        enter(app, id: "parenting.arrangement.source", text: source)
        requestAndAllowConsent(app)
        let reconcile = app.buttons["parenting.inline.reconcile"]
        reveal(app, reconcile)
        wait { reconcile.exists && reconcile.isEnabled }
        XCTAssertFalse(element(app, "parenting.inline.loading").exists)
        XCTAssertFalse(element(app, "parenting.inline.candidate").exists)
        XCTAssertFalse(app.buttons["parenting.inline.adopt"].exists)
        XCTAssertFalse(app.buttons["parenting.arrangement.aiIntake"].exists,
                       "An unknown request must offer original-request readback rather than a new submission.")
        XCTAssertFalse(app.buttons["parenting.inline.retry"].exists)
        XCTAssertFalse(app.buttons["parenting.inline.freshAttempt"].exists)
        XCTAssertEqual(input(app, "parenting.arrangement.source").value as? String, source)
        assertSaveDisabled(app)
        reveal(app, reconcile)
        capture(app, "unknown-original-request-awaits-explicit-readback")
        tap(app, reconcile)
        let adopt = app.buttons["parenting.inline.adopt"]
        reveal(app, adopt)
        XCTAssertTrue(adopt.exists, app.debugDescription)
        XCTAssertTrue(element(app, "parenting.inline.candidate").exists, app.debugDescription)
        // The injected backend rejects mismatched reads and permanently rejects readback after any second reply call.
        // Reaching this real parsed candidate therefore requires only the original cid/op/epoch submission.
        XCTAssertFalse(input(app, "parenting.arrangement.title").value as? String == "Synthetic reading together")
        XCTAssertEqual(input(app, "parenting.arrangement.source").value as? String, source)
        assertSaveDisabled(app)
        reveal(app, adopt)
        capture(app, "unknown-original-readback-candidate-not-applied")
        tap(app, adopt)
        let title = input(app, "parenting.arrangement.title")
        XCTAssertEqual(title.value as? String, "Synthetic reading together")
        title.tap()
        title.typeText(" revised after readback")
        XCTAssertTrue((title.value as? String ?? "").contains("revised after readback"))
        XCTAssertEqual(input(app, "parenting.arrangement.source").value as? String, source)
        assertSaveDisabled(app)
        capture(app, "unknown-explicitly-adopted-editable-review-still-unsaved")
        closeUnsavedArrangement(app)
        assertNoArrangement(app)
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
        wait { !self.inputExists(app, "parenting.child.name") || self.element(app, "parenting.form.error").exists }
        let issue = element(app, "parenting.form.error")
        XCTAssertFalse(issue.exists, "Saving the first child failed: \(issue.exists ? issue.label : "no form error")\n" + app.debugDescription)
        XCTAssertFalse(inputExists(app, "parenting.child.name"), app.debugDescription)
        XCTAssertTrue(app.buttons["parenting.addArrangement"].exists, app.debugDescription)
    }
    private func openGoalEditor(_ app: XCUIApplication) {
        let add = app.buttons["parenting.addGoal"]
        reveal(app, add)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44, "The target must include the full accessible label hit area.\n" + app.debugDescription)
        tap(app, add)
        // A missing sheet is a presentation failure, not a field to find by scrolling the Home screen.
        wait { app.textFields["parenting.goal.title"].exists }
    }
    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons["parenting.tab." + name]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
        // reveal() locates the next target without pulling the refreshable Home past its top edge.
    }
    private func requestAndAllow(_ app: XCUIApplication) {
        requestAndAllowConsent(app)
        reveal(app, app.buttons["parenting.inline.adopt"])
        XCTAssertTrue(app.buttons["parenting.inline.adopt"].exists, app.debugDescription)
    }
    private func requestAndAllowConsent(_ app: XCUIApplication) {
        tap(app, app.buttons["parenting.arrangement.aiIntake"])
        let allow = app.buttons["chat.modelConsent.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(app.staticTexts["chat.modelConsent.title"].label, "Synthetic parenting UI consent")
        wait { allow.isEnabled }
        allow.tap()
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
        assertPinnedAction(app, id: "parenting.arrangement.save")
        reveal(app, save)
        XCTAssertTrue(save.exists, app.debugDescription)
        XCTAssertFalse(save.isEnabled, "An unreviewed or timeless candidate cannot become a saved arrangement.")
    }
    private func assertPinnedAction(_ app: XCUIApplication, id: String) {
        let button = app.navigationBars.buttons[id]
        XCTAssertTrue(button.exists, "The sole save action must remain in the existing navigation bar.\n" + app.debugDescription)
        let rect = button.frame
        XCTAssertFalse(rect.isEmpty, app.debugDescription)
        XCTAssertTrue(app.frame.contains(CGPoint(x: rect.midX, y: rect.midY)), app.debugDescription)
        XCTAssertLessThan(rect.maxY, inputPanelTop(app), "The action must stay above the keyboard and its input accessories.")
    }
    private func closeUnsavedArrangement(_ app: XCUIApplication) {
        tap(app, app.buttons["parenting.arrangement.cancel"])
        let discardID = app.alerts.buttons.matching(identifier: "parenting.arrangement.discard").firstMatch
        let discard = discardID.exists ? discardID : app.alerts.buttons.matching(NSPredicate(format: "label == %@", "Discard and close")).firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        wait { discard.exists && discard.isEnabled && discard.isHittable }
        discard.tap()
        wait { !self.inputExists(app, "parenting.arrangement.source") }
    }
    private func chooseMenuAction(_ app: XCUIApplication, _ label: String) {
        let action = app.buttons[label]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        wait { action.isEnabled && action.isHittable }
        action.tap()
    }
    private func assertCancelledArrangement(_ app: XCUIApplication, arrangementID: String, title: String, time: String) -> String {
        // Each call starts with the actual cancelled-history disclosure collapsed, including after a cold launch.
        tapDisclosure(app, id: "parenting.cancelledHistory")
        let card = element(app, "parenting.arrangement." + arrangementID)
        reveal(app, card)
        XCTAssertTrue(card.exists && card.staticTexts[title].exists, app.debugDescription)
        XCTAssertEqual(arrangementTime(app, arrangementID: arrangementID), time)
        let state = element(app, "parenting.arrangement.cancelled." + arrangementID)
        reveal(app, state)
        XCTAssertFalse(state.label.isEmpty)
        XCTAssertFalse(app.buttons["parenting.confirm." + arrangementID].exists)
        XCTAssertFalse(app.buttons["parenting.complete." + arrangementID].exists)
        XCTAssertFalse(app.buttons["parenting.adjust." + arrangementID].exists)
        XCTAssertEqual(card.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.completionRecord.")).count, 0)
        return state.label
    }
    private func observationSourceAndEditTime(_ app: XCUIApplication, recordID: String, original: String) -> String {
        tapDisclosure(app, id: "parenting.record.provenance." + recordID)
        let source = app.staticTexts["parenting.record.source." + recordID]
        reveal(app, source)
        XCTAssertEqual(source.label, original, "Correcting the visible body must preserve the parent's original observation.")
        let timestamp = app.staticTexts["parenting.record.correctedAt." + recordID]
        reveal(app, timestamp)
        XCTAssertFalse(timestamp.label.isEmpty)
        return timestamp.label
    }
    private func showCompletedArrangement(_ app: XCUIApplication, arrangementID: String) -> XCUIElement {
        // Both calls start from a fresh, collapsed history (after completion, then after a cold launch).
        tapDisclosure(app, id: "parenting.completedHistory")
        let card = element(app, "parenting.arrangement." + arrangementID)
        reveal(app, card)
        XCTAssertTrue(card.exists, "The original arrangement UUID must remain in completed history.")
        XCTAssertTrue(element(app, "parenting.arrangement.completed." + arrangementID).exists)
        return card
    }
    private func tapDisclosure(_ app: XCUIApplication, id: String) {
        let group = element(app, id)
        reveal(app, group)
        // contain produces an Other group around the actual Disclosure button on the current runtime.
        let button = group.elementType == .button ? group : group.buttons.firstMatch
        XCTAssertTrue(button.exists, app.debugDescription)
        tap(app, button)
    }
    private func arrangementTime(_ app: XCUIApplication, arrangementID: String) -> String {
        let time = app.staticTexts["parenting.arrangement.time." + arrangementID]
        reveal(app, time)
        XCTAssertFalse(time.label.isEmpty, app.debugDescription)
        return time.label
    }
    private func assertArrangementGoal(_ app: XCUIApplication, arrangementID: String, goal: String) {
        let label = element(app, "parenting.arrangement.goal." + arrangementID)
        reveal(app, label)
        XCTAssertTrue(label.label.contains(goal), app.debugDescription)
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
        // A virtualized upper field can still exist with a zero frame. Search upward in that case as well.
        let upperField = ["parenting.arrangement.source", "parenting.child.name", "parenting.goal.title"].contains(id)
        // TextEditor and TextField identifiers come from the actual host form; do not scan all AX types.
        let multiline = ["parenting.arrangement.source", "parenting.record.text"].contains(id)
        let field = multiline ? app.textViews.matching(identifier: id).firstMatch : app.textFields.matching(identifier: id).firstMatch
        reveal(app, field, searchTowardBottom: !upperField)
        wait { field.exists }
        return field
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
    private func tap(_ app: XCUIApplication, _ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(app, target, file: file, line: line)
        wait({ target.exists && target.isEnabled && target.isHittable }, file: file, line: line)
        target.tap()
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Synthetic native UI condition timed out\n" + (currentApp?.debugDescription ?? "No active synthetic application"), file: file, line: line)
    }
    /// One iteration's clipping geometry; refresh after every drag and never share between reveal calls.
    private struct ViewportBounds {
        let appFrame: CGRect
        let navigationFrames: [CGRect]
        let tabTop: CGFloat?
        let inputPanelTop: CGFloat
    }
    /// Visibility is separate from tappability: disabled Save and noninteractive groups must remain inspectable.
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, searchTowardBottom: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<16 {
            let navigationFrames = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame }
            var targetFrame: CGRect?
            if target.exists {
                let rect = target.frame
                if !rect.isEmpty {
                    targetFrame = rect
                    if navigationFrames.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }) { return }
                }
            }
            let appFrame = app.frame
            let tabTop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "parenting.tab."))
                .allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.minY }.min()
            let bounds = ViewportBounds(appFrame: appFrame, navigationFrames: navigationFrames,
                                        tabTop: tabTop, inputPanelTop: inputPanelTop(app, appFrame: appFrame))
            let scroll = scrollingElement(app, bounds: bounds)
            let scrollFrame = scroll.frame
            let viewport = visibleScrollFrame(scrollFrame, bounds: bounds)
            if let rect = targetFrame, viewport.contains(CGPoint(x: rect.midX, y: rect.midY)) { return }
            // With no usable geometry, use the field's known direction instead of reversing an unrelated search.
            let towardBottom = targetFrame.map { $0.midY >= viewport.minY } ?? searchTowardBottom
            drag(scroll, frame: scrollFrame, viewport: viewport, towardBottom: towardBottom)
        }
        // Reading identifier/frame on a nonexistent target throws before XCTest can print our useful hierarchy.
        XCTFail("Synthetic native UI target is unreachable\n" + app.debugDescription, file: file, line: line)
    }
    private func scrollingElement(_ app: XCUIApplication, bounds: ViewportBounds) -> XCUIElement {
        let lists = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        if let list = largestUsableScroll(candidates: lists, bounds: bounds) { return list }
        return largestUsableScroll(candidates: app.scrollViews.allElementsBoundByIndex, bounds: bounds) ?? app
    }
    private func largestUsableScroll(candidates: [XCUIElement], bounds: ViewportBounds) -> XCUIElement? {
        var selected: XCUIElement?
        var selectedArea: CGFloat = 0
        var visibleFallback: XCUIElement?
        var fallbackArea: CGFloat = 0
        for candidate in candidates where candidate.exists {
            let rect = visibleScrollFrame(candidate.frame, bounds: bounds)
            let area = rect.width * rect.height
            guard rect.height > 80, rect.width > 80 else { continue }
            if area >= fallbackArea { visibleFallback = candidate; fallbackArea = area }
            if candidate.isHittable && area >= selectedArea { selected = candidate; selectedArea = area }
        }
        // A keyboard can cover the container's hit point while leaving a usable upper viewport.
        return selected ?? visibleFallback
    }
    private func visibleScrollFrame(_ scrollFrame: CGRect, bounds: ViewportBounds) -> CGRect {
        let frame = scrollFrame.intersection(bounds.appFrame)
        let navigationBottom = bounds.navigationFrames.map { $0.maxY }.max() ?? frame.minY
        let top = max(frame.minY, navigationBottom) + 12
        let bottom = min(frame.maxY, bounds.tabTop ?? frame.maxY, bounds.inputPanelTop) - 12
        return CGRect(x: frame.minX + 12, y: top, width: max(0, frame.width - 24), height: max(0, bottom - top))
    }
    private func inputPanelTop(_ app: XCUIApplication, appFrame suppliedFrame: CGRect? = nil) -> CGFloat {
        let appFrame = suppliedFrame ?? app.frame
        let keyboard = app.keyboards.firstMatch
        var top = keyboard.exists ? keyboard.frame.minY : appFrame.maxY
        let accessories = app.otherElements.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "inputView", "SystemInputAssistantView"))
        for accessory in accessories.allElementsBoundByIndex where accessory.exists {
            let rect = accessory.frame.intersection(appFrame)
            if !rect.isEmpty { top = min(top, rect.minY) }
        }
        return top
    }
    private func drag(_ scroll: XCUIElement, frame: CGRect, viewport: CGRect, towardBottom: Bool) {
        guard viewport.height > 80, frame.width > 0, frame.height > 0 else { return }
        // The observed Form cell starts at x20, its TextEditor at x40. Pan inside the cell's padding,
        // outside nested text/calendar scrollers, and away from the bottom safe area and input accessories.
        var x = viewport.minX + viewport.width * 0.05
        let cell = scroll.cells.firstMatch
        if cell.exists, !cell.frame.isEmpty {
            x = min(viewport.maxX - 2, max(viewport.minX + 2, cell.frame.minX + 10))
        }
        let upper = viewport.minY + viewport.height * 0.2
        let lower = viewport.minY + viewport.height * 0.8
        let startY = towardBottom ? lower : upper
        let endY = towardBottom ? upper : lower
        let start = scroll.coordinate(withNormalizedOffset: .init(dx: (x - frame.minX) / frame.width, dy: (startY - frame.minY) / frame.height))
        let end = scroll.coordinate(withNormalizedOffset: .init(dx: (x - frame.minX) / frame.width, dy: (endY - frame.minY) / frame.height))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func capture(_ app: XCUIApplication, _ stage: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Synthetic-Parenting-M1-" + stage
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
