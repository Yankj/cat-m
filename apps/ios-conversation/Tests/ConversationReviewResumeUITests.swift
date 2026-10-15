import XCTest
import Foundation

/// Native cold launches against the existing, explicitly synthetic 8773 API.
/// This test never sends, approves a grant, enters Auth or reads credentials.
final class ConversationReviewResumeUITests:XCTestCase {
    private let port=8773
    private var stateURL:URL {
        if let path=ProcessInfo.processInfo.environment["CATPAW_CONSENT_FIXTURE_STATE_PATH"],!path.isEmpty {return URL(fileURLWithPath:path)}
        let root=(0..<4).reduce(URL(fileURLWithPath:#filePath)){url,_ in url.deletingLastPathComponent()}
        return root.appendingPathComponent("services/edge/build/native-accepted-work-20261015/consent-hit-20261015.json")
    }
    override func setUp(){continueAfterFailure=false}
    private func until(seconds:TimeInterval=10,_ condition:()->Bool)->Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {if condition(){return true};RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        return condition()
    }
    private func state() throws -> [String:Any] {
        let value=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL)) as? [String:Any])
        XCTAssertEqual(value["fixture_kind"] as? String,"actual_cloud_native_loopback_v1")
        XCTAssertEqual(value["origin"] as? String,"http://127.0.0.1:8773")
        return value
    }
    private func requests(_ value:[String:Any])->[[String:Any]] {value["requests"] as? [[String:Any]] ?? []}
    private func assertNoDispatch(_ initial:[String:Any]) throws {
        let latest=try state(),before=initial["counters"] as? [String:Int] ?? [:],after=latest["counters"] as? [String:Int] ?? [:]
        for key in ["provider_calls","turns","accepted_posts","memory_posts"] {
            XCTAssertNotNil(before[key]);XCTAssertEqual(after[key],before[key],"Cold review must not dispatch: "+key)
        }
        let first=requests(initial),last=requests(latest)
        XCTAssertGreaterThanOrEqual(last.count,first.count)
        for request in last.dropFirst(first.count) {
            XCTAssertEqual(request["method"] as? String,"GET","Unsent review may only read the existing loopback API")
            let path=request["path"] as? String ?? ""
            XCTAssertFalse(path.contains("/auth/") || path.contains("/signup") || path.contains("/token"),"Review never enters Auth")
        }
    }
    private func assertConversation(_ app:XCUIApplication,draft:String) {
        let input=app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:15),app.debugDescription)
        XCTAssertTrue(until{input.isHittable && (input.value as? String)==draft},app.debugDescription)
        XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        XCTAssertFalse(app.textFields["auth.email"].exists)
        XCTAssertFalse(app.staticTexts["auth.error"].exists)
        XCTAssertFalse(app.buttons["chat.modelConsent.allow"].exists)
        XCTAssertFalse(app.staticTexts["chat.userMessage"].exists,"The draft has never been sent")
    }
    private func closeSidebar(_ app:XCUIApplication) {
        let open=app.buttons["sidebar.open"]
        XCTAssertTrue(until{open.exists && open.isEnabled && open.isHittable});open.tap()
        let close=app.buttons["sidebar.close"]
        XCTAssertTrue(close.waitForExistence(timeout:5));XCTAssertTrue(close.isHittable);close.tap()
        XCTAssertTrue(until{!close.exists && !app.buttons["sidebar.scrim"].exists && open.isHittable && app.textViews["chat.input"].isHittable})
    }
    private func backgroundAndTerminate(_ app:XCUIApplication,initial:[String:Any]) throws {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(until{app.state != .runningForeground},"Use the normal scene lifecycle to flush the local draft")
        try assertNoDispatch(initial)
        app.terminate()
    }
    private func capture(_ app:XCUIApplication,phase:String,store:String,expiry:Int) {
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Review-resume-"+phase;shot.lifetime = .keepAlways;add(shot)
        let note=XCTAttachment(string:"phase=\(phase);store=\(store);loopback_port=8773;client_expiry=\(expiry);launch_environment_count=\(app.launchEnvironment.count);reality=explicit_loopback_synthetic;Send_presses=0;Auth_actions=0;credential_reads=0;QA_font_override=absent")
        note.name="Review-resume-provenance-"+phase;note.lifetime = .keepAlways;add(note)
    }
    func testOrdinaryColdLaunchRestoresOptedInReviewAndUnsentChineseDraftWithoutAuth() throws {
        let initial=try state(),store=UUID().uuidString,expiry=Int(Date().timeIntervalSince1970)+300
        let draft="冷启动恢复检查：这段中文草稿尚未发送。"
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":store,"CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CATPAW_ACCEPTED_WORK_PORT":String(port),"CATPAW_QA_VISUAL_REVIEW":"1","CATPAW_REVIEW_PERSIST":"1","CATPAW_REVIEW_EXPIRES_AT":String(expiry)]
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();assertConversation(app,draft:"")
        let input=app.textViews["chat.input"];input.tap();input.typeText(draft)
        XCTAssertEqual(input.value as? String,draft)
        closeSidebar(app) // Resign the editor through the ordinary native route.
        assertConversation(app,draft:draft);try assertNoDispatch(initial)
        capture(app,phase:"opted-in-before-background",store:store,expiry:expiry)
        try backgroundAndTerminate(app,initial:initial)
        app.launchEnvironment=[:];app.launchArguments=[]
        for attempt in 1...2 {
            XCTAssertTrue(app.launchEnvironment.isEmpty)
            app.launch() // Ordinary desktop-style launch: no fixture environment is supplied.
            assertConversation(app,draft:draft);try assertNoDispatch(initial)
            capture(app,phase:"ordinary-cold-launch-\(attempt)",store:store,expiry:expiry)
            try backgroundAndTerminate(app,initial:initial)
        }
        // Absence of credential persistence is additionally checked by the
        // descriptor's unit/source contract; this UI test does not inspect a vault.
    }
}
