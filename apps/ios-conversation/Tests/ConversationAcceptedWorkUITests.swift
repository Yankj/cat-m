import XCTest
import UIKit

/// Real native host + production HTTP adapter against the explicitly synthetic
/// loopback maintenance API. These tests do not establish real Auth/model/PG.
final class ConversationAcceptedWorkUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(port:Int=8767,unknown:Bool=false)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":unknown ? "p0-ui-accepted-work-unknown":"p0-ui-accepted-work","CATPAW_ACCEPTED_WORK_PORT":String(port),"P0_PERF_RECORDING":"1"]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US"]
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:15));XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:6));return app
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {let raw=app.staticTexts["qa.p0Probe"].value as? String ?? "{}";return (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any] ?? [:]}
    private func wait(_ body:()->Bool,seconds:TimeInterval=20){let end=Date().addingTimeInterval(seconds);while Date()<end {if body(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))};XCTFail("Named accepted-work integration condition timed out")}
    private func stats(_ port:Int)->[String:Any] {
        var result:[String:Any]=[:];let done=expectation(description:"Loopback synthetic stats")
        URLSession.shared.dataTask(with:URL(string:"http://127.0.0.1:\(port)/testing/v1/stats")!){data,_,_ in
            if let data,let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {result=value};done.fulfill()
        }.resume();wait(for:[done],timeout:6);return result["counters"] as? [String:Any] ?? [:]
    }
    private func entry(_ app:XCUIApplication,_ id:String)->XCUIElement {app.descendants(matching:.any).matching(identifier:id).firstMatch}
    private func reveal(_ app:XCUIApplication,_ value:XCUIElement,readable:Bool=false) {
        for _ in 0..<24 {
            let review=app.scrollViews["chat.acceptedWork.viewport"],viewport=review.exists ? review.frame:app.frame
            let top=max(130,max(viewport.minY,app.navigationBars.firstMatch.frame.maxY)+8)
            let bottom=min(viewport.maxY-8,app.buttons["chat.acceptedWork.confirm"].exists ? app.buttons["chat.acceptedWork.confirm"].frame.minY-8:app.frame.height-50)
            let span=max(44,bottom-top),frame=value.exists ? value.frame:.zero
            let visible=value.exists ? min(bottom,frame.maxY)-max(top,frame.minY):0
            if value.exists && (readable || value.isHittable) && visible>=min(frame.height,readable ? span:44)-1{return}
            // Correct the clipped edge by its actual distance. A fixed half-screen
            // drag oscillates around short rows at large Dynamic Type sizes.
            var delta = -span*0.45
            if frame.height>0 && frame.width>0 {
                if frame.minY<top {delta=top-frame.minY+4}
                else if frame.maxY>bottom {delta=bottom-frame.maxY-4}
            }
            delta=max(-span*0.45,min(span*0.45,delta))
            let start=(top+bottom)/2,end=start+delta
            app.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:start/app.frame.height)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:end/app.frame.height)))
        };XCTFail("Accepted-work target not reachable: "+value.identifier+" "+app.debugDescription)
    }
    private func review(_ app:XCUIApplication,raw:String?=nil) {
        if let raw {let field=app.textViews["chat.input"];field.tap();field.typeText(raw)}
        let context=app.buttons["chat.input.context.open"];XCTAssertTrue(context.waitForExistence(timeout:5),app.debugDescription);context.tap()
        let work=app.buttons["chat.input.context.acceptedWork"];XCTAssertTrue(work.waitForExistence(timeout:5),app.debugDescription);reveal(app,work);XCTAssertTrue(work.isEnabled);work.tap()
        XCTAssertTrue(app.staticTexts["chat.acceptedWork.originalText"].waitForExistence(timeout:6),app.debugDescription);wait({app.buttons["chat.acceptedWork.confirm"].isEnabled})
    }
    private func confirm(_ app:XCUIApplication) {
        let confirm=app.buttons["chat.acceptedWork.confirm"];XCTAssertGreaterThanOrEqual(confirm.frame.height,44);XCTAssertTrue(confirm.isHittable);confirm.tap()
        let nativeAllow=app.buttons["chat.modelConsent.allow"]
        wait({nativeAllow.exists || app.alerts.firstMatch.exists || ["running","completed"].contains(self.probe(app)["turn_state"] as? String ?? "")})
        if nativeAllow.exists {XCTAssertTrue(nativeAllow.isEnabled && nativeAllow.isHittable,app.debugDescription);nativeAllow.tap()}
        else if app.alerts.firstMatch.exists {let allow=app.alerts.buttons["允许此对话"].exists ? app.alerts.buttons["允许此对话"]:app.alerts.buttons["Allow this conversation"];XCTAssertTrue(allow.exists,app.debugDescription);allow.tap()}
    }
    private func capture(_ app:XCUIApplication,_ label:String){let value=XCTAttachment(screenshot:app.screenshot());value.name="Synthetic-native-accepted-work-"+label;value.lifetime = .keepAlways;add(value)}
    func testReviewCloseColdReopenPreservesTermsThenRealHTTPPublishesOriginalReport() {
        let app=launch(),before=stats(8767)["accepted_posts"] as? Int ?? 0,raw="Please organize the supplied fictional notes as a local report."
        review(app,raw:raw);XCTAssertEqual(app.staticTexts["chat.acceptedWork.originalText"].label,raw)
        let deadline=app.staticTexts["chat.acceptedWork.summary.deadline"];reveal(app,deadline,readable:true);let originalDeadline=deadline.label
        let count=app.staticTexts["chat.acceptedWork.summary.modelLimit"];reveal(app,count,readable:true);let originalCount=count.label;capture(app,"default-unconfirmed-original-terms")
        app.buttons["chat.acceptedWork.close"].tap();XCTAssertEqual(stats(8767)["accepted_posts"] as? Int,before)
        XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15));XCTAssertEqual(app.textViews["chat.input"].value as? String,raw)
        review(app);let recoveredDeadline=app.staticTexts["chat.acceptedWork.summary.deadline"];reveal(app,recoveredDeadline,readable:true);XCTAssertEqual(recoveredDeadline.label,originalDeadline)
        let recoveredCount=app.staticTexts["chat.acceptedWork.summary.modelLimit"];reveal(app,recoveredCount,readable:true);XCTAssertEqual(recoveredCount.label,originalCount)
        confirm(app);wait({self.probe(app)["turn_state"] as? String=="completed"});XCTAssertEqual(stats(8767)["accepted_posts"] as? Int,before+1)
        let decision=probe(app)["accepted_work_decision_id"] as? String;XCTAssertNotNil(decision);let original=probe(app)["turn_id"] as? String
        let card=app.descendants(matching:.any).matching(NSPredicate(format:"identifier MATCHES %@","^chat\\.goal\\.[a-f0-9]{64}$")).firstMatch
        wait({card.exists});reveal(app,card)
        let disclosure=card.buttons.matching(NSPredicate(format:"label CONTAINS %@","有限工作原生样例")).firstMatch
        if disclosure.exists {disclosure.tap()}else{card.tap()}
        let result=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.artifact.open.")).firstMatch
        wait({result.exists},seconds:30);XCTAssertTrue(result.exists,app.debugDescription)
        reveal(app,result);result.tap()
        let content=app.staticTexts["chat.artifact.reader.content"]
        XCTAssertTrue(content.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.title"].label,"原生有限工作成果")
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v1")
        XCTAssertEqual(content.label,"A useful synthetic report based only on the original conversation and explicitly selected fictional context.")
        capture(app,"default-opened-original-report")
        let back=app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable,app.debugDescription);back.tap()
        wait({!content.exists && app.textViews["chat.input"].exists})
        XCTAssertEqual(stats(8767)["accepted_posts"] as? Int,before+1)
        capture(app,"default-original-accepted-work")
        XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15));wait({self.probe(app)["turn_id"] as? String==original})
        XCTAssertEqual(probe(app)["accepted_work_decision_id"] as? String,decision);XCTAssertEqual(stats(8767)["accepted_posts"] as? Int,before+1)
    }
    func testLargestSystemTextKeepsOriginalTermsAndFixedConfirmationReachable() {
        let app=launch(),before=stats(8767)["accepted_posts"] as? Int ?? 0
        wait({self.probe(app)["input_font_point_size"] as? Double != nil})
        let measured=probe(app),category=measured["input_system_category"] as? String ?? ""
        XCTAssertEqual(category,UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,"This case requires the real maximum system category, without a QA size override")
        let expected=UIFont.preferredFont(forTextStyle:.body,compatibleWith:UITraitCollection(preferredContentSizeCategory:.accessibilityExtraExtraExtraLarge))
        XCTAssertEqual(measured["input_font_point_size"] as? Double ?? 0,Double(expected.pointSize),accuracy:0.01)
        let witness=XCTAttachment(string:"actual_system_category="+category+";input_point_size="+String(measured["input_font_point_size"] as? Double ?? 0)+";QA_size_override=absent;fixture=explicit_loopback_synthetic")
        witness.name="Actual-system-maximum-text-witness";witness.lifetime = .keepAlways;add(witness)
        review(app,raw:"A long fictional request that must remain fully readable while all work limits can be reviewed and changed. Nothing has been submitted yet.")
        for id in ["originalText","summary.scope","summary.deadline","summary.modelLimit","summary.executionBudget","summary.sourceLimit"] {let value=entry(app,"chat.acceptedWork."+id);reveal(app,value,readable:true);XCTAssertTrue(value.exists)}
        let confirm=app.buttons["chat.acceptedWork.confirm"],close=app.buttons["chat.acceptedWork.close"]
        for action in [confirm,close] {XCTAssertGreaterThanOrEqual(action.frame.height,44);XCTAssertTrue(action.isHittable,app.debugDescription)}
        XCTAssertEqual(stats(8767)["accepted_posts"] as? Int,before);capture(app,"system-maximum-complete-terms-fixed-confirm")
        close.tap();XCTAssertEqual(stats(8767)["accepted_posts"] as? Int,before)
    }
    func testLostResponseColdClientReadsOriginalWithoutRepeatingPOST() {
        let app=launch(port:8768,unknown:true),before=stats(8768)["accepted_posts"] as? Int ?? 0
        review(app,raw:"A fictional local report with one original immutable work agreement.");confirm(app)
        wait({self.probe(app)["turn_state"] as? String=="unknown"});let original=probe(app)["turn_id"] as? String,decision=probe(app)["accepted_work_decision_id"] as? String
        XCTAssertNotNil(original);XCTAssertNotNil(decision);XCTAssertEqual(stats(8768)["accepted_posts"] as? Int,before+1);XCTAssertEqual(stats(8768)["dropped_responses"] as? Int,1);capture(app,"unknown-original-request-not-resent")
        XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15))
        wait({self.probe(app)["turn_state"] as? String=="completed"},seconds:30)
        XCTAssertEqual(probe(app)["turn_id"] as? String,original);XCTAssertEqual(probe(app)["accepted_work_decision_id"] as? String,decision);XCTAssertEqual(stats(8768)["accepted_posts"] as? Int,before+1);capture(app,"cold-original-http-get-recovery")
    }
}
