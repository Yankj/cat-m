import XCTest
import CryptoKit

final class ConversationFirstUITests: XCTestCase {
    func testApprovedSingleNaturalDelegationArtifactAndColdRestore() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_APPROVED_NATURAL_TASK"] == "1" else { throw XCTSkip("Requires explicit synthetic-only task approval and at most five free provider calls") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"com.example.CatpawM.OpenMuseDemo");app.launch()
        let input = app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:40));XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        let fresh=app.buttons["chat.new"],enabled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:app.buttons["chat.new"])
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:20),.completed);fresh.tap();XCTAssertTrue(app.staticTexts["chat.empty"].waitForExistence(timeout:15))
        let prompt="请直接把以下虚构资料交给后台短任务整理并保存本地成果，标题「合成出门清单」：小猫下午去公园30分钟；已备水杯、纸巾；天气未知。正文列「安排」「物品」「未知」，末尾包含CATPAW_TASK_OK。不追问、不查网络、不设长期任务；成果保存后结束任务。"
        input.tap();input.typeText(prompt);app.buttons["chat.send"].tap()
        let consent=app.alerts.firstMatch;XCTAssertTrue(consent.waitForExistence(timeout:20));attach(app,"natural-v14-isolated-provider-consent");consent.buttons["允许此对话"].tap()
        let goals=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.goal.")),goal=goals.firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout:100),"One natural turn must commit a delegate_task binding; never re-post this request")
        XCTAssertEqual(goals.count,1);let originalGoalID=goal.identifier;attach(app,"natural-v14-unique-bound-task")
        // App foreground observes the same turn/task every ten seconds. No manual tick or further Send.
        var succeeded=false,blocked=""
        for _ in 0..<18 {
            let status=goal.label
            if status.contains("已完成") { succeeded=true;break }
            if status.contains("等待反馈") || status.contains("需要处理") || status.contains("状态待确认") || status.contains("已暂停") || status.contains("已结束") { blocked=status;break }
            Thread.sleep(forTimeInterval:10)
        }
        attach(app,"natural-v14-task-settled-or-checkpoint")
        XCTAssertTrue(succeeded,"Task did not succeed; preserve original binding/checkpoint, no tick or re-post. Status: \(blocked.isEmpty ? goal.label : blocked)")
        goal.tap()
        let artifact=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.artifact.open.")).firstMatch
        XCTAssertTrue(artifact.waitForExistence(timeout:15));XCTAssertTrue(app.staticTexts["合成出门清单 · v1"].exists);let artifactID=artifact.identifier
        artifact.tap()
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v1")
        let hashElement=readerHash(app);let hash=hashElement.label
        XCTAssertNotNil(hash.range(of:"^SHA-256 [a-f0-9]{64}$",options:.regularExpression))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","CATPAW_TASK_OK")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","安排")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","物品")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","未知")).firstMatch.exists)
        attach(app,"natural-v14-artifact-v1-body-hash")
        app.terminate();app.launch();XCTAssertTrue(input.waitForExistence(timeout:40));XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        let sameGoal=app.buttons[originalGoalID];XCTAssertTrue(sameGoal.waitForExistence(timeout:30));XCTAssertTrue(sameGoal.label.contains("已完成"));sameGoal.tap()
        let sameArtifact=app.buttons[artifactID];XCTAssertTrue(sameArtifact.waitForExistence(timeout:10));XCTAssertTrue(app.staticTexts["合成出门清单 · v1"].exists);sameArtifact.tap()
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v1");XCTAssertEqual(readerHash(app).label,hash)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","CATPAW_TASK_OK")).firstMatch.exists);attach(app,"natural-v14-cold-restore-same-task-artifact-v1-hash")
        let proof:[String:Any]=["api_version":14,"new_user_created":false,"natural_turn_send_actions":1,"task_goal_identifier":originalGoalID,"unique_binding_count":1,"task_state":"succeeded","artifact_identifier":artifactID,"artifact_version":1,"artifact_title":"合成出门清单","artifact_hash":hash,"marker":"CATPAW_TASK_OK","cold_restore_same_task_artifact_hash":true,"manual_tick":false,"unknown_replay":false,"token_exported":false]
        let evidence=XCTAttachment(data:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),uniformTypeIdentifier:"public.json");evidence.name="natural-v14-task-artifact-proof";evidence.lifetime = .keepAlways;add(evidence)
    }

    func testApprovedLastSyntheticTurnExplicitCompletionAndColdRestore() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_APPROVED_ANON_LAST_CALL"] == "1" else { throw XCTSkip("Requires explicit approval for the one remaining synthetic model request") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"com.example.CatpawM.OpenMuseDemo");app.launch()
        let input = app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:40));XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        let fresh = app.buttons["chat.new"]
        let enabled = XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:fresh)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:20),.completed);fresh.tap()
        XCTAssertTrue(app.staticTexts["chat.empty"].waitForExistence(timeout:15));input.tap();input.typeText("Reply exactly CATPAW_OK.")
        app.buttons["chat.send"].tap()
        let consent = app.alerts.firstMatch;XCTAssertTrue(consent.waitForExistence(timeout:20));attach(app,"anonymous-v13-new-conversation-consent")
        consent.buttons["允许此对话"].tap()
        let completed = app.staticTexts["chat.reply.completed"]
        // Wait for the domain terminal, never for the first streaming text delta.
        if !completed.waitForExistence(timeout:75) {
            let observe = app.buttons["chat.observe"]
            if observe.exists && observe.isEnabled { observe.tap() }
            XCTAssertTrue(completed.waitForExistence(timeout:20),"Observe the same turn only; this case never re-posts the request")
        }
        let answer = app.descendants(matching:.any)["chat.assistantMessage"].firstMatch;XCTAssertTrue(answer.exists);let text = answer.label
        XCTAssertEqual(text.trimmingCharacters(in:.whitespacesAndNewlines),"CATPAW_OK")
        XCTAssertFalse(app.staticTexts["chat.unresolved"].exists);XCTAssertFalse(app.staticTexts["chat.reply.failed"].exists);attach(app,"anonymous-v13-explicit-completed-reply")
        app.buttons["chat.history"].tap()
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.","Reply exactly CATPAW_OK")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10));let id = row.identifier
        let original = app.buttons["chat.history.row.ED2F017D-8078-4AB9-857E-8072215F1009"];XCTAssertTrue(original.exists,"The original unknown conversation must remain")
        row.tap();app.terminate();app.launch()
        XCTAssertTrue(input.waitForExistence(timeout:40));XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        XCTAssertTrue(completed.waitForExistence(timeout:20));XCTAssertEqual(answer.label,text)
        app.buttons["chat.history"].tap();XCTAssertTrue(app.buttons[id].waitForExistence(timeout:10));XCTAssertTrue(original.exists);attach(app,"anonymous-v13-cold-restore-completed-and-old-unknown-history")
        let proof:[String:Any] = ["api_version":13,"app_bundle":"com.example.CatpawM.OpenMuseDemo","anonymous_identity_reused":true,"new_send_actions":1,"original_unknown_conversation_retained":true,"new_conversation_id":id,"explicit_domain_terminal":"completed","final_reply":"CATPAW_OK","cold_restore_same_conversation_and_text":true,"token_exported":false]
        let evidence = XCTAttachment(data:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),uniformTypeIdentifier:"public.json");evidence.name = "anonymous-v13-completion-proof";evidence.lifetime = .keepAlways;add(evidence)
    }

    func testExistingRealAnonymousTurnReadOnlyAndColdRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"com.example.CatpawM.OpenMuseDemo");app.launch()
        let input = app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:40))
        XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        let observe = app.buttons["chat.observe"]
        if observe.waitForExistence(timeout:5) {
            let enabled = XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:observe)
            XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:20),.completed);observe.tap()
        }
        let answer = app.descendants(matching:.any)["chat.assistantMessage"].firstMatch
        let full = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@","CATPAW ANONYMOUS LIVE OK"),object:answer)
        let status = XCTWaiter.wait(for:[full],timeout:45)
        attach(app,"anonymous-existing-original-turn-read-only")
        XCTAssertEqual(status,.completed,"Original reply must settle; read-only case never clicks Send or grants new consent")
        let resolved = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.staticTexts["chat.unresolved"])
        XCTAssertEqual(XCTWaiter.wait(for:[resolved],timeout:20),.completed,"Partial text or unknown state is not success")
        let received = answer.label
        app.buttons["chat.history"].tap()
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.","Isolated synthetic integration check")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10));let id = row.identifier;row.tap()
        app.terminate();app.launch();XCTAssertTrue(input.waitForExistence(timeout:40));XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        XCTAssertTrue(answer.waitForExistence(timeout:15));XCTAssertEqual(answer.label,received)
        XCTAssertFalse(app.staticTexts["chat.unresolved"].exists)
        app.buttons["chat.history"].tap();XCTAssertTrue(app.buttons[id].waitForExistence(timeout:10));attach(app,"anonymous-existing-cold-restore-same-conversation")
        let proof:[String:Any] = ["actual_app_bundle":"com.example.CatpawM.OpenMuseDemo","production_auth":true,"anonymous_identity_reused":true,"synthetic_only":true,"conversation_id_reused":id,"reply_restored_exactly":true,"new_send_actions":0,"token_exported":false]
        let evidence = XCTAttachment(data:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),uniformTypeIdentifier:"public.json");evidence.name = "anonymous-existing-read-only-proof";evidence.lifetime = .keepAlways;add(evidence)
    }

    func testApprovedRealAnonymousEntranceChatAndColdRestore() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_APPROVED_ANON_TRIAL"] == "1" else { throw XCTSkip("Requires explicit approval for a real isolated anonymous synthetic trial") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"com.example.CatpawM.OpenMuseDemo")
        app.launch()
        let start = app.buttons["auth.startExperience"],input = app.textViews["chat.input"]
        if start.waitForExistence(timeout:10) {
            let enabled = XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:start)
            XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:20),.completed)
            attach(app,"anonymous-real-start-entry");Thread.sleep(forTimeInterval: 1.0) /* SPEC-E: the CTA is hit-testable 0.95 s after the landing appears */; start.tap()
        }
        XCTAssertTrue(input.waitForExistence(timeout:40),"Real auth/user verification and account scope must complete")
        XCTAssertFalse(app.staticTexts["auth.fixture"].exists);XCTAssertFalse(app.buttons["fixture.run"].exists);XCTAssertFalse(app.textFields["auth.email"].exists)
        attach(app,"anonymous-real-verified-workspace")
        let prompt = "Isolated synthetic integration check. Reply exactly CATPAW ANONYMOUS LIVE OK. Do not browse, use tools, or access personal data."
        input.tap();input.typeText(prompt)
        let send = app.buttons["chat.send"];XCTAssertTrue(send.isEnabled);send.tap()
        let consent = app.alerts.firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout:20),"New isolated anonymous scope must require explicit provider consent")
        attach(app,"anonymous-real-synthetic-provider-consent")
        let allow = consent.buttons["允许此对话"];XCTAssertTrue(allow.exists);allow.tap()
        let answer = app.descendants(matching:.any)["chat.assistantMessage"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout:70),"A real explicit provider terminal is required; an EOF or error is not success")
        let received = answer.label;XCTAssertTrue(received.contains("CATPAW ANONYMOUS LIVE OK"))
        attach(app,"anonymous-real-chat-terminal")
        app.buttons["chat.history"].tap()
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.","Isolated synthetic integration check")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10));let originalID = row.identifier
        row.tap();XCTAssertTrue(input.waitForExistence(timeout:10))
        app.terminate();app.launch()
        XCTAssertTrue(input.waitForExistence(timeout:40));XCTAssertFalse(start.exists)
        XCTAssertTrue(answer.waitForExistence(timeout:20));XCTAssertEqual(answer.label,received)
        app.buttons["chat.history"].tap();XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout:10))
        attach(app,"anonymous-real-cold-restore-same-conversation")
        let proof:[String:Any] = ["actual_app_bundle":"com.example.CatpawM.OpenMuseDemo","production_auth":true,"anonymous":true,"synthetic_only":true,"conversation_id_reused":originalID,"reply_restored_exactly":true,"provider_sends_requested":1,"token_exported":false]
        let evidence = XCTAttachment(data:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),uniformTypeIdentifier:"public.json");evidence.name = "anonymous-real-ui-proof";evidence.lifetime = .keepAlways;add(evidence)
    }

    func testOriginalR9RecoverySameIDsV2HashCompletedAfterRestart() async throws {
        continueAfterFailure = false
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["CATPAW_RECOVERY_CONNECTION"])
        var b64 = encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/"); b64 += String(repeating:"=",count:(4-b64.count%4)%4)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(Data(base64Encoded:b64))) as? [String:Any])
        let origin = try XCTUnwrap(URL(string:try XCTUnwrap(config["base_url"] as? String))),token = try XCTUnwrap(config["access_token"] as? String)
        XCTAssertEqual(origin.host,"127.0.0.1"); XCTAssertEqual(config["original_recovery_read_only"] as? Bool,true)
        func get(_ path:String) async throws -> [String:Any] {
            var request = URLRequest(url:try XCTUnwrap(URL(string:path,relativeTo:origin))); request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            let (data,response) = try await URLSession.shared.data(for:request); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200); return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        }
        let app = XCUIApplication(); app.launchEnvironment["R7_SYNTHETIC_CONNECTION_B64URL"] = encoded
        app.launchEnvironment["R7_AUTHORIZED_REAL_SYNTHETIC"] = "1"; app.launchEnvironment["R9_ORIGINAL_RECOVERY"] = "1"
        app.launch(); XCTAssertTrue(app.staticTexts["fixture.identity"].waitForExistence(timeout:20))
        let goal = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.goal.")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout:20)); goal.tap()
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout:30)); XCTAssertFalse(app.buttons["fixture.run"].isEnabled)
        func evidence() throws -> [String:Any] { let value = try XCTUnwrap(app.staticTexts["fixture.evidence"].value as? String); return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any]) }
        let before = try evidence()
        func check(_ value:[String:Any]) throws {
            for key in ["conversation_id","turn_id","task_id","run_id","artifact_id"] { XCTAssertEqual((value[key] as? String)?.lowercased(),(config[key] as? String)?.lowercased()) }
            XCTAssertEqual(value["state"] as? String,"completed"); XCTAssertEqual(value["artifact_version"] as? Int,2); XCTAssertEqual(value["artifact_hash"] as? String,config["artifact_hash"] as? String)
            let history = try XCTUnwrap(value["artifact_history"] as? [[String:Any]])
            XCTAssertEqual(Set(history.compactMap{$0["version"] as? Int}),Set([1,2])); XCTAssertEqual(history.first(where:{$0["version"] as? Int == 1})?["hash"] as? String,"c79b6bbae33ed916c0ba5b9bb244cbb096cb6426b6e8ed33d6788ea79eb29c64")
        }
        try check(before); attach(app,"r9-recovered-original-ids-v2-completed")
        app.terminate(); app.launch(); XCTAssertTrue(app.staticTexts["fixture.identity"].waitForExistence(timeout:20)); XCTAssertTrue(goal.waitForExistence(timeout:20)); goal.tap()
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout:20)); let after = try evidence(); try check(after)
        for key in ["conversation_id","turn_id","task_id","run_id","artifact_id","artifact_hash"] { XCTAssertEqual(before[key] as? String,after[key] as? String) }
        let projection = try await get(String(try XCTUnwrap(after["projection_url"] as? String).dropFirst()))
        XCTAssertEqual((projection["run"] as? [String:Any])?["state"] as? String,"succeeded")
        let scope = try XCTUnwrap(config["scope"] as? [String:String]), artifactID = try XCTUnwrap(after["artifact_id"] as? String)
        let wire = try await get("catpaw/v1/scopes/"+scope["scope_id"]!+"/artifacts/"+artifactID+"/versions/2"), record = try XCTUnwrap(wire["artifact"] as? [String:Any]), body = try XCTUnwrap(record["body"] as? String)
        let hash=SHA256.hash(data:Data(body.utf8)).map{String(format:"%02x",$0)}.joined();XCTAssertEqual(hash,after["artifact_hash"] as? String)
        let artifact = app.buttons["chat.artifact.open."+artifactID]; XCTAssertTrue(artifact.waitForExistence(timeout:10)); artifact.tap(); XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v2");XCTAssertEqual(readerHash(app).label,"SHA-256 "+hash);attach(app,"r9-restart-v2-artifact-reader")
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:["before":before,"after":after,"production_auth":false],options:.sortedKeys),uniformTypeIdentifier:"public.json"); attachment.name = "r9-original-recovery-before-after"; attachment.lifetime = .keepAlways; add(attachment)
        let stats = try await get("catpaw/testing/v1/fixture"); XCTAssertEqual(stats["provider_requests"] as? Int,3); XCTAssertEqual(stats["recovery_provider_requests"] as? Int,1)
    }

    func testColdValidRestoreShowsOwnLocalDraftWithAdmissionClosedUntilValidation() { coldRestoreScenario("cold-valid", accepted:true) }
    func testColdExpiredRestoreShowsOwnLocalDraftWithAdmissionClosedUntilValidation() { coldRestoreScenario("cold-expired", accepted:true) }
    func testColdRevokedRestoreClosesOwnLocalDraftAfterValidationRejects() { coldRestoreScenario("cold-revoked", accepted:false) }
    private func coldRestoreScenario(_ scenario:String, accepted:Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(), store = UUID().uuidString
        app.launchEnvironment["R7_AUTH_TEST_STORE"] = store
        app.launchEnvironment["R7_AUTH_TEST_SCENARIO"] = "account-isolation"
        app.launch()
        let email = app.textFields["auth.email"]; XCTAssertTrue(email.waitForExistence(timeout:15)); email.tap(); email.typeText("a.test@example.invalid")
        let password = app.secureTextFields["auth.password"]; password.tap(); password.typeText("fixture-only"); app.buttons["auth.signIn"].tap()
        let input = app.textViews["chat.input"]; XCTAssertTrue(input.waitForExistence(timeout:15)); input.tap(); input.typeText("Cold restore private synthetic draft")
        // Observe the actual persisted history projection before terminating;
        // a keyboard value alone can precede the existing 300ms draft save.
        app.buttons["sidebar.open"].tap()
        let saved = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","sidebar.conversation.","Cold restore private synthetic draft")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout:10)); app.buttons["sidebar.close"].tap()
        app.terminate(); app.launchEnvironment["R7_AUTH_TEST_SCENARIO"] = scenario; app.launch()
        let state=app.otherElements["auth.fixture.sessionState"]
        XCTAssertTrue(state.waitForExistence(timeout:5))
        let pending=expectation(for:NSPredicate(format:"value == %@","restoring|closed|unvalidated|turns:0"),evaluatedWith:state)
        wait(for:[pending],timeout:5)
        XCTAssertTrue(input.exists);XCTAssertEqual(input.value as? String,"Cold restore private synthetic draft")
        XCTAssertFalse(app.staticTexts["Account B private synthetic draft"].exists)
        attach(app,"r8-"+scenario+"-own-local-draft-network-closed")
        if accepted {
            let admitted=expectation(for:NSPredicate(format:"value == %@","authenticated|admitted|validated|turns:0"),evaluatedWith:state)
            wait(for:[admitted],timeout:15)
            XCTAssertTrue(input.exists)
            let loaded = expectation(for:NSPredicate(format:"value == %@","Cold restore private synthetic draft"),evaluatedWith:input)
            wait(for:[loaded],timeout:10)
            attach(app,"r8-"+scenario+"-validated-original-draft")
        } else {
            let closed = expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:input)
            wait(for:[closed],timeout:15)
            let rejected=expectation(for:NSPredicate(format:"value == %@","loginRequired|closed|unvalidated|turns:0"),evaluatedWith:state)
            wait(for:[rejected],timeout:5)
            XCTAssertTrue(app.staticTexts["auth.error"].exists); XCTAssertFalse(input.exists)
            XCTAssertTrue(app.buttons["auth.signIn"].exists)
            attach(app,"r8-cold-revoked-login-required")
        }
    }
    func testV5FrozenSyntheticActualAppCloseAndReadback() async throws {
        continueAfterFailure = false
        guard let encoded = ProcessInfo.processInfo.environment["CATPAW_V5_FIXTURE_B64URL"] else { throw XCTSkip("Requires explicit synthetic CLI runner") }
        var b64 = encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/"); b64 += String(repeating:"=",count:(4-b64.count%4)%4)
        let data = try XCTUnwrap(Data(base64Encoded:b64)), config = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]), base = try XCTUnwrap(config["base_url"] as? String), origin = try XCTUnwrap(URL(string:base)), token = try XCTUnwrap(config["access_token"] as? String)
        XCTAssertEqual(origin.host,"127.0.0.1"); XCTAssertEqual(config["production_login_verified"] as? Bool,false)
        func call(_ path:String,tick:Bool = false,body:[String:Any] = [:]) async throws -> [String:Any] {
            var r = URLRequest(url:try XCTUnwrap(URL(string:path,relativeTo:origin))); r.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            if tick { r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject:body); r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
            let (d,response) = try await URLSession.shared.data(for:r); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200); return try XCTUnwrap(JSONSerialization.jsonObject(with:d) as? [String:Any])
        }
        let app = XCUIApplication(); app.launchEnvironment["R7_SYNTHETIC_CONNECTION_B64URL"] = encoded
        if ProcessInfo.processInfo.environment["R7_AUTHORIZED_REAL_SYNTHETIC"] == "1" { app.launchEnvironment["R7_AUTHORIZED_REAL_SYNTHETIC"] = "1" }
        app.launch(); XCTAssertTrue(app.staticTexts["fixture.identity"].waitForExistence(timeout:20))
        let run = app.buttons["fixture.run"]
        let enabled = expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:run); await fulfillment(of:[enabled],timeout:15)
        attach(app,"r7-v5-explicit-fixture-identity"); run.tap()
        let goal = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.goal.")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout:90)); attach(app,"r7-v5-original-task-card")
        func evidence() throws -> [String:Any] { let value = try XCTUnwrap(app.staticTexts["fixture.evidence"].value as? String); return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any]) }
        let before = try evidence()
        XCTAssertFalse(run.isEnabled); app.terminate()
        var progressEvidence:[[String:Any]] = []
        if ProcessInfo.processInfo.environment["R9_BOUNDED_LOCAL_PROGRESS"] == "1" {
            let runID = try XCTUnwrap(before["run_id"] as? String), projection = try await call(String(try XCTUnwrap(before["projection_url"] as? String).dropFirst()))
            let task = try XCTUnwrap(projection["task"] as? [String:Any]), taskID = try XCTUnwrap(task["id"] as? String)
            let deadline = Date().addingTimeInterval(60)
            for _ in 0..<8 {
                guard Date() < deadline else { break }
                let wire = try await call("catpaw/testing/v1/local-progress?task_id="+taskID+"&run_id="+runID), progress = try XCTUnwrap(wire["progress"] as? [String:Any])
                progressEvidence.append(progress)
                let action = try XCTUnwrap(progress["next_action"] as? String)
                guard ["initial_worker_model","local_tool","local_receipt"].contains(action) else { break }
                if let next = progress["nextRunAt"] as? String {
                    let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
                    if let date = parser.date(from:next) {
                        let delay = max(0,date.timeIntervalSinceNow)+0.05
                        guard delay < deadline.timeIntervalSinceNow else { break }
                        try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))
                    }
                }
                let settled = try await call("catpaw/testing/v1/local-tick",tick:true,body:["task_id":taskID,"run_id":runID,"expected_next_action":action,"expected_round_next":progress["round_next"] ?? NSNull()])
                if let afterTick = settled["progress"] as? [String:Any] { progressEvidence.append(afterTick) }
            }
        } else {
            _ = try await call("catpaw/testing/v1/tick",tick:true); try await Task.sleep(nanoseconds:1_200_000_000); _ = try await call("catpaw/testing/v1/tick",tick:true)
        }
        app.launch(); XCTAssertTrue(app.staticTexts["fixture.identity"].waitForExistence(timeout:20)); XCTAssertFalse(app.buttons["fixture.run"].isEnabled)
        XCTAssertTrue(goal.waitForExistence(timeout:20)); goal.tap()
        let after = try evidence()
        for key in ["conversation_id","turn_id","run_id"] { XCTAssertEqual(before[key] as? String,after[key] as? String) }
        let progressAttachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:["before":before,"after":after,"progress":progressEvidence,"production_auth":false],options:.sortedKeys),uniformTypeIdentifier:"public.json"); progressAttachment.name = "r9-bounded-original-id-readback"; progressAttachment.lifetime = .keepAlways; add(progressAttachment)
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout:30),"Original task did not succeed; inspect bounded progress evidence. Never spend a third model request."); attach(app,"r7-v5-app-reopened-original-completed-task")
        let projection = try await call(String(try XCTUnwrap(after["projection_url"] as? String).dropFirst())), serverRun = try XCTUnwrap(projection["run"] as? [String:Any])
        XCTAssertEqual(serverRun["state"] as? String,"succeeded")
        let scope = try XCTUnwrap(config["scope"] as? [String:String]), artifactID = try XCTUnwrap(after["artifact_id"] as? String), version = try XCTUnwrap(after["artifact_version"] as? Int)
        let artifactWire = try await call("catpaw/v1/scopes/"+scope["scope_id"]!+"/artifacts/"+artifactID+"/versions/"+String(version)), artifactRecord = try XCTUnwrap(artifactWire["artifact"] as? [String:Any])
        XCTAssertEqual(artifactRecord["content_hash"] as? String,after["artifact_hash"] as? String); XCTAssertEqual(version,1)
        let body = try XCTUnwrap(artifactRecord["body"] as? String), hash = SHA256.hash(data:Data(body.utf8)).map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(hash,after["artifact_hash"] as? String)
        let evidenceAttachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:["before":before,"after":after,"artifact_hash":artifactRecord["content_hash"]!,"production_auth":false],options:.sortedKeys),uniformTypeIdentifier:"public.json"); evidenceAttachment.name = "r7-v5-original-ids-artifact-hash"; evidenceAttachment.lifetime = .keepAlways; add(evidenceAttachment)
        let artifact = app.buttons["chat.artifact.open."+artifactID]
        XCTAssertTrue(artifact.waitForExistence(timeout:10)); artifact.tap();XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v1");XCTAssertEqual(readerHash(app).label,"SHA-256 "+hash);attach(app,"r7-v5-artifact-version-provenance")
        let final = try await call("catpaw/testing/v1/fixture"), count = try XCTUnwrap(final["provider_requests"] as? Int)
        XCTAssertLessThanOrEqual(count,2); XCTAssertGreaterThanOrEqual(count,2)
    }
    func testAuthAccountSwitchAndRestartNeverExposeOtherDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["R7_AUTH_TEST_STORE"] = UUID().uuidString; app.launchEnvironment["R7_AUTH_TEST_SCENARIO"] = "account-isolation"; app.launch()
        func login(_ email:String) {
            let field = app.textFields["auth.email"]; XCTAssertTrue(field.waitForExistence(timeout:15)); field.tap(); field.typeText(email)
            let password = app.secureTextFields["auth.password"]; password.tap(); password.typeText("fixture-only"); app.buttons["auth.signIn"].tap()
            XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15))
        }
        func logout() { app.buttons["chat.settings"].tap(); let exit = app.buttons["auth.signOut"]; XCTAssertTrue(exit.waitForExistence(timeout:10)); exit.tap(); let confirm = app.buttons["确认退出"]; XCTAssertTrue(confirm.waitForExistence(timeout:5)); confirm.tap(); XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout:15)) }
        XCTAssertTrue(app.staticTexts["auth.fixture"].waitForExistence(timeout:15)); attach(app,"r7-explicit-fixture-login")
        login("a.test@example.invalid")
        let input = app.textViews["chat.input"]; input.tap(); input.typeText("Account A private synthetic draft")
        attach(app,"r7-account-a-private-draft"); logout(); login("b.test@example.invalid")
        XCTAssertFalse((input.value as? String)?.contains("Account A") == true); XCTAssertFalse(app.staticTexts["Account A private synthetic draft"].exists)
        attach(app,"r7-account-b-isolated-chat"); logout(); login("a.test@example.invalid")
        XCTAssertEqual(input.value as? String,"Account A private synthetic draft")
        app.terminate(); app.launch(); XCTAssertTrue(input.waitForExistence(timeout:20)); XCTAssertEqual(input.value as? String,"Account A private synthetic draft")
        XCTAssertFalse(app.textFields["auth.email"].exists); attach(app,"r7-validated-session-restart-account-a")
        logout(); app.terminate(); app.launch(); XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout:15)); XCTAssertFalse(input.exists)
        attach(app,"r7-logout-barrier-after-restart")
    }
    func testMissingProductionConfigurationShowsDisabledLogin() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout:15))
        XCTAssertFalse(app.textViews["chat.input"].exists); XCTAssertFalse(app.buttons["auth.signIn"].isEnabled)
        XCTAssertTrue(app.staticTexts["auth.error"].exists); attach(app,"r7-unconfigured-login-fails-closed")
    }
    func testActiveFollowupQueuePauseRemoveAndForegroundNoRedispatch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CF_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["CF_UI_TEST_SCENARIO"] = "active-followup"
        app.launch()
        let input = app.textViews["chat.input"], send = app.buttons["chat.send"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap(); input.typeText("First synthetic request stays active")
        send.tap()
        expectation(for: NSPredicate(format: "label == %@", "排队发送"), evaluatedWith: send); waitForExpectations(timeout: 10)
        input.tap(); input.typeText("Second pending message")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let summary=app.buttons["chat.pendingSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout:10));summary.tap()
        let pause = app.buttons["chat.followup.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        attach(app, "r6-active-native-followup-enqueued")
        pause.tap()
        let resume = app.buttons["chat.followup.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertFalse(resume.isEnabled)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.followup.remove.")).firstMatch
        XCTAssertTrue(remove.exists); remove.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: remove); waitForExpectations(timeout: 10)
        app.buttons["chat.followup.close"].tap()
        input.tap(); input.typeText("Third retained message")
        XCTAssertTrue(send.isEnabled); send.tap()
        XCTAssertTrue(summary.waitForExistence(timeout:10));summary.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        attach(app, "r6-native-queue-paused-after-removal")
        app.buttons["chat.followup.close"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["chat.unresolved"].waitForExistence(timeout: 15))
        XCTAssertTrue(summary.exists);summary.tap();XCTAssertTrue(resume.exists);XCTAssertFalse(resume.isEnabled)
        app.buttons["chat.followup.close"].tap()
        input.tap(); input.typeText("Must not dispatch while unknown")
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(app.otherElements.matching(identifier: "chat.userMessage").count + app.staticTexts.matching(identifier: "chat.userMessage").count, 1)
        attach(app, "r6-foreground-original-unknown-no-redispatch")
        app.buttons["chat.settings"].tap()
        app.buttons["connection.refresh"].tap()
        XCTAssertTrue(app.staticTexts["合成后端，无模型调用 · 请求次数：1"].waitForExistence(timeout: 10))
        attach(app, "r6-native-harness-one-dispatch-no-model")
    }
    func testChatFirstNoFallbackAndDraftSurvivesRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CF_UI_TEST_STORE"] = UUID().uuidString
        app.launch()
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["assistant.createDelegation"].exists)
        XCTAssertFalse(app.buttons["root.sidebar"].exists)
        input.tap(); input.typeText("Plan Friday's customer presentation")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 15))
        XCTAssertEqual(input.value as? String, "Plan Friday's customer presentation")
        XCTAssertFalse(app.descendants(matching:.any)["chat.assistantMessage"].exists)
        attach(app, "chat-unconfigured-input-preserved")
        app.buttons["chat.settings"].tap()
        let connection = app.descendants(matching: .any)["connection.state"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        XCTAssertTrue(connection.label.contains("未连接") || (connection.value as? String)?.contains("未连接") == true)
        attach(app, "model-connection-not-configured")
        app.buttons["完成"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        XCTAssertEqual(input.value as? String, "Plan Friday's customer presentation")
        app.buttons["chat.history"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.historyList"].waitForExistence(timeout: 10))
        attach(app, "native-conversation-history")
        app.buttons["完成"].tap()
        app.buttons["chat.new"].tap()
        let cleared = NSPredicate(format: "value != %@", "Plan Friday's customer presentation")
        expectation(for: cleared, evaluatedWith: input); waitForExpectations(timeout: 10)
        app.buttons["chat.history"].tap()
        let draftRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.history.row.", "Plan Friday's customer presentation")).firstMatch
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.row.")).count, 2)
        attach(app, "history-new-and-persistent-draft")
        draftRow.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Plan Friday's customer presentation")
        XCTAssertFalse(app.descendants(matching:.any)["chat.assistantMessage"].exists)
        attach(app, "restored-original-conversation")
    }

    /// Run with simctl appearance/content_size on the dedicated device.
    /// No cloud, signup, stored identity or model. System settings drive the UI.
    func testExperienceCaptureCurrentAppearance() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CF_UI_TEST_STORE"] = UUID().uuidString
        app.launch()
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:20))
        attach(app, "experience-chat")
        let controls = ["chat.history", "chat.new", "chat.settings", "chat.send", "chat.connection"]
        let frames = controls.map { id -> [String:Any] in
            let element = app.buttons[id]; let f = element.frame
            XCTAssertGreaterThanOrEqual(f.width, 44, id)
            XCTAssertGreaterThanOrEqual(f.height, 44, id)
            XCTAssertTrue(element.isHittable, id)
            return ["id":id,"x":f.minX,"y":f.minY,"width":f.width,"height":f.height,"enabled":element.isEnabled]
        }
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        XCTAssertEqual(input.label,"消息")
        let metadata = XCTAttachment(data:try JSONSerialization.data(withJSONObject:frames,options:.sortedKeys),uniformTypeIdentifier:"public.json")
        metadata.name = "experience-targets"; metadata.lifetime = .keepAlways; add(metadata)
        try app.performAccessibilityAudit(for:[.contrast,.textClipped,.sufficientElementDescription,.hitRegion])
        app.buttons["chat.settings"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["connection.state"].firstMatch.waitForExistence(timeout:10))
        attach(app, "experience-settings")
        app.buttons["完成"].tap()
        app.buttons["chat.history"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["chat.historyList"].firstMatch.waitForExistence(timeout:10))
        attach(app, "experience-history")
        app.buttons["完成"].tap()
        // Sheet drag must dismiss without a confirmation or data loss.
        app.buttons["chat.settings"].tap()
        let sheet = app.descendants(matching:.any)["connection.state"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout:10))
        let navigation = app.navigationBars["设置"]
        let origin = app.coordinate(withNormalizedOffset:.zero)
        let grabber = origin.withOffset(CGVector(dx:navigation.frame.midX,dy:navigation.frame.minY - 12))
        let bottom = origin.withOffset(CGVector(dx:navigation.frame.midX,dy:app.frame.maxY - 12))
        grabber.press(forDuration:0.05,thenDragTo:bottom)
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:sheet); waitForExpectations(timeout:5)
        XCTAssertTrue(input.isHittable)
        attach(app,"experience-sheet-dismissed")
        // Long text + native keyboard: draft and send stay above the keyboard.
        input.tap(); input.typeText(String(repeating:"Offline draft line. ",count:12))
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        XCTAssertLessThanOrEqual(app.buttons["chat.send"].frame.maxY,app.keyboards.firstMatch.frame.minY + 1)
        attach(app,"experience-keyboard-long-draft")
        app.terminate()
        app.launchEnvironment.removeValue(forKey:"CF_UI_TEST_STORE")
        app.launch()
        XCTAssertTrue(app.buttons["auth.startExperience"].waitForExistence(timeout:20))
        XCTAssertFalse(app.textFields["auth.email"].exists)
        attach(app, "experience-entry")
        app.swipeUp(); attach(app, "experience-entry-scrolled")
        XCTAssertTrue(app.buttons["auth.startExperience"].isHittable)
        try app.performAccessibilityAudit(for:[.contrast,.textClipped,.sufficientElementDescription,.hitRegion])
        app.terminate()
    }

    /// The dedicated simulator pasteboard is seeded with our 8001-character fixture.
    func testExperienceOversizedDraftInlineValidationAndRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CF_UI_TEST_STORE"] = UUID().uuidString
        app.launch()
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:20))
        input.press(forDuration:1)
        let paste = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@ OR label == %@", "粘贴", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout:5)); paste.tap()
        let validation = app.staticTexts["chat.validation"]
        XCTAssertTrue(validation.waitForExistence(timeout:10))
        XCTAssertEqual((input.value as? String)?.utf16.count,8001)
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        XCTAssertFalse(app.descendants(matching:.any)["chat.assistantMessage"].exists)
        attach(app,"experience-overlong-inline-error")
        XCUIDevice.shared.press(.home); app.terminate(); app.launch()
        XCTAssertTrue(input.waitForExistence(timeout:20))
        XCTAssertEqual((input.value as? String)?.utf16.count,8001)
        XCTAssertTrue(validation.exists); XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        attach(app,"experience-overlong-restored")
    }

    private func readerHash(_ app:XCUIApplication)->XCUIElement {
        let hash=app.staticTexts["chat.artifact.reader.hash"]
        let disclosure=app.descendants(matching:.any).matching(identifier:"chat.artifact.reader.history").firstMatch
        for _ in 0..<20 {
            if hash.exists {break}
            if disclosure.exists && disclosure.isHittable {disclosure.tap();break}
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(hash.waitForExistence(timeout:10),app.debugDescription);return hash
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
