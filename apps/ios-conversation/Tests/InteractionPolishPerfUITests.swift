import Foundation
import XCTest

/// Drives launch, send, keyboard, drawer and navigation on the offline echo fixture
/// with CATPAW_FRAME_PROBE=1. Phase boundaries are printed as `PHASE <name> <uptime>`;
/// the app writes frame intervals to Documents/interaction-probe.json. Run by
/// Scripts/measure-interaction.sh, which joins the two into a per-phase report.
final class InteractionPolishPerfUITests: XCTestCase {
    private let bundleID = "com.example.CatpawM.ConversationFirst.Auth"
    override func setUp() { continueAfterFailure = false }
    private func phase(_ name: String) { print("PHASE \(name) \(ProcessInfo.processInfo.systemUptime)") }
    private func idle(_ seconds: TimeInterval = 1.2) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testInteractionFrames() {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": "p0-ui-echo",
                                 "CATPAW_QA_VISUAL_REVIEW": "1", "CATPAW_FRAME_PROBE": "1"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        phase("launch")
        app.launch()
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), app.debugDescription)
        idle(2.5)
        let new = app.buttons["chat.new"]
        if new.waitForExistence(timeout: 5), new.isEnabled { new.tap() }
        idle()

        phase("send")
        for i in 0..<4 {
            input.tap(); input.typeText("测量第\(i)条消息 interaction polish")
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
            _ = app.staticTexts["chat.reply.completed"].waitForExistence(timeout: 12)
            idle(1.5)
        }

        phase("keyboard")
        let transcript = app.scrollViews["chat.transcript"]
        for _ in 0..<4 {
            input.tap(); idle(1.0)
            transcript.swipeDown(velocity: .slow); idle(1.0)
        }

        phase("drawer")
        let w = app.frame.width, h = app.frame.height
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 {
            let a = origin.withOffset(CGVector(dx: 12, dy: h * 0.5)), b = origin.withOffset(CGVector(dx: w * 0.75, dy: h * 0.5))
            a.press(forDuration: 0.02, thenDragTo: b, withVelocity: .default, thenHoldForDuration: 0.05); idle(1.0)
            let c = origin.withOffset(CGVector(dx: w * 0.95, dy: h * 0.5)), d = origin.withOffset(CGVector(dx: w * 0.1, dy: h * 0.5))
            c.press(forDuration: 0.02, thenDragTo: d, withVelocity: .default, thenHoldForDuration: 0.05); idle(1.0)
        }

        phase("navigation")
        for _ in 0..<3 {
            let open = app.buttons["sidebar.open"]
            guard open.waitForExistence(timeout: 3) else { break }
            open.tap(); idle(1.0)
            let settings = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'settings'")).firstMatch
            guard settings.waitForExistence(timeout: 3) else { break }
            settings.tap(); idle(1.2)
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }; idle(1.2)
        }

        phase("press")
        for _ in 0..<4 {
            let bubble = app.otherElements["chat.userMessage"].firstMatch
            if bubble.exists { bubble.press(forDuration: 0.2) }; idle(0.6)
        }
        phase("end")
        idle(1.5)
    }
}
