import XCTest
import Foundation

/// Actual native controls and HTTP adapter, using ONLY the isolated 8773
/// maintenance loopback fixture. No real Auth, model, SQL or accepted-work bypass.
/// The server snapshot is read-only evidence; all decisions go through native UI.
final class ConversationConsentLongNoticeUITests:XCTestCase {
    private let port=8773
    private let noticeTitle="允许合成离线测试处理此对话？"
    private let noticeBody="这是本机 loopback 合成测试。消息和选中的文字上下文仅进入维护 API、序列化测试仓库与注入脚本模型；不会发送给 OpenRouter、Google 或真实 Supabase Auth/数据库。新的对话仍须明确许可；有限工作仍遵守原先确认的期限、次数与撤权约束。"
    private var stateURL:URL {
        if let path=ProcessInfo.processInfo.environment["CATPAW_CONSENT_FIXTURE_STATE_PATH"],!path.isEmpty {return URL(fileURLWithPath:path)}
        let root=(0..<4).reduce(URL(fileURLWithPath:#filePath)){url,_ in url.deletingLastPathComponent()}
        return root.appendingPathComponent("services/edge/build/native-accepted-work-20261015/consent-hit-20261015.json")
    }
    override func setUp(){continueAfterFailure=false}
    private func until(seconds:TimeInterval=10,_ condition:()->Bool)->Bool {
        let limit=Date().addingTimeInterval(seconds)
        while Date()<limit {if condition(){return true};RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        return condition()
    }
    private func state() throws -> [String:Any] {
        let object=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL)) as? [String:Any])
        XCTAssertEqual(object["fixture_kind"] as? String,"actual_cloud_native_loopback_v1")
        XCTAssertEqual(object["origin"] as? String,"http://127.0.0.1:8773")
        return object
    }
    private func records(_ kind:String,in state:[String:Any])->[[String:Any]] {
        guard let repository=state["repository"] as? [String:Any],let rows=repository["records"] as? [[Any]] else {return []}
        return rows.compactMap {row in
            guard row.count==2,let key=row[0] as? String,let parts=(try? JSONSerialization.jsonObject(with:Data(key.utf8))) as? [String],parts.count==3,parts[1]==kind else {return nil}
            return row[1] as? [String:Any]
        }
    }
    private func count(_ state:[String:Any],method:String,path:String)->Int {
        (state["requests"] as? [[String:Any]] ?? []).filter{$0["method"] as? String==method && $0["path"] as? String==path}.count
    }
    private func counters(_ state:[String:Any])->[String:Int] {state["counters"] as? [String:Int] ?? [:]}
    private func action(_ app:XCUIApplication,allow:Bool)->XCUIElement {
        let owner:XCUIElement=app.alerts.firstMatch.exists ? app.alerts.firstMatch:app
        return owner.buttons.matching(NSPredicate(format:"label IN %@",allow ? ["允许此对话","Allow this conversation"]:["暂不允许","Not now"])).firstMatch
    }
    private func capture(_ app:XCUIApplication,_ phase:String) {
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Loopback-long-consent-"+phase;shot.lifetime = .keepAlways;add(shot)
        func geometry(_ element:XCUIElement)->String {"exists=\(element.exists);enabled=\(element.exists && element.isEnabled);hittable=\(element.exists && element.isHittable);frame=\(element.exists ? element.frame:.zero)"}
        let text="phase=\(phase);port=8773;reality=explicit_loopback_synthetic;real_requests=0\napp=\(app.frame)\nalert=\(geometry(app.alerts.firstMatch))\nallow=\(geometry(action(app,allow:true)))\ndeny=\(geometry(action(app,allow:false)))\nprivacyShield=\(app.descendants(matching:.any).matching(identifier:"chat.privacyShield").firstMatch.exists)"
        let value=XCTAttachment(string:text);value.name="Loopback-long-consent-geometry-"+phase;value.lifetime = .keepAlways;add(value)
    }
    private func openNormalAction(_ app:XCUIApplication,inline:String,details:String) {
        let direct=app.buttons[inline]
        if direct.exists && direct.isHittable {direct.tap();return}
        let open=app.buttons["chat.input.context.open"]
        XCTAssertTrue(open.waitForExistence(timeout:5));XCTAssertTrue(open.isEnabled && open.isHittable);open.tap()
        let full=app.buttons[details];XCTAssertTrue(full.waitForExistence(timeout:5));NativeUIScrollReveal.reveal(app,full)
        XCTAssertTrue(full.isEnabled && full.isHittable);full.tap()
    }
    private func assertNoticeAndHitTargets(_ app:XCUIApplication,_ phase:String) {
        XCTAssertTrue(app.staticTexts[noticeTitle].waitForExistence(timeout:8),app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label == %@",noticeBody)).firstMatch.exists,"Use the exact Chinese HTTP loopback notice, never the short P0 consent double")
        capture(app,phase)
        for button in [action(app,allow:false),action(app,allow:true)] {
            XCTAssertTrue(button.exists && button.isEnabled && button.isHittable,app.debugDescription)
            NativeUIGeometry.assertMinimumHeight(button.frame)
            XCTAssertTrue(app.frame.contains(button.frame),"Both actual decision controls must lie inside the native viewport")
        }
    }
    func testLongLoopbackConsentRejectReopenAllowPreservesOneOriginalRequest() throws {
        let baseline=try state(),initial=counters(baseline),raw="Hello."
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CATPAW_ACCEPTED_WORK_PORT":String(port),"CATPAW_QA_VISUAL_REVIEW":"1"]
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();let input=app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:15))
        let fresh=app.buttons["chat.new"]
        XCTAssertTrue(fresh.waitForExistence(timeout:5));XCTAssertTrue(fresh.isEnabled && fresh.isHittable);fresh.tap()
        XCTAssertTrue(input.waitForExistence(timeout:5));XCTAssertEqual(input.value as? String,"")
        input.tap();input.typeText(raw);XCTAssertEqual(input.value as? String,raw)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled);app.buttons["chat.send"].tap() // the sole Send press
        assertNoticeAndHitTargets(app,"initial-before-deny")
        let presented=try state(),paths=presented["requests"] as? [[String:Any]] ?? []
        let consentPath=try XCTUnwrap(paths.last(where:{$0["method"] as? String=="GET" && ($0["path"] as? String)?.hasSuffix("/model-consent")==true})?["path"] as? String)
        let parts=consentPath.split(separator:"/").map(String.init);XCTAssertEqual(parts.count,8)
        let conversationID=try XCTUnwrap(parts.count==8 ? parts[6]:nil)
        let turnPath="/catpaw/chat/v1/scopes/"+parts[4]+"/conversations/"+conversationID+"/turns"
        XCTAssertEqual(count(presented,method:"POST",path:consentPath),0);XCTAssertEqual(count(presented,method:"POST",path:turnPath),0)
        XCTAssertEqual(counters(presented)["provider_calls"],initial["provider_calls"])
        action(app,allow:false).tap()
        let denied=until{!app.staticTexts[self.noticeTitle].exists && !app.alerts.firstMatch.exists}
        capture(app,"after-real-deny-tap");XCTAssertTrue(denied,"Real Not now tap must close the notice",file:#filePath,line:#line)
        guard denied else {return}
        RunLoop.current.run(until:Date().addingTimeInterval(0.5))
        let held=try state();XCTAssertEqual(count(held,method:"POST",path:consentPath),0);XCTAssertEqual(count(held,method:"POST",path:turnPath),0)
        XCTAssertEqual(counters(held)["provider_calls"],initial["provider_calls"]);XCTAssertEqual(counters(held)["turns"],initial["turns"])
        XCTAssertEqual(counters(held)["accepted_posts"],initial["accepted_posts"])
        openNormalAction(app,inline:"chat.pendingSummary",details:"chat.input.context.pending")
        XCTAssertTrue(app.buttons["chat.followup.close"].waitForExistence(timeout:5))
        let queued=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.followup.edit."))
        XCTAssertEqual(queued.count,1,"One Send press journals exactly one original message")
        XCTAssertTrue(app.staticTexts[raw].exists)
        let originalID=String(queued.firstMatch.identifier.dropFirst("chat.followup.edit.".count)).lowercased();XCTAssertNotNil(UUID(uuidString:originalID))
        app.buttons["chat.followup.close"].tap();XCTAssertTrue(until{!app.buttons["chat.followup.close"].exists})
        openNormalAction(app,inline:"chat.consent.review",details:"chat.input.context.modelConsent")
        assertNoticeAndHitTargets(app,"normal-recovery-before-allow")
        let reopened=try state();XCTAssertEqual(count(reopened,method:"POST",path:turnPath),0);XCTAssertEqual(count(reopened,method:"POST",path:consentPath),0)
        XCTAssertEqual(counters(reopened)["provider_calls"],initial["provider_calls"])
        action(app,allow:true).tap()
        let closed=until{!app.staticTexts[self.noticeTitle].exists && !app.alerts.firstMatch.exists}
        capture(app,"after-real-allow-tap");XCTAssertTrue(closed,"Allow must return control to the original conversation")
        XCTAssertTrue(until(seconds:20){guard let state=try? self.state() else {return false};return self.count(state,method:"POST",path:turnPath)==1 && self.count(state,method:"POST",path:consentPath)==1})
        let committed=try state(),turns=records("native-chat-turns",in:committed).filter{$0["conversation_id"] as? String==conversationID}
        XCTAssertEqual(turns.count,1)
        let turn=try XCTUnwrap(turns.first),message=(turn["input"] as? [String:Any])?["message"] as? [String:Any]
        XCTAssertEqual(turn["id"] as? String,originalID);XCTAssertEqual(message?["text"] as? String,raw)
        XCTAssertEqual(count(committed,method:"POST",path:consentPath),1);XCTAssertEqual(count(committed,method:"POST",path:turnPath),1)
        XCTAssertEqual(counters(committed)["accepted_posts"],initial["accepted_posts"],"This test never submits accepted work")
        let evidence:[String:Any]=["reality":"explicit_loopback_synthetic","port":port,"conversation_id":conversationID,"original_operation_id":originalID,"original_text":raw,"consent_posts":1,"ordinary_turn_posts":1,"queued_originals":1,"observed_turn_state":turn["state"] ?? NSNull(),"real_auth_model_sql":false]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name="Loopback-long-consent-original-request-receipt";attachment.lifetime = .keepAlways;add(attachment)
        // Permission/hit/admission test only. The named scripted provider is not
        // evidence that a real model answered the ordinary short text correctly.
    }
}
