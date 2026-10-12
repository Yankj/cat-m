import XCTest
final class QAFeedbackUITests: XCTestCase {
    func testFrozenViewKeepsPreparingAndQueuedTextDuringHeldConsent() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        XCTAssertTrue(app.staticTexts["qa.fixture"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["qa.fixture"].label,"injected_synthetic_offline; external_network_enabled=false")
        let input=app.textFields["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:5));input.tap();input.typeText("Synthetic queued QA")
        app.buttons["chat.send"].tap()
        let preparing=app.staticTexts["chat.preparing"]
        XCTAssertTrue(preparing.waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Synthetic queued QA"].exists)
        Thread.sleep(forTimeInterval:2)
        XCTAssertTrue(preparing.exists);XCTAssertTrue(app.staticTexts["Synthetic queued QA"].exists)
        XCTAssertFalse(app.staticTexts["chat.assistantMessage"].exists)
        let evidence=XCTAttachment(screenshot:app.screenshot());evidence.name="held-consent-synthetic-frozen-view";evidence.lifetime = .keepAlways;add(evidence)
        // Presence sampled after XCTest tap is functional evidence, never a 100ms measurement.
        app.terminate()
    }
}
