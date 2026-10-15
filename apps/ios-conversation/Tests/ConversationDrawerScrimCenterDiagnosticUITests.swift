import Foundation
import UIKit
import XCTest

/// Independent physical hit diagnostic; does not replace the strict
/// ConversationDrawerRevealUITests scrim AX/isHittable acceptance assertions.
/// Synthetic P0 echo; no cloud/Auth/model calls. No continuous-motion claim.
final class ConversationDrawerScrimCenterDiagnosticUITests:XCTestCase {
    private let bundleID="com.example.CatpawM.ConversationFirst.Auth"
    private let question="Synthetic drawer reading check"
    private let reply="Synthetic offline reply; no model call."
    override func setUp(){continueAfterFailure=false}

    private func until(_ condition:()->Bool,seconds:TimeInterval=8)->Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {
            if condition(){return true}
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        }
        return condition()
    }
    private func reader(_ app:XCUIApplication)->XCUIElement {
        app.descendants(matching:.any).matching(identifier:"chat.assistantMessage").firstMatch
    }
    private func userEchoCount(_ app:XCUIApplication)->Int {
        app.descendants(matching:.any).matching(identifier:"chat.userMessage").count
    }
    private func record(_ app:XCUIApplication,_ phase:String,extra:String="") {
        let scrim=app.buttons["sidebar.scrim"],close=app.buttons["sidebar.close"]
        let exists=scrim.exists
        let frame=exists ? scrim.frame:.null
        let visible=frame.intersection(app.frame)
        let input=app.textViews["chat.input"]
        let text="purpose=diagnostic_absolute_visible_center_not_AX_acceptance\nreality=explicit_in_process_synthetic;scenario=p0-ui-echo;visual_overlay=hidden\nphase=\(phase)\napp=\(app.frame)\nscrim_exists=\(exists)\nscrim_enabled=\(exists ? String(scrim.isEnabled):"not_present")\nscrim_hittable=\(exists ? String(scrim.isHittable):"not_present")\nscrim_AX_frame=\(frame)\nscrim_visible_intersection=\(visible)\nclose_exists=\(close.exists)\ninput_value=\(input.exists ? String(describing:input.value):"not_present")\nuser_echo_count=\(userEchoCount(app))\n\(extra)\nlimit=diagnostic only; PASS cannot replace strict AX/isHittable or real-model acceptance"
        let facts=XCTAttachment(string:text);facts.name="Drawer-scrim-center-diagnostic-"+phase;facts.lifetime = .keepAlways;add(facts)
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Drawer-scrim-center-diagnostic-"+phase;image.lifetime = .keepAlways;add(image)
        let hierarchy=XCTAttachment(string:app.debugDescription);hierarchy.name="Drawer-scrim-center-hierarchy-"+phase;hierarchy.lifetime = .keepAlways;add(hierarchy)
    }
    func testDiagnosticAbsoluteVisibleScrimCenterAfterReadOnlyBodyPan() {
        let app=XCUIApplication(bundleIdentifier:bundleID)
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-echo","CATPAW_QA_VISUAL_REVIEW":"1"]
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let input=app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:12),app.debugDescription)
        XCTAssertFalse(app.staticTexts["qa.p0Fixture"].exists)
        let new=app.buttons["chat.new"]
        XCTAssertTrue(new.waitForExistence(timeout:5));XCTAssertTrue(new.isEnabled && new.isHittable);new.tap()
        XCTAssertTrue(until{input.exists && (input.value as? String)==""},app.debugDescription)
        input.tap();input.typeText(question)
        let send=app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled && send.isHittable);send.tap() // The sole Send press.
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].waitForExistence(timeout:12),app.debugDescription)
        XCTAssertTrue(until{self.reader(app).exists && self.reader(app).label==self.reply},app.debugDescription)
        let draft="诊断点击遮罩后保留中文草稿"
        input.tap();input.typeText(draft);XCTAssertEqual(input.value as? String,draft)
        let echoes=userEchoCount(app);XCTAssertGreaterThan(echoes,0)
        let body=reader(app),transcript=app.scrollViews["chat.transcript"]
        XCTAssertTrue(body.exists && body.isHittable);XCTAssertTrue(transcript.exists)
        let bodyVisible=body.frame.intersection(transcript.frame).intersection(app.frame)
        XCTAssertGreaterThan(bodyVisible.width,100);XCTAssertGreaterThan(bodyVisible.height,12)
        let start=CGPoint(x:bodyVisible.minX+bodyVisible.width*0.4,y:bodyVisible.midY)
        XCTAssertGreaterThan(start.x,app.frame.minX+44,"Start inside the actual read-only body, beyond the edge-only zone")
        let appOrigin=app.coordinate(withNormalizedOffset:.zero)
        appOrigin.withOffset(CGVector(dx:start.x-app.frame.minX,dy:start.y-app.frame.minY))
            .press(forDuration:0.05,thenDragTo:appOrigin.withOffset(CGVector(dx:app.frame.width-12,dy:start.y-app.frame.minY)),withVelocity:.slow,thenHoldForDuration:0.2)
        let scrim=app.buttons["sidebar.scrim"],close=app.buttons["sidebar.close"]
        let opened=until{scrim.exists && close.exists}
        record(app,"before-absolute-center-tap",extra:"opened_by_body_pan=\(opened)")
        // No scrim isEnabled/isHittable or activation-point assertion here:
        // those values remain recorded above and are enforced by the old test.
        XCTAssertTrue(opened,"Need an actual open drawer and scrim frame to diagnose. "+app.debugDescription)
        let frame=scrim.frame,visible=frame.intersection(app.frame)
        guard !visible.isNull && !visible.isInfinite && visible.width>0 && visible.height>0,
              visible.midX.isFinite && visible.midY.isFinite else {
            XCTFail("No finite visible scrim center; no coordinate tap performed.");return
        }
        let point=CGPoint(x:visible.midX,y:visible.midY)
        // App-absolute coordinate tap deliberately bypasses scrim.tap() and
        // scrim.coordinate(...), which can depend on XCTest activation-point.
        appOrigin.withOffset(CGVector(dx:point.x-app.frame.minX,dy:point.y-app.frame.minY)).tap()
        let closed=until{!close.exists && !app.buttons["sidebar.scrim"].exists && input.exists && input.isHittable}
        record(app,"after-absolute-center-tap",extra:"absolute_tap_point=\(point)\nclosed_endpoint=\(closed)\ndraft_exact=\((input.value as? String)==draft)")
        XCTAssertTrue(closed,"Absolute visible-center touch must actually close the drawer; AX-only diagnosis is insufficient. "+app.debugDescription)
        XCTAssertEqual(input.value as? String,draft)
        XCTAssertEqual(userEchoCount(app),echoes,"No second user turn without another Send press")
        XCTAssertEqual(reader(app).label,reply)
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"chat.assistantMessage").count,1)
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].exists)
    }
}
