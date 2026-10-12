import XCTest

final class P0NativeExperienceUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario]
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:5))
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline")
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        return app
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let text=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any] ?? [:]
    }
    private func wait(_ predicate:()->Bool,seconds:TimeInterval=15){
        let deadline=Date().addingTimeInterval(seconds)
        while Date()<deadline { if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTFail("P0 explicit offline fixture condition timed out")
    }
    private func clear(_ input:XCUIElement){input.tap();let value=input.value as? String ?? "";if !value.isEmpty { input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:value.utf16.count)) }}
    private func attach(_ app:XCUIApplication,name:String){
        let data=(try? JSONSerialization.data(withJSONObject:probe(app),options:[.sortedKeys,.prettyPrinted])) ?? Data()
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testStableLocalEchoDuringPermissionAndTwentyCallbackSamples() {
        let app=launch("p0-ui-echo"),input=app.textViews["chat.input"]
        XCTAssertEqual(input.value as? String,"Saved local draft");clear(input)
        for index in 0..<20 {
            input.tap();input.typeText("Synthetic echo \(index)");app.buttons["chat.send"].tap()
            XCTAssertTrue(app.staticTexts["chat.pendingAdmission"].firstMatch.waitForExistence(timeout:1))
            wait({((self.probe(app)["echo_samples"] as? [[String:Any]])?.count ?? 0) >= index+1})
            let operation=(probe(app)["echo_samples"] as? [[String:Any]])?.last?["operation_id"] as? String
            wait({self.probe(app)["turn_state"] as? String == "completed" && self.probe(app)["turn_id"] as? String == operation})
        }
        wait({((self.probe(app)["frame_intervals_ms"] as? [Double])?.count ?? 0) >= 300})
        let data=probe(app),samples=data["echo_samples"] as? [[String:Any]] ?? []
        XCTAssertEqual(samples.count,20);XCTAssertEqual(data["is_presented_frame_proof"] as? Bool,false)
        XCTAssertEqual(data["synthetic_reply_calls"] as? Int,20)
        // Record the actual values. No GPU/physical first-frame or performance PASS is inferred here.
        attach(app,name:"P0-Simulator-action-geometry-callback-20-samples")
    }
    func testNativeMarkedTextPreventsSendAndCommandReturn(){
        let app=launch("p0-ui-ime"),input=app.textViews["chat.input"];clear(input)
        app.buttons["qa.p0IME.mark"].tap();wait({self.probe(app)["composition_active"] as? Bool == true})
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let before=input.value as? String;app.buttons["qa.p0IME.command"].tap()
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0);XCTAssertEqual(input.value as? String,before)
        app.buttons["qa.p0IME.commit"].tap();wait({self.probe(app)["composition_active"] as? Bool == false})
        XCTAssertTrue(app.buttons["chat.send"].isEnabled);attach(app,name:"P0-actual-UITextInput-marked-text-injection")
    }
    func testSimulatorHomeFiveSecondsRecoversSameSyntheticTurn(){
        let app=launch("p0-ui-lifecycle"),input=app.textViews["chat.input"];clear(input);input.typeText("Synthetic scene recovery");app.buttons["chat.send"].tap()
        wait({self.probe(app)["synthetic_reply_calls"] as? Int == 1})
        let initial=probe(app),id=initial["turn_id"] as? String,conversation=initial["conversation_id"] as? String
        XCUIDevice.shared.press(.home);RunLoop.current.run(until:Date().addingTimeInterval(5));app.activate()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:20)
        let final=probe(app);XCTAssertEqual(final["turn_id"] as? String,id);XCTAssertEqual(final["conversation_id"] as? String,conversation)
        XCTAssertEqual(final["synthetic_reply_calls"] as? Int,1);XCTAssertGreaterThanOrEqual(final["synthetic_observe_calls"] as? Int ?? 0,1)
        attach(app,name:"P0-Simulator-home5s-in-process-backend-not-cloud-continuation")
    }
    func testLargestDynamicTypeComposerAndStreamRemainAccessible(){
        let app=launch("p0-ui-large"),input=app.textViews["chat.input"];XCTAssertTrue(input.isHittable);clear(input);input.typeText("Synthetic large type")
        XCTAssertTrue(app.buttons["chat.send"].isHittable);app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:20)
        XCTAssertTrue(input.isHittable);XCTAssertTrue(app.buttons["chat.send"].exists);attach(app,name:"P0-Simulator-accessibility5-composer-stream")
    }
}
