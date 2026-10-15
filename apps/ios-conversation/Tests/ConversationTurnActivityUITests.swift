import Foundation
import XCTest

/// Actual native interaction over two controlled transcript tool events.
/// The fixture remains pending: no grow trigger, HTTP, model, or task execution.
final class ConversationTurnActivityUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let raw=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any] ?? [:]
    }
    private func until(_ condition:@escaping ()->Bool,seconds:TimeInterval=8,file:StaticString=#filePath,line:UInt=#line) {
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in condition()},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:seconds),.completed,"Expected native semantic state did not arrive",file:file,line:line)
    }
    private func replaceAll(_ app:XCUIApplication,_ input:XCUIElement,with text:String) {
        XCTAssertTrue(input.isHittable);input.tap()
        if !(input.value as? String ?? "").isEmpty {
            input.press(forDuration:1.1)
            let all=app.menuItems.matching(NSPredicate(format:"label IN %@",["全选","Select All"])).firstMatch
            XCTAssertTrue(all.waitForExistence(timeout:3),app.debugDescription);all.tap()
            input.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue:text)
        } else if !text.isEmpty {input.typeText(text)}
        XCTAssertEqual(input.value as? String,text)
    }
    private func revealSummary(_ app:XCUIApplication,_ summary:XCUIElement,file:StaticString=#filePath,line:UInt=#line) {
        let scroll=app.scrollViews["chat.transcript"],composer=app.descendants(matching:.any).matching(identifier:"chat.composer").firstMatch
        for _ in 0..<8 {
            let frame=scroll.frame.intersection(app.frame),top=max(frame.minY,app.navigationBars.firstMatch.frame.maxY)+8
            var bottom=min(frame.maxY,composer.frame.minY-8)
            if app.keyboards.firstMatch.exists {bottom=min(bottom,app.keyboards.firstMatch.frame.minY-8)}
            guard bottom-top>60 else {XCTFail("A visible transcript strip is required",file:file,line:line);return}
            if summary.exists,summary.isHittable {
                let visible=summary.frame.intersection(CGRect(x:frame.minX,y:top,width:frame.width,height:bottom-top))
                if NativeUIGeometry.heightMeetsMinimum(visible) {return}
            }
            // The summary is above this fixture's long body. Drag content down
            // toward the beginning, even while LazyVStack has no AX row for it.
            let x=frame.minX+14
            app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:top+16))
                .press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:bottom-16)),withVelocity:.slow,thenHoldForDuration:0.2)
        }
        capture(app,"Native-process-summary-reveal-failure")
        XCTFail("Summary did not become visibly reachable after eight bounded earlier-page drags. "+app.debugDescription,file:file,line:line)
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)
    }
    func testTwoPendingToolFactsShareOneTurnSummaryAndEditingDraftDoesNotSendAgain()throws {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-reading-growth"]
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline")
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        let input=app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:5))
        // The initial saved draft is cleared through the editor, not a new chat.
        replaceAll(app,input,with:"")
        let original="Synthetic process grouping"
        input.typeText(original);XCTAssertEqual(input.value as? String,original)
        let send=app.buttons["chat.send"];XCTAssertTrue(send.isEnabled && send.isHittable);send.tap()
        until({self.probe(app)["synthetic_reply_calls"] as? Int == 1 && self.probe(app)["turn_state"] as? String == "running"})
        // Release the editor through ordinary navigation before scrolling a
        // long transcript; the test never presses the toolbar under the HUD.
        app.buttons["sidebar.open"].tap()
        let close=app.buttons["sidebar.close"];XCTAssertTrue(close.waitForExistence(timeout:5));close.tap()
        until({!app.keyboards.firstMatch.exists})
        let turn=try XCTUnwrap(probe(app)["turn_id"] as? String)
        XCTAssertNotNil(UUID(uuidString:turn))
        let toggles=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.activity.toggle."))
        let toggle=app.buttons["chat.activity.toggle."+turn]
        // A long real transcript may virtualize its summary above the viewport.
        // Reveal its actual native hit area before inspecting or tapping it.
        revealSummary(app,toggle)
        XCTAssertTrue(toggle.exists && toggle.isHittable);NativeUIGeometry.assertMinimumHeight(toggle.frame)
        XCTAssertEqual(toggles.count,1,"Two calls in one turn must not produce two process headers")
        XCTAssertEqual(toggle.label,"正在处理请求…")
        let facts=app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.activity.tool."))
        XCTAssertEqual(facts.count,0,"Facts start collapsed")
        capture(app,"Native-single-turn-process-collapsed")
        toggle.tap()
        until({facts.count==2})
        let factIDs=facts.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(Set(factIDs).count,2)
        for id in factIDs {
            let fact=app.descendants(matching:.any).matching(identifier:id).firstMatch
            NativeUIScrollReveal.reveal(app,fact)
            XCTAssertTrue(fact.isHittable,"The actual expanded fact must be visible")
            XCTAssertTrue(fact.label.contains("准备交互内容"),fact.label)
            XCTAssertTrue(fact.label.contains("等待工具回执"),fact.label)
            XCTAssertFalse(fact.label.contains("{}"),"Raw tool arguments must not be presented")
            XCTAssertNil(fact.label.range(of:"[0-9]+(?:\\.[0-9]+)?\\s*(?:秒|seconds?|s)\\b",options:.regularExpression),"No invented elapsed fact")
        }
        XCTAssertFalse(app.staticTexts["Synthetic upper result"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic lower result"].exists)
        capture(app,"Native-single-turn-process-two-pending-facts")
        revealSummary(app,toggle);XCTAssertTrue(toggle.isHittable);toggle.tap()
        until({facts.count==0})
        XCTAssertTrue(toggle.exists);XCTAssertEqual(toggles.count,1);XCTAssertEqual(toggle.label,"正在处理请求…")
        let draft="Local draft remains unsent"
        replaceAll(app,input,with:draft)
        XCTAssertEqual(input.value as? String,draft)
        XCTAssertEqual(probe(app)["turn_id"] as? String,turn)
        XCTAssertEqual(probe(app)["turn_state"] as? String,"running")
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1,"Expanding and typing must not send again")
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        capture(app,"Native-process-collapsed-and-unsent-draft")
    }
}
