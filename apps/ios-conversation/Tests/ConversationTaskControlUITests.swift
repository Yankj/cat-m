import XCTest

final class ConversationTaskControlUITests:XCTestCase {
    private var openedTaskID:String?
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        if scenario.hasPrefix("p0-ui-large") || scenario=="p0-ui-genui-large" {app.launchEnvironment["CATPAW_UI_TEST_TEXT_SIZE"]="accessibility5"}
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12));XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:6))
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline");XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false);return app
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {let json=app.staticTexts["qa.p0Probe"].value as? String ?? "{}";return (try? JSONSerialization.jsonObject(with:Data(json.utf8))) as? [String:Any] ?? [:]}
    private func wait(_ body:()->Bool,seconds:TimeInterval=15){let end=Date().addingTimeInterval(seconds);while Date()<end {if body(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))};XCTFail("Named offline task-control condition timed out")}
    private func element(_ app:XCUIApplication,_ prefix:String)->XCUIElement {app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@",prefix)).firstMatch}
    private func reveal(_ app:XCUIApplication,_ value:XCUIElement,conversation:Bool=false,requiresHittable:Bool=true,readable:Bool=false) {
        for _ in 0..<22 {
            let top=max(130,app.navigationBars.firstMatch.frame.maxY+12);var bottom=app.frame.height-36
            if app.keyboards.firstMatch.exists {bottom=min(bottom,app.keyboards.firstMatch.frame.minY-12)}
            if conversation,app.buttons["attachment.pick"].exists {bottom=min(bottom,app.buttons["attachment.pick"].frame.minY-12)}
            if conversation,app.buttons["chat.jumpToLatest"].exists {bottom=min(bottom,app.buttons["chat.jumpToLatest"].frame.minY-12)}
            let visible=value.exists ? min(value.frame.maxY,bottom)-max(value.frame.minY,top):0
            let required=readable ? min(value.frame.height,bottom-top) : min(value.frame.height,44)
            if value.exists && (!requiresHittable || value.isHittable) && visible>=required {return}
            XCTAssertGreaterThan(bottom-top,45,app.debugDescription)
            let middle=(top+bottom)/2,down=value.exists ? value.frame.midY<middle:conversation
            let distance=min(bottom-top-20,max(44,value.exists ? abs(value.frame.midY-middle):bottom-top-20)),start=down ? top+10:bottom-10,end=start+(down ? distance:-distance)
            app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:start/app.frame.height)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:end/app.frame.height)))
        };XCTFail("Control target is not reachable in the observed content viewport: "+app.debugDescription)
    }
    private func send(_ app:XCUIApplication){let input=app.textViews["chat.input"];input.tap();input.typeText("Synthetic persistent task pause and recovery");app.buttons["chat.send"].tap();wait({self.probe(app)["turn_state"] as? String=="completed"})}
    private func open(_ app:XCUIApplication) {
        if app.keyboards.firstMatch.exists {app.buttons["sidebar.open"].tap();let close=app.buttons["sidebar.close"];XCTAssertTrue(close.waitForExistence(timeout:5),app.debugDescription);close.tap();wait({!app.keyboards.firstMatch.exists})}
        let entry=element(app,"chat.goal.control.")
        if !entry.exists {let card=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Synthetic persistent work")).firstMatch;reveal(app,card,conversation:true);XCTAssertTrue(card.waitForExistence(timeout:6),app.debugDescription);card.tap()}
        XCTAssertTrue(entry.waitForExistence(timeout:6),app.debugDescription);reveal(app,entry,conversation:true);openedTaskID=String(entry.identifier.dropFirst("chat.goal.control.".count));entry.tap();XCTAssertTrue(app.staticTexts["chat.control.status"].waitForExistence(timeout:6),app.debugDescription)
    }
    private func state(_ app:XCUIApplication,_ chinese:String,_ english:String)->Bool {let text=app.staticTexts["chat.control.status"].label;return text.contains(chinese) || text.lowercased().contains(english)}
    private func capture(_ app:XCUIApplication,_ name:String){let value=XCTAttachment(screenshot:app.screenshot());value.name="Synthetic-native-task-control-"+name;value.lifetime = .keepAlways;add(value)}
    private func readOriginalOperations(_ app:XCUIApplication)->XCUIElement {
        let original=element(app,"chat.control.unknown.model:")
        if !original.exists || original.frame.height==0 {let disclosure=element(app,"chat.control.originalOperations");reveal(app,disclosure);disclosure.tap()}
        XCTAssertTrue(original.waitForExistence(timeout:5),app.debugDescription);reveal(app,original,requiresHittable:false,readable:true)
        XCTAssertTrue(original.identifier.hasPrefix("chat.control.unknown.model:"),original.identifier)
        let originalID=String(original.identifier.dropFirst("chat.control.unknown.model:".count));XCTAssertNotNil(originalID.range(of:"^[a-f0-9]{64}$",options:.regularExpression));XCTAssertTrue(original.label.contains(originalID),"The independent row identity must name the same original operation that is read aloud.")
        let label=original.label.lowercased();XCTAssertTrue(label.contains("模型") || label.contains("model"),label);XCTAssertTrue(label.contains("尚未确认") || label.contains("unconfirmed"),label)
        return original
    }
    func testPauseCloseColdReopenAndResumeSameTaskPreservesDraftAndReceipts() {
        let app=launch("p0-ui-task-control");send(app);let input=app.textViews["chat.input"];input.tap();input.typeText("Unrelated unfinished conversation draft");open(app)
        XCTAssertEqual(probe(app)["control_posts"] as? Int,0);let version=app.staticTexts["chat.control.planVersion"].label;XCTAssertTrue(version.contains("v1"));let pause=app.buttons["chat.control.pause"];reveal(app,pause);wait({pause.isEnabled});pause.tap();wait({self.state(app,"已暂停","paused")});wait({self.probe(app)["control_posts"] as? Int==1});let original=element(app,"chat.control.operation.").identifier;XCTAssertNotNil(original.range(of:"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression));capture(app,"paused-original-receipt")
        app.buttons["chat.control.close"].tap();XCTAssertEqual(input.value as? String,"Unrelated unfinished conversation draft");XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12));open(app);wait({self.state(app,"已暂停","paused")});XCTAssertEqual(probe(app)["control_posts"] as? Int,1);XCTAssertEqual(element(app,"chat.control.operation.").identifier,original)
        let resume=app.buttons["chat.control.resume"];reveal(app,resume);wait({resume.isEnabled});resume.tap();wait({self.state(app,"已排队","queued")});wait({self.probe(app)["control_posts"] as? Int==2});XCTAssertEqual(probe(app)["control_committed_operations"] as? Int,2);XCTAssertEqual(app.staticTexts["chat.control.planVersion"].label,version);capture(app,"cold-resume-awaiting-original-worker")
        app.buttons["chat.control.close"].tap();XCTAssertEqual(input.value as? String,"Unrelated unfinished conversation draft")
    }
    func testLostControlReceiptColdRelaunchGetsOriginalAndNeverResends() {
        let app=launch("p0-ui-task-control-unknown");send(app);open(app);let pause=app.buttons["chat.control.pause"];reveal(app,pause);wait({pause.isEnabled});pause.tap();wait({self.probe(app)["control_posts"] as? Int==1});let submission=element(app,"chat.control.submission.");XCTAssertTrue(submission.waitForExistence(timeout:6),app.debugDescription);let original=element(app,"chat.control.operation.").identifier;XCTAssertNotNil(original.range(of:"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression));XCTAssertFalse(app.buttons["chat.control.pause"].isEnabled);XCTAssertFalse(app.buttons["chat.control.resume"].isEnabled);reveal(app,submission);capture(app,"unknown-no-resend-original-uuid")
        app.buttons["chat.control.close"].tap();XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12));open(app);wait({self.state(app,"已暂停","paused")});wait({self.probe(app)["control_original_reads"] as? Int==1});XCTAssertEqual(probe(app)["control_posts"] as? Int,1);XCTAssertEqual(probe(app)["control_committed_operations"] as? Int,1);XCTAssertEqual(element(app,"chat.control.operation.").identifier,original);capture(app,"cold-original-get-confirmed")
    }
    func testMaximumAccessibilityControlsRemainReachableAndRevokeIsSeparateFromPause() {
        let app=launch("p0-ui-large-task-control");send(app);open(app);XCTAssertTrue(app.staticTexts["chat.control.planVersion"].label.contains("v1"));let pause=app.buttons["chat.control.pause"],resume=app.buttons["chat.control.resume"],revoke=app.buttons["chat.control.revoke"]
        for button in [pause,resume,revoke] {reveal(app,button,requiresHittable:button.isEnabled);XCTAssertGreaterThanOrEqual(button.frame.height,44)}
        reveal(app,revoke);wait({revoke.isEnabled});capture(app,"maximum-ax-independent-authority-withdrawal");revoke.tap();wait({self.state(app,"已取消","cancelled")});wait({self.probe(app)["control_posts"] as? Int==1});XCTAssertFalse(app.buttons["chat.control.resume"].exists);XCTAssertTrue(app.staticTexts["chat.control.reason"].exists);capture(app,"maximum-ax-revoked-receipt")
        app.buttons["chat.control.close"].tap();guard let taskID=openedTaskID else {XCTFail("Original task identity missing");return}
        let card=element(app,"chat.goal."+taskID);XCTAssertTrue(card.waitForExistence(timeout:6),app.debugDescription);reveal(app,card,conversation:true,requiresHittable:false)
        // The adaptive header has one complete VoiceOver title + status label.
        // Its AX type must not depend on the current row/stack layout branch.
        let cancelled=card.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@)","Synthetic persistent work","已取消","Cancelled")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout:8),app.debugDescription);reveal(app,cancelled,conversation:true,requiresHittable:false,readable:true)
        XCTAssertEqual(probe(app)["control_posts"] as? Int,1);capture(app,"maximum-ax-original-card-confirmed-cancelled")
    }
    func testMaximumAccessibilityUnknownOriginalOperationsStayReadableAndPreventResume() {
        let app=launch("p0-ui-large-task-control-unresolved");send(app);open(app);XCTAssertTrue(app.staticTexts["chat.control.planVersion"].label.contains("v1"));let unknown=app.staticTexts["chat.control.unknownOperations"];XCTAssertTrue(unknown.waitForExistence(timeout:6),app.debugDescription)
        let resume=app.buttons["chat.control.resume"];reveal(app,resume,requiresHittable:false);XCTAssertGreaterThanOrEqual(resume.frame.height,44);XCTAssertFalse(resume.isEnabled);XCTAssertEqual(probe(app)["control_posts"] as? Int,0)
        let original=readOriginalOperations(app).identifier;XCTAssertNotNil(original.range(of:"[a-f0-9]{64}$",options:.regularExpression));capture(app,"maximum-ax-unknown-original-no-retry")
        let pause=app.buttons["chat.control.pause"];reveal(app,pause);wait({pause.isEnabled});pause.tap();wait({self.state(app,"已暂停","paused")});XCTAssertFalse(app.buttons["chat.control.resume"].isEnabled);wait({self.probe(app)["control_posts"] as? Int==1});XCTAssertEqual(readOriginalOperations(app).identifier,original);capture(app,"maximum-ax-paused-unknown-preserved")
    }
}
