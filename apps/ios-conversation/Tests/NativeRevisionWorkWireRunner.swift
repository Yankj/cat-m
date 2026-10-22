import Foundation

/// Replays actual maintained-handler bytes over a Root-owned loopback fixture.
/// This runner uses fixed recorded IDs. It creates no real Auth/model/source calls.
private struct RevisionWireCredentials:NativeChatSessionCredentials {
    func authorization(scope:DataScope) async throws -> String {"Bearer explicit-wire-test-only"}
}
private struct RevisionWireStrings:Decodable {
    struct Request:Decodable {struct Turn:Decodable {struct Message:Decodable {let id:UUID,text:String};let message:Message};let turn:Turn}
    struct Envelope:Decodable {struct Conversation:Decodable {struct Message:Decodable {let id:UUID,role:String,content:String};let messages:[Message]};let conversation:Conversation}
    let request:Request,conversation_before:Envelope
}
@main private enum NativeRevisionWorkWireRunner {
    static func check(_ condition:Bool,_ label:String) throws {guard condition else {throw catError.invalid(label)};print("PASS: "+label)}
    static func data(_ value:Any) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    static func stats(_ origin:URL) async throws -> [String:Int] {
        var request=URLRequest(url:origin.appendingPathComponent("wire-test-stats"));request.setValue("Bearer explicit-wire-test-only",forHTTPHeaderField:"Authorization")
        let (bytes,response)=try await URLSession.shared.data(for:request);guard (response as? HTTPURLResponse)?.statusCode==200 else {throw ConversationSessionError.invalidEvent};return try JSONDecoder().decode([String:Int].self,from:bytes)
    }
    static func mode(_ name:String,origin:URL) async throws {
        var request=URLRequest(url:origin.appendingPathComponent("wire-test-mode"));request.httpMethod="POST";request.setValue("Bearer explicit-wire-test-only",forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try data(["mode":name])
        let (_,response)=try await URLSession.shared.data(for:request);guard (response as? HTTPURLResponse)?.statusCode==200 else {throw ConversationSessionError.invalidEvent}
    }
    static func main() async throws {
        guard CommandLine.arguments.count==4,let origin=URL(string:CommandLine.arguments[1]),origin.scheme=="http",origin.host=="127.0.0.1" else {throw catError.invalid("explicit loopback origin, evidence directory and maintained fixture required")}
        let output=URL(fileURLWithPath:CommandLine.arguments[2]),bytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])),fixture=try ConversationStrictJSON.object(bytes,maxBytes:2_000_000),strings=try JSONDecoder().decode(RevisionWireStrings.self,from:bytes)
        let scope=fixture["scope"] as! [String:Any],principal=fixture["principal"] as! [String:Any],wrapper=fixture["request"] as! [String:Any],turn=wrapper["turn"] as! [String:Any],work=wrapper["work"] as! [String:Any],limits=work["limits"] as! [String:Int],snapshot=(fixture["turn"] as! [String:Any])["turn"] as! [String:Any]
        let sid=UUID(uuidString:scope["scope_id"] as! String)!,subject=UUID(uuidString:principal["subject_id"] as! String)!,cid=UUID(uuidString:fixture["conversation_id"] as! String)!,operation=UUID(uuidString:turn["turn_id"] as! String)!
        let target=try JSONDecoder().decode(ConversationArtifactContinuationIntent.self,from:data(wrapper["target"]!)),original=(fixture["original_turn"] as! [String:Any])["turn"] as! [String:Any],binding=try JSONDecoder().decode(ConversationTaskBinding.self,from:data((original["task_bindings"] as! [[String:Any]])[0]))
        let admitted=(snapshot["revision_work_intent"] as! [String:Any])["admitted_at"] as! String,clock=try ConversationAcceptedWorkCodec.instant(admitted)
        let options=ConversationAcceptedWorkOptions(notAfter:try ConversationAcceptedWorkCodec.instant(work["not_after"] as! String),executionBudgetMilliseconds:work["execution_budget_ms"] as! Int,modelLimit:limits["model"]!,sourceLimit:limits["source"]!,toolPolicy:ConversationAcceptedWorkToolPolicy(rawValue:work["tool_policy"] as! String)!)
        let expectedOuter=try ConversationRevisionWorkReceipt.decode(data(fixture["operation"]!)),baseEnvelope=fixture["base_artifact"] as! [String:Any],base=baseEnvelope["artifact"] as! [String:Any]
        try check(base["is_current"] as? Bool==true && base["editable"] as? Bool==false,"fixture records current base after old source expired; manual edit remains false")
        func backend() throws -> NativeChatHTTPBackend {NativeChatHTTPBackend(configuration:try .init(origin:origin,localScope:Profiles.user,serverScopeID:sid,allowInjectedTestProvider:true,expectedSubjectID:subject),credentials:RevisionWireCredentials(),acceptedWorkClock:{clock})}
        for name in ["valid","drop","badouter"] {
            try await mode(name,origin:origin);let before=try await stats(origin),native=try backend(),capability=try await native.revisionWorkCapability(scope:Profiles.user,conversationID:cid)
            try check(capability.available && capability.subjectID==subject && capability.serverScopeID==sid,"\(name) exact versioned readiness authorizes only fixed scope/subject")
            let authorization=try ConversationAcceptedWorkSelection(decisionID:UUID(uuidString:work["decision_id"] as! String)!,options:options,capability:capability),selection=try ConversationRevisionWorkSelection(authorization:authorization,target:target,originalText:strings.request.turn.message.text)
            var history=strings.conversation_before.conversation.messages.map{ConversationTranscriptMessage(id:$0.id,role:ConversationTranscriptMessage.Role(rawValue:$0.role)!,content:$0.content)}
            history.append(.init(id:stableID("conversation-tool-result-\(binding.turn_id)-\(binding.call_id)"),role:.tool,content:String(decoding:try ConversationTaskActionJSON.encoded(binding),as:UTF8.self),toolCallID:binding.call_id,toolName:"delegate_plan_v1"))
            history.append(.init(id:strings.request.turn.message.id,role:.user,content:selection.originalText))
            let provisional=ConversationTurnRequest(scope:Profiles.user,conversationID:cid,threadID:cid.uuidString.lowercased(),operationID:operation,epoch:1,history:history,context:(turn["context"] as! [[String:String]]).map{.init(id:$0["id"]!,text:$0["text"]!)},continuation:target,continuationOriginalBinding:binding,continuationSubjectID:subject)
            let intent=try await native.freezeRevisionWork(provisional,selection:selection),request=try provisional.withRevisionWork(intent)
            try check(try intent.wrapper()==ConversationCanonicalJSON.data(data(wrapper),maxBytes:48000),"\(name) frozen POST is the exact maintained request bytes and original UUIDs")
            let file=output.appendingPathComponent(name+".json"),repository=try Repository(persistence:FilePersistence(url:file)),service=ConversationSessionService(repository:repository,backend:native)
            _=try await service.create(scope:Profiles.user,id:cid)
            var session=ConversationSession(scope:Profiles.user,conversationID:cid),goal=ConversationGoalProjection(id:binding.task_id,revision:binding.delegation_revision,title:"Recorded original report",state:.unknown,summary:"Old finite source expired",updatedAt:clock)
            goal.binding=binding;goal.sourceAuthorizationCurrent=false;goal.revisionRequiresNewWork=true;goal.revisionWorkPolicy = .init(toolPolicy:options.toolPolicy,sourceCount:limits["source"]!);goal.planReference = .init(revision:target.expectedPlanRevision,planHash:target.expectedPlanHash)
            let first=(fixture["artifacts"] as! [[String:Any]]).first{row in (row["artifact"] as? [String:Any])?["version"] as? Int==target.artifactReference.version}!,record=first["artifact"] as! [String:Any],body=record["body"] as! String,parsed=try ConversationStrictJSON.object(Data(body.utf8)),content=parsed["data"] as! [String:Any]
            goal.artifactHistory=[.init(id:target.artifactReference.artifactID,version:target.artifactReference.version,contentHash:target.artifactReference.contentHash,body:body,title:parsed["title"] as! String,summary:parsed["summary"] as! String,content:content["content"] as! String)]
            session.goals[goal.id]=goal;session.messages=history;session.turns=[.init(id:operation,request:request,state:.notSent,lastSequence:0,error:"Explicitly frozen original request")]
            let journal=try await repository.record(stableID("conversation-first-journal-\(cid)"),scope:Profiles.user),encoded=try JSONEncoder().encode(session)
            try await repository.commit(scope:Profiles.user,mutations:[.update(journal.id,journal.header.revision,.preference(.init(key:"conversation_session:\(cid)",value:String(decoding:encoded,as:UTF8.self))))])
            var failed=false;do{_=try await service.send(scope:Profiles.user,conversationID:cid,text:selection.originalText,operationID:operation,context:request.context,continuation:target,revisionWork:selection)}catch{failed=true}
            var saved=try await service.read(scope:Profiles.user,conversationID:cid)
            try check(saved.goals.count==1 && saved.goals[binding.task_id]?.binding==binding && saved.turns.count==1,"\(name) same original Task/run/binding and one durable operation")
            if name=="valid" {try check(!failed && saved.turns.last?.state == .completed,"valid actual HTTP/SSE reaches durable completion")}
            else {try check(failed && saved.unresolved?.id==operation && saved.unresolved?.request.revisionWork==intent,"\(name) response loss/tamper remains original unknown")}
            await native.close()
            let coldNative=try backend(),cold=ConversationSessionService(repository:try Repository(persistence:FilePersistence(url:file)),backend:coldNative)
            var readFailed=false;do{try await cold.observe(scope:Profiles.user,conversationID:cid)}catch{readFailed=true}
            saved=try await cold.read(scope:Profiles.user,conversationID:cid)
            if name=="badouter" {
                try check(readFailed && saved.unresolved?.id==operation && saved.turns.last?.revisionWorkReceipt==nil && saved.goals[binding.task_id]?.sourceAuthorizationCurrent==false,"tampered outer is rejected on POST and original GET; old false fence stays")
            } else {
                try check(!readFailed && saved.turns.last?.state == .completed && saved.turns.last?.revisionWorkReceipt?.receipt_hash==expectedOuter.receipt_hash,"\(name) cold original GET validates same outer/new-grant identity")
                let actual=saved.goals[binding.task_id]!
                try check(actual.sourceAuthorizationCurrent==true && actual.state == .completed && actual.artifacts.contains{ConversationArtifactVersionReference(ConversationArtifactIdentity($0))==expectedOuter.revision.result_reference},"\(name) only verified new v2 receipt unlocks old false fence and exact new report")
            }
            _=try await cold.send(scope:Profiles.user,conversationID:cid,text:selection.originalText,operationID:operation,context:request.context,continuation:target,revisionWork:selection)
            let after=try await stats(origin)
            try check(after["turnPosts"]! - before["turnPosts"]! == 1 && after["turnReads"]!>before["turnReads"]!,"\(name) one POST only; cold recovery and duplicate submit only observe original UUID")
            if name != "badouter" {try check(after["operationReads"]!>before["operationReads"]!,"\(name) actual original operation GET verifies full v2 envelope")}
            await coldNative.close()
        }
        print("PASS native revision-work wire: valid / drop cold GET / badouter; maintained-handler replay only, no real Auth/model/source/device proof")
    }
}
