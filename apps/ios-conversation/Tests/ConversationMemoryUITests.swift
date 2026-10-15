import XCTest
import UIKit

/// Actual native UI and HTTP against the maintained API with named synthetic
/// account, persistence and provider. This does not establish real PG or model use.
final class ConversationMemoryUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(port:Int=8769)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CATPAW_ACCEPTED_WORK_PORT":String(port),"P0_PERF_RECORDING":"1"]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US"]
        app.launch();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15));return app
    }
    private func open(_ app:XCUIApplication){app.buttons["sidebar.open"].tap();let memory=app.buttons["sidebar.memory"];XCTAssertTrue(memory.waitForExistence(timeout:5) && memory.isEnabled);memory.tap();XCTAssertTrue(app.buttons["memory.refresh"].waitForExistence(timeout:10))}
    private func wait(_ body:()->Bool,seconds:TimeInterval=20){let end=Date().addingTimeInterval(seconds);while Date()<end {if body(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))};XCTFail("Named native memory condition timed out")}
    private func element(_ app:XCUIApplication,_ id:String)->XCUIElement {app.descendants(matching:.any).matching(identifier:id).firstMatch}
    private func stats(_ port:Int)->[String:Int] {
        var result:[String:Int]=[:];let done=expectation(description:"Loopback memory counters")
        URLSession.shared.dataTask(with:URL(string:"http://127.0.0.1:\(port)/testing/v1/stats")!){data,_,_ in
            if let data,let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let counters=value["counters"] as? [String:Any] {for (key,value) in counters {if let count=value as? Int {result[key]=count}}};done.fulfill()
        }.resume();wait(for:[done],timeout:6);return result
    }
    private func reveal(_ app:XCUIApplication,_ value:XCUIElement) {
        for attempt in 0..<12 {
            // A keyboard prediction strip is itself a ScrollView. Bind the app
            // viewport by identity instead of relying on cross-window order.
            let viewport=app.scrollViews["memory.viewport"].frame
            let top=max(120,max(viewport.minY,app.navigationBars.firstMatch.frame.maxY)+8)
            var bottom=min(viewport.maxY-8,app.frame.maxY-40)
            if app.keyboards.firstMatch.exists {
                let keyboard=app.keyboards.firstMatch.frame
                var occlusionTop=keyboard.minY
                // The prediction/accessory strip belongs to the keyboard window
                // but lies above XCUIKeyboard.frame. Use its measured geometry.
                for window in app.windows.allElementsBoundByIndex where window.keyboards.firstMatch.exists {
                    for scroll in window.scrollViews.allElementsBoundByIndex {
                        let frame=scroll.frame
                        if frame.height>0 && frame.width>=keyboard.width*0.75 && frame.minY>0 && frame.maxY<=keyboard.minY+1 {occlusionTop=min(occlusionTop,frame.minY)}
                    }
                }
                bottom=min(bottom,occlusionTop-8)
            }
            let confirm=app.buttons["memory.review.confirm"];if confirm.exists {bottom=min(bottom,confirm.frame.minY-8)}
            guard bottom-top>=44 else {XCTFail("No unobscured app viewport: \(top)...\(bottom)");return}
            let span=bottom-top,frame=value.exists ? value.frame:.zero
            if attempt<2 {print("Memory reveal \(value.identifier) frame=\(frame), viewport=\(viewport), visible=\(top)...\(bottom)")}
            let visible=value.exists ? min(bottom,frame.maxY)-max(top,frame.minY):0
            if value.exists && value.isHittable && visible>=min(frame.height,44)-1{return}
            var delta = -span*0.45
            if frame.height>0 && frame.width>0 {if frame.minY<top {delta=top-frame.minY+4}else if frame.maxY>bottom {delta=bottom-frame.maxY-4}}
            delta=max(-span*0.45,min(span*0.45,delta));let start=(top+bottom)/2,end=start+delta
            app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:start/app.frame.height)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:end/app.frame.height)))
        };XCTFail("Memory control not reachable: "+value.identifier+" "+app.debugDescription)
    }
    private func confirm(_ app:XCUIApplication){let action=app.buttons["memory.review.confirm"];XCTAssertTrue(action.waitForExistence(timeout:5));XCTAssertGreaterThanOrEqual(action.frame.height,44);XCTAssertTrue(action.isHittable);action.tap()}
    private func enable(_ app:XCUIApplication){let toggle=app.buttons["memory.enabled.change"];wait{toggle.exists && toggle.isEnabled};if toggle.label=="Turn on memory use" {reveal(app,toggle);toggle.tap();confirm(app);wait{!app.buttons["memory.review.confirm"].exists && toggle.label=="Turn off memory use"}}}
    private func capture(_ app:XCUIApplication,_ name:String){
        // Capture stable presentation rather than the first transient sheet frame.
        if app.buttons["memory.review.confirm"].exists {
            let action=app.buttons["memory.review.confirm"];var last=CGRect.null,stable=0
            wait({let frame=action.frame;if frame==last && action.isHittable {stable+=1}else{stable=0};last=frame;return stable>=3})
        }
        let value=XCTAttachment(screenshot:app.screenshot());value.name="Synthetic-native-memory-"+name;value.lifetime = .keepAlways;add(value)}
    func test01NewConversationSavesColdDraftThenSourceCorrectionAndForget() {
        let app=launch();open(app);enable(app)
        let raw="Prefer cocoa.",changed="Prefer tea.",topic="Drink",before=stats(8769)
        let title=element(app,"memory.draft.topic"),text=element(app,"memory.draft.text")
        reveal(app,title);title.tap();title.typeText(topic);reveal(app,text);text.tap();text.typeText(raw)
        let review=app.buttons["memory.draft.review"];reveal(app,review);review.tap()
        XCTAssertEqual(app.staticTexts["memory.review.original"].label,raw);capture(app,"default-unsubmitted-review")
        app.buttons["memory.review.close"].tap();XCTAssertEqual(stats(8769)["memory_posts"],before["memory_posts"])
        XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15));open(app)
        reveal(app,text);XCTAssertEqual(text.value as? String,raw);reveal(app,review);review.tap();confirm(app)
        let source=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","memory.source.")).firstMatch
        wait{source.exists};XCTAssertEqual(stats(8769)["memory_posts"],(before["memory_posts"] ?? 0)+1)
        reveal(app,source);source.tap();XCTAssertTrue(app.staticTexts["memory.source.text"].waitForExistence(timeout:5));XCTAssertEqual(app.staticTexts["memory.source.text"].label,raw);capture(app,"default-real-source");app.buttons["memory.source.close"].tap()
        let correct=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","memory.correct.")).firstMatch
        reveal(app,correct);correct.tap();reveal(app,text);text.tap();text.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap();text.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:raw.utf16.count)+changed)
        reveal(app,review);review.tap();XCTAssertEqual(app.staticTexts["memory.review.original"].label,changed);confirm(app)
        wait{!app.buttons["memory.review.confirm"].exists && app.staticTexts[changed].exists};capture(app,"default-corrected-memory")
        let forget=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","memory.forget.")).firstMatch;reveal(app,forget);forget.tap();confirm(app)
        wait{app.staticTexts["memory.empty"].exists};XCTAssertEqual(stats(8769)["memory_posts"],(before["memory_posts"] ?? 0)+3);XCTAssertEqual(stats(8769)["provider_calls"],before["provider_calls"]);capture(app,"default-forgotten-with-receipt")
    }
    func test02LargestSystemTextKeyboardAndFixedReviewRemainReachable() {
        let app=launch();open(app);enable(app)
        let probe=app.staticTexts["qa.p0Probe"].value as? String ?? "{}",values=(try? JSONSerialization.jsonObject(with:Data(probe.utf8))) as? [String:Any] ?? [:]
        XCTAssertEqual(values["input_system_category"] as? String,UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue)
        let before=stats(8769),title=element(app,"memory.draft.topic"),text=element(app,"memory.draft.text")
        reveal(app,title);title.tap();title.typeText("Fictional preference")
        reveal(app,text);text.tap();text.typeText("A readable fictional preference at the largest actual system text size.")
        let keyboard=app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout:2) {text.tap()}
        XCTAssertTrue(keyboard.waitForExistence(timeout:5),"The software keyboard must actually be visible, not inferred from typing")
        var last=CGRect.null,stable=0
        wait({let frame=keyboard.frame;if keyboard.exists && frame==last {stable+=1}else{stable=0};last=frame;return stable>=3})
        let viewport=app.scrollViews["memory.viewport"].frame,top=max(viewport.minY,app.navigationBars.firstMatch.frame.maxY)
        let assistant=app.otherElements["SystemInputAssistantView"],keyboardTop=assistant.exists ? min(assistant.frame.minY,keyboard.frame.minY):keyboard.frame.minY
        XCTAssertGreaterThanOrEqual(min(text.frame.maxY,keyboardTop)-max(text.frame.minY,top),44,"A useful part of the focused editor must remain visible above the actual keyboard")
        let geometry=XCTAttachment(string:"build=25;system_category=accessibilityExtraExtraExtraLarge;reality=synthetic_native\neditor=\(text.frame)\nkeyboard=\(keyboard.frame)\nkeyboard_top=\(keyboardTop)\nviewport=\(viewport)");geometry.name="Memory-maximum-actual-keyboard-geometry";geometry.lifetime = .keepAlways;add(geometry)
        capture(app,"maximum-editor-with-actual-visible-system-keyboard")
        let review=app.buttons["memory.draft.review"];reveal(app,review);review.tap()
        let confirm=app.buttons["memory.review.confirm"],close=app.buttons["memory.review.close"]
        XCTAssertTrue(confirm.waitForExistence(timeout:5) && confirm.isHittable);XCTAssertGreaterThanOrEqual(confirm.frame.height,44);XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.staticTexts["memory.review.original"].exists);capture(app,"maximum-full-review-fixed-confirmation")
        close.tap();XCTAssertEqual(stats(8769)["memory_posts"],before["memory_posts"]);XCTAssertEqual(stats(8769)["provider_calls"],before["provider_calls"])
    }
    func test03LostReplyColdClientReadsOriginalWithoutSecondPOST() {
        let app=launch(port:8770);open(app);let before=stats(8770)
        let toggle=app.buttons["memory.enabled.change"];wait{toggle.exists && toggle.isEnabled};XCTAssertEqual(toggle.label,"Turn on memory use");toggle.tap();confirm(app)
        wait{app.staticTexts["memory.unknown"].exists};XCTAssertEqual(stats(8770)["memory_posts"],(before["memory_posts"] ?? 0)+1);capture(app,"unknown-accepted-original")
        XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15));open(app)
        let observe=app.buttons["memory.observe"];XCTAssertTrue(observe.waitForExistence(timeout:10));reveal(app,observe);observe.tap()
        wait{app.staticTexts["memory.applied"].exists && !app.staticTexts["memory.unknown"].exists}
        let after=stats(8770);XCTAssertEqual(after["memory_posts"],(before["memory_posts"] ?? 0)+1);XCTAssertEqual(after["memory_original_gets"],(before["memory_original_gets"] ?? 0)+1);XCTAssertEqual(after["provider_calls"],before["provider_calls"]);capture(app,"cold-original-get-no-resend")
    }
}
