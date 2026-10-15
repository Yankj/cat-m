import XCTest
import CryptoKit

/// Compare native geometry at floating-point precision, never with a point-sized
/// allowance. CGRect origin/extent arithmetic can return 43.99999999999994 for 44.
enum NativeUIGeometry {
    static func heightMeetsMinimum(_ frame:CGRect,minimum:CGFloat=44)->Bool {
        guard frame.minY.isFinite,frame.maxY.isFinite,frame.height.isFinite else {return false}
        let magnitude=max(1,abs(frame.minY),abs(frame.maxY),abs(minimum))
        return frame.height>=minimum || minimum-frame.height<=magnitude*CGFloat.ulpOfOne*8
    }
    static func assertMinimumHeight(_ frame:CGRect,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertTrue(heightMeetsMinimum(frame),"Minimum touch height is 44pt; actual \(frame.height)pt",file:file,line:line)
    }
}

/// Scroll the currently owned viewport, never a picker/context behind a sheet.
/// Hold at the drag endpoint to stop inertia; short corrections derive from the
/// observed target distance rather than repeatedly jumping a whole screen.
enum NativeUIScrollReveal {
    static func reveal(_ app:XCUIApplication,_ element:XCUIElement,file:StaticString=#filePath,line:UInt=#line) {
        for _ in 0..<15 {
            let photosCancel=app.buttons["Cancel"]
            guard !photosCancel.exists else {XCTFail("Close the actual PhotosPicker before interacting with another viewport.\n"+app.debugDescription,file:file,line:line);return}
            let details=app.scrollViews["chat.input.context.scroll"]
            let reader=app.scrollViews["chat.artifact.reader.viewport"]
            let scroll=details.exists ? details : reader.exists ? reader : app.scrollViews["chat.transcript"]
            XCTAssertTrue(scroll.exists,app.debugDescription,file:file,line:line)
            let frame=scroll.frame.intersection(app.frame)
            let navigationBottom=app.navigationBars.allElementsBoundByIndex.filter{$0.isHittable}.map{$0.frame.maxY}.max() ?? frame.minY
            let top=max(frame.minY,navigationBottom)+8
            var bottom=min(frame.maxY,app.frame.maxY-20)
            if !details.exists && !reader.exists {
                let composer=app.descendants(matching:.any).matching(identifier:"chat.composer").firstMatch
                XCTAssertTrue(composer.exists,app.debugDescription,file:file,line:line)
                bottom=min(bottom,composer.frame.minY-8)
            }
            if app.keyboards.firstMatch.exists {bottom=min(bottom,app.keyboards.firstMatch.frame.minY-8)}
            guard bottom-top>44 else {XCTFail("The current viewport must leave a reachable reading area.\n"+app.debugDescription,file:file,line:line);return}
            let exists=element.exists,rect=exists ? element.frame:.zero
            let visible=exists ? min(rect.maxY,bottom)-max(rect.minY,top):0
            if exists,element.isHittable,visible>=min(44,rect.height) {return}
            let center=(top+bottom)/2,down = !exists || rect.midY<center
            let distance=min(bottom-top-20,max(12,exists ? abs(rect.midY-center)*0.65:bottom-top-20))
            let start=down ? top+10:bottom-10,end=start+(down ? distance:-distance)
            let x=frame.minX+min(14,frame.width/10)
            app.coordinate(withNormalizedOffset:.init(dx:x/app.frame.width,dy:start/app.frame.height))
                .press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:.init(dx:x/app.frame.width,dy:end/app.frame.height)),withVelocity:.slow,thenHoldForDuration:0.2)
        }
        XCTFail("Target did not become reachable inside its actual viewport.\n"+app.debugDescription,file:file,line:line)
    }
}

/// Actual host UI with the existing explicitly offline fixture. No model execution is simulated here.
final class ConversationArtifactContinuationUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let raw=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any] ?? [:]
    }
    private func wait(_ predicate:()->Bool,file:StaticString=#filePath,line:UInt=#line) {
        let end=Date().addingTimeInterval(15)
        while Date()<end {if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        XCTFail("Offline target input condition timed out",file:file,line:line)
    }
    private func ready(_ app:XCUIApplication) {
        XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12),app.debugDescription)
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:6),app.debugDescription)
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline")
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
    }
    private func reveal(_ app:XCUIApplication,_ element:XCUIElement) {
        NativeUIScrollReveal.reveal(app,element)
    }
    private func openArtifact(_ app:XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            app.buttons["sidebar.open"].tap();let close=app.buttons["sidebar.close"]
            XCTAssertTrue(close.waitForExistence(timeout:5),app.debugDescription);close.tap();wait({!app.keyboards.firstMatch.exists})
        }
        let open=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.artifact.open.")).firstMatch
        if !open.exists {let card=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Synthetic sourced report")).firstMatch;reveal(app,card);card.tap()}
        XCTAssertTrue(open.waitForExistence(timeout:5),app.debugDescription);reveal(app,open);open.tap()
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.version"].waitForExistence(timeout:5),app.debugDescription)
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v2")
    }
    private func select(_ app:XCUIApplication,_ mode:String) {
        let action=app.buttons["chat.artifact.reader."+mode]
        XCTAssertTrue(action.waitForExistence(timeout:5),app.debugDescription);reveal(app,action);action.tap()
        XCTAssertTrue(app.staticTexts["chat.artifact.continuation.target"].waitForExistence(timeout:6),app.debugDescription)
        XCTAssertEqual(app.staticTexts["chat.artifact.continuation.target"].label,"Synthetic sourced report · v2")
    }
    private func capture(_ app:XCUIApplication,_ suffix:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="Simulator-synthetic-report-continuation-v21-"+suffix;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func readRestriction(_ app:XCUIApplication) {
        let inline=app.staticTexts["chat.artifact.continuation.blocked"]
        if inline.exists && inline.isHittable {XCTAssertFalse(inline.label.isEmpty);return}
        let open=app.buttons["chat.input.context.open"]
        XCTAssertTrue(open.exists && open.isHittable,"A clipped restriction must have a reachable full-details entry")
        NativeUIGeometry.assertMinimumHeight(open.frame);open.tap()
        XCTAssertTrue(app.staticTexts["chat.input.context.version"].waitForExistence(timeout:5),app.debugDescription)
        XCTAssertEqual(app.staticTexts["chat.input.context.version"].label,"v2")
        let blocked=app.staticTexts["chat.input.context.blocked"]
        XCTAssertTrue(blocked.exists,app.debugDescription);reveal(app,blocked)
        XCTAssertTrue(blocked.isHittable);XCTAssertFalse(blocked.label.isEmpty,"Read the actual source/admission restriction")
        app.buttons["chat.input.context.close"].tap();wait({!app.staticTexts["chat.input.context.version"].exists})
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
    }
    private func leaveTarget(_ app:XCUIApplication) {
        let inline=app.buttons["chat.artifact.continuation.leave"]
        if inline.exists && inline.isHittable {
            NativeUIGeometry.assertMinimumHeight(inline.frame)
            if app.keyboards.firstMatch.exists {XCTAssertLessThanOrEqual(inline.frame.maxY,app.keyboards.firstMatch.frame.minY)}
            inline.tap()
        } else {
            let open=app.buttons["chat.input.context.open"]
            XCTAssertTrue(open.exists && open.isHittable,"Compact target keeps an explicit version/details route")
            XCTAssertTrue(open.label.contains("v2"));NativeUIGeometry.assertMinimumHeight(open.frame);open.tap()
            XCTAssertTrue(app.staticTexts["chat.input.context.version"].waitForExistence(timeout:5));XCTAssertEqual(app.staticTexts["chat.input.context.version"].label,"v2")
            let leave=app.buttons["chat.input.context.leave"];reveal(app,leave)
            XCTAssertTrue(leave.isHittable && leave.isEnabled);NativeUIGeometry.assertMinimumHeight(leave.frame);leave.tap()
            wait({!app.staticTexts["chat.input.context.version"].exists})
        }
        wait({!app.staticTexts["chat.artifact.continuation.target"].exists})
    }
    private func runDraftPath(_ scenario:String) {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        if scenario.hasPrefix("p0-ui-large") || scenario=="p0-ui-genui-large" {app.launchEnvironment["CATPAW_UI_TEST_TEXT_SIZE"]="accessibility5"}
        app.launch();ready(app)
        let input=app.textViews["chat.input"];input.tap();input.typeText("Synthetic report for local target selection");app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String=="completed"})
        input.tap();input.typeText("Ordinary draft kept apart")
        let ordinary=input.value as? String ?? "",hash=SHA256.hash(data:Data(ordinary.utf8)).map{String(format:"%02x",$0)}.joined()
        wait({self.probe(app)["draft_hash"] as? String==hash})
        openArtifact(app);select(app,"revise")
        readRestriction(app)
        input.tap();input.typeText("Revise conclusion two; keep exact selected version.\nDRAFT-END")
        let raw=input.value as? String ?? "";XCTAssertTrue(raw.contains("DRAFT-END"));XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let leave=app.buttons["chat.artifact.continuation.leave"]
        if leave.exists && leave.isHittable {
            XCTAssertTrue(leave.isEnabled);NativeUIGeometry.assertMinimumHeight(leave.frame)
            XCTAssertLessThanOrEqual(leave.frame.maxY,app.keyboards.firstMatch.frame.minY)
        } else {
            let details=app.buttons["chat.input.context.open"]
            XCTAssertTrue(details.exists && details.isHittable && details.isEnabled);XCTAssertTrue(details.label.contains("v2"))
            NativeUIGeometry.assertMinimumHeight(details.frame);XCTAssertLessThanOrEqual(details.frame.maxY,app.keyboards.firstMatch.frame.minY)
        }
        let assistant=app.descendants(matching:.any).matching(identifier:"SystemInputAssistantView").firstMatch
        let keyboardTop=assistant.exists ? min(assistant.frame.minY,app.keyboards.firstMatch.frame.minY) : app.keyboards.firstMatch.frame.minY
        NativeUIGeometry.assertMinimumHeight(app.buttons["chat.send"].frame)
        XCTAssertLessThanOrEqual(app.buttons["chat.send"].frame.maxY,keyboardTop,"The send control remains fully above the predictive-input bar")
        XCTAssertLessThanOrEqual(input.frame.maxY,keyboardTop,"The actual editor remains above all keyboard input views")
        let geometry=XCTAttachment(string:"version=0.3.0(21);reality=offline_synthetic_simulator\ninput=\(input.frame)\nsend=\(app.buttons["chat.send"].frame)\nleave=\(leave.frame)\nkeyboard_top=\(keyboardTop)")
        geometry.name="Simulator-synthetic-v21-selected-input-geometry";geometry.lifetime = .keepAlways;add(geometry)
        capture(app,scenario+"-selected-local-raw")
        if scenario=="p0-ui-large-artifact-edit" {
            let details=app.buttons["chat.input.context.open"]
            XCTAssertTrue(details.exists && details.isHittable,"Overflowing context has an explicit, reachable details entry. exists=\(details.exists), hittable=\(details.isHittable), enabled=\(details.isEnabled), frame=\(details.frame). \(app.debugDescription)")
            NativeUIGeometry.assertMinimumHeight(details.frame)
            details.tap()
            let version=app.staticTexts["chat.input.context.version"]
            XCTAssertTrue(version.waitForExistence(timeout:5),app.debugDescription);XCTAssertEqual(version.label,"v2")
            let blocked=app.staticTexts["chat.input.context.blocked"]
            XCTAssertTrue(blocked.exists,app.debugDescription);reveal(app,blocked)
            XCTAssertTrue(blocked.isHittable,"The full source/admission restriction remains readable in the details sheet")
            app.buttons["chat.input.context.close"].tap();wait({!version.exists})
            XCTAssertEqual(app.textViews["chat.input"].value as? String,raw,"Explicitly reading details preserves the exact draft")
            XCTAssertFalse(app.buttons["chat.send"].isEnabled)
            XCTAssertEqual(probe(app)["artifact_posts"] as? Int,0)
        }
        leaveTarget(app)
        XCTAssertEqual(input.value as? String,ordinary)
        openArtifact(app);select(app,"explain")
        XCTAssertFalse((input.value as? String ?? "").contains("DRAFT-END"),"Read-only question has its own draft")
        input.tap();input.typeText("Why this exact report version?")
        let question=input.value as? String ?? ""
        leaveTarget(app)
        XCTAssertEqual(input.value as? String,ordinary)
        openArtifact(app);select(app,"revise");XCTAssertEqual(input.value as? String,raw)
        app.terminate();app.launch();ready(app)
        XCTAssertTrue(app.staticTexts["chat.artifact.continuation.target"].waitForExistence(timeout:5),app.debugDescription)
        XCTAssertEqual(app.textViews["chat.input"].value as? String,raw,"Cold host restores selected version and unsubmitted raw")
        XCTAssertEqual(app.staticTexts["chat.artifact.continuation.target"].label,"Synthetic sourced report · v2")
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        XCTAssertEqual(probe(app)["artifact_posts"] as? Int,0)
        capture(app,scenario+"-cold-selected-version")
        leaveTarget(app)
        XCTAssertEqual(app.textViews["chat.input"].value as? String,ordinary)
        openArtifact(app);select(app,"explain");XCTAssertEqual(app.textViews["chat.input"].value as? String,question)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0);XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        capture(app,scenario+"-independent-question-draft")
    }
    func testTouchHeightComparisonIgnoresOnlyMachineRoundoff() {
        XCTAssertTrue(NativeUIGeometry.heightMeetsMinimum(CGRect(x:0,y:400,width:44,height:44)))
        XCTAssertTrue(NativeUIGeometry.heightMeetsMinimum(CGRect(x:0,y:400,width:44,height:43.99999999999994)))
        XCTAssertFalse(NativeUIGeometry.heightMeetsMinimum(CGRect(x:0,y:400,width:44,height:43.9999)))
        XCTAssertFalse(NativeUIGeometry.heightMeetsMinimum(CGRect(x:0,y:400,width:44,height:43)))
    }
    func testSelectedVersionModesColdDraftsAndExitKeepOrdinaryInputWithoutSending() {runDraftPath("p0-ui-artifact-edit")}
    func testMaximumTextTargetInputAndExitRemainReachableAboveKeyboard() {runDraftPath("p0-ui-large-artifact-edit")}
}
