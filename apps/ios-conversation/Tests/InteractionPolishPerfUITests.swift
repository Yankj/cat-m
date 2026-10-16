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
    /// Best-effort visual evidence; the Simulator runner can write to the host /tmp.
    private func shot(_ name: String) {
        let dir = URL(fileURLWithPath: "/tmp/interaction-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }
    private func idle(_ seconds: TimeInterval = 1.2) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// Interactive dismissal: drag from the transcript down into the keyboard.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let o = app.coordinate(withNormalizedOffset: .zero), h = app.frame.height, w = app.frame.width
        o.withOffset(CGVector(dx: w * 0.5, dy: h * 0.35)).press(forDuration: 0.05, thenDragTo: o.withOffset(CGVector(dx: w * 0.5, dy: h * 0.97)), withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    private func transcript0(_ app: XCUIApplication) -> XCUIElement { app.scrollViews["chat.transcript"] }
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
        input.tap(); idle(1.2); shot("empty-keyboard")
        dismissKeyboard(app); idle(1.0)

        phase("send")
        for i in 0..<4 {
            if app.keyboards.count == 0 { input.tap() }; input.typeText("测量第\(i)条消息 interaction polish")
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
            _ = app.staticTexts["chat.reply.completed"].waitForExistence(timeout: 12)
            idle(1.5)
        }

        shot("after-send")
        if app.keyboards.count == 0 { input.tap() }; idle(1.2); shot("keyboard-up")
        dismissKeyboard(app); idle(1.0)
        phase("keyboard")
        let transcript = app.scrollViews["chat.transcript"]
        for _ in 0..<4 {
            if app.keyboards.count == 0 { input.tap() }; idle(1.0)
            dismissKeyboard(app); idle(1.0)
        }
        // Clear any edit callout; a presented callout legitimately blocks the drawer pan.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap(); idle(0.6)

        phase("drawer")
        let w = app.frame.width, h = app.frame.height
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 {
            let a = origin.withOffset(CGVector(dx: 12, dy: h * 0.5)), b = origin.withOffset(CGVector(dx: w * 0.75, dy: h * 0.5))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.1); idle(1.0); shot("drawer-open")
            print("DRAWER_OPEN \(app.buttons["sidebar.scrim"].exists) keyboard=\(app.keyboards.count)")
            let c = origin.withOffset(CGVector(dx: w * 0.95, dy: h * 0.5)), d = origin.withOffset(CGVector(dx: w * 0.1, dy: h * 0.5))
            c.press(forDuration: 0.05, thenDragTo: d, withVelocity: .fast, thenHoldForDuration: 0.0); idle(1.0)
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
