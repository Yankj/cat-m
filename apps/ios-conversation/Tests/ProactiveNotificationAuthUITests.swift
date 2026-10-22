import XCTest

/// PR90g (QA setup, run FIRST, then the host tests without uninstalling): simctl privacy cannot pre-grant notifications,
/// so this launches the host app with `-catRequestNotificationAuth` (debug-only wiring in catApp.init) and taps
/// Allow on the system prompt through springboard. Afterwards `ProactiveEngineHostTests/testRealNotificationCenterOwnerCleanup`
/// can add real pending requests. Fails (never skips) when no prompt and no prior grant can be confirmed.
final class ProactiveNotificationAuthUITests: XCTestCase {
    func testGrantNotificationAuthorizationForHostTests() throws {
        continueAfterFailure = false
        let app = XCUIApplication()                       // TEST_TARGET_NAME = cat
        app.launchArguments += ["-CatpawRequestNotificationAuth"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow", "允许", "Allow Notifications"]
        let deadline = Date().addingTimeInterval(20)
        var tapped = false
        while Date() < deadline, !tapped {
            for label in labels {
                let b = springboard.alerts.buttons[label].exists ? springboard.alerts.buttons[label] : springboard.buttons[label]
                if b.exists { b.tap(); tapped = true; break }
            }
            if !tapped { _ = springboard.alerts.firstMatch.waitForExistence(timeout: 1) }
        }
        if !tapped {
            // No prompt: only fine if it was already granted earlier on this simulator (status is decided once per install).
            let shot = XCTAttachment(screenshot: springboard.screenshot()); shot.name = "no-notification-prompt"; shot.lifetime = .keepAlways; add(shot)
            XCTFail("No notification permission prompt appeared within 20 s (labels tried: \(labels)). If the app was installed fresh, check the -catRequestNotificationAuth wiring; if it was denied before, erase the simulator or reset its privacy settings and run this test again.")
        }
        app.terminate()
    }
}
