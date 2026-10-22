import Foundation

/// Offline deterministic protocol tests. Does not create Auth, send HTTP or execute work.
@main enum ConversationRevisionWorkRunner {
    private struct RawGolden:Decodable {struct Item:Decodable {let raw:String,wrapper:String};let cases:[Item]}
    static var checks=0
    static func require(_ value:Bool,_ label:String) throws {guard value else {throw catError.invalid(label)};checks += 1;print("PASS: "+label)}
    static func rejected(_ label:String,_ body:() throws -> Void) throws {var failed=false;do {try body()} catch {failed=true};try require(failed,label)}
    static func json<T:Encodable>(_ value:T) throws -> [String:Any] {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]}
    static func data(_ value:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    static func changeRequest(_ request:ConversationTurnRequest,_ change:(inout [String:Any])->Void) throws -> ConversationTurnRequest {var value=try json(request);change(&value);return try JSONDecoder().decode(ConversationTurnRequest.self,from:data(value))}
    static func main() throws {
        guard CommandLine.arguments.count==2 else {throw catError.invalid("golden path required")}
        let raw=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),fixture=try ConversationStrictJSON.object(raw,maxBytes:500_000)
        let stringCases=try JSONDecoder().decode(RawGolden.self,from:raw).cases
        let cases=fixture["cases"] as! [[String:Any]],subject=UUID(uuidString:fixture["subject"] as! String)!,serverScope=UUID(uuidString:fixture["scope"] as! String)!,cid=UUID(uuidString:fixture["conversation"] as! String)!,operation=UUID(uuidString:fixture["turn"] as! String)!,message=UUID(uuidString:fixture["message"] as! String)!,decision=UUID(uuidString:fixture["decision"] as! String)!
        let localScope=DataScope(profileID:UUID(uuidString:"f0000000-0000-4000-8000-000000000001")!,workspaceID:UUID(uuidString:"f0000000-0000-4000-8000-000000000002")!)
        let binding=try JSONDecoder().decode(ConversationTaskBinding.self,from:data(fixture["binding"] as! [String:Any]))
        let target=try JSONDecoder().decode(ConversationArtifactContinuationIntent.self,from:data(fixture["target"] as! [String:Any]))
        let cap=ConversationAcceptedWorkCapability(available:true,routeHash:fixture["route_hash"] as? String,subjectID:subject,serverScopeID:serverScope,publicSourcesAvailable:true)
        let deadline=try ConversationAcceptedWorkCodec.instant("2026-10-15T05:30:00.000Z"),now=try ConversationAcceptedWorkCodec.instant("2026-10-15T05:00:00.000Z")
        let options=ConversationAcceptedWorkOptions(notAfter:deadline,executionBudgetMilliseconds:120_000,modelLimit:3,sourceLimit:2,toolPolicy:.publicSources)
        let authorization=try ConversationAcceptedWorkSelection(decisionID:decision,options:options,capability:cap)
        for (index,c) in cases.enumerated() {
            let text=stringCases[index].raw,selection=try ConversationRevisionWorkSelection(authorization:authorization,target:target,originalText:text)
            let request=ConversationTurnRequest(scope:localScope,conversationID:cid,threadID:"existing-conversation",operationID:operation,epoch:14,history:[.init(id:message,role:.user,content:text)],context:[.init(id:"user-context",text:"保留来源与结论边界\nemoji 🐾")],continuation:target,continuationOriginalBinding:binding,continuationSubjectID:subject)
            let intent=try ConversationRevisionWorkIntent(request:request,selection:selection,expectedRevision:7,expectedGrantEpoch:2)
            let actualWrapper=try intent.wrapper(),expectedWrapper=Data(stringCases[index].wrapper.utf8)
            if actualWrapper != expectedWrapper {try actualWrapper.write(to:URL(fileURLWithPath:".build/revision-work-tests/actual-wrapper-\(index).json"));try expectedWrapper.write(to:URL(fileURLWithPath:".build/revision-work-tests/expected-wrapper-\(index).json"))}
            try require(actualWrapper==expectedWrapper,"Node canonical wrapper raw case \(index)")
            try require(intent.inputHash==c["input_hash"] as? String && intent.targetHash==c["target_hash"] as? String && (try intent.workIntentHash)==c["work_intent_hash"] as? String,"Node input/target/work hashes case \(index)")
            try intent.validateForFirstPost(request:request,capability:cap,now:now)
            try rejected("expired first POST denied case \(index)"){try intent.validateForFirstPost(request:request,capability:cap,now:deadline)}
            let frozen=try JSONEncoder().encode(intent),restored=try ConversationRevisionWorkIntent.restore(frozen,request:request)
            try require(restored.operationID==operation && restored.selection.decisionID==decision && (try restored.wrapper())==intent.wrapper(),"unknown restore keeps exact operation/decision/window/wrapper case \(index)")
            let call=c["call_id"] as! String,accepted=try ConversationRevisionWorkReceipt.decode(data(c["accepted"] as! [String:Any])),completed=try ConversationRevisionWorkReceipt.decode(data(c["completed"] as! [String:Any]))
            try accepted.validate(request:request,intent:intent,callID:call,sourceAuthHash:fixture["source_auth_hash"] as? String)
            try completed.validate(request:request,intent:intent,callID:call,sourceAuthHash:fixture["source_auth_hash"] as? String)
            try require(try accepted.immutableHash()==completed.immutableHash() && accepted.receipt_hash==completed.receipt_hash,"Node accepted/completed immutable receipt identity case \(index)")
            var optionalNil=c["accepted"] as! [String:Any],inner=optionalNil["revision"] as! [String:Any];inner["result_reference"]=NSNull();inner["result_receipt_hash"]=NSNull();optionalNil["revision"]=inner
            try ConversationRevisionWorkReceipt.decode(data(optionalNil)).validate(request:request,intent:intent,callID:call)
            try require(true,"existing optional nil inner fields compatible case \(index)")
            for key in ["decision_id","input_hash","target_hash","work_intent_hash","grant_receipt_hash"] {
                var bad=c["accepted"] as! [String:Any];bad[key] = key=="decision_id" ? UUID().uuidString.lowercased() : String(repeating:"9",count:64)
                if key != "grant_receipt_hash" {let parsed=try ConversationRevisionWorkReceipt.decode(data(bad));bad["receipt_hash"]=try parsed.immutableHash()}
                try rejected("receipt \(key) mismatch case \(index)"){try ConversationRevisionWorkReceipt.decode(data(bad)).validate(request:request,intent:intent,callID:call)}
            }
            var wrongGrant=c["accepted"] as! [String:Any],grant=wrongGrant["grant_reference"] as! [String:Any];grant["grant_id"]=UUID().uuidString.lowercased();wrongGrant["grant_reference"]=grant;wrongGrant["receipt_hash"]=try ConversationRevisionWorkReceipt.decode(data(wrongGrant)).immutableHash()
            try rejected("different new grant even with recalculated outer hash case \(index)"){try ConversationRevisionWorkReceipt.decode(data(wrongGrant)).validate(request:request,intent:intent,callID:call)}
            var wrongInner=c["accepted"] as! [String:Any],r=wrongInner["revision"] as! [String:Any];r["scope_id"]=UUID().uuidString.lowercased();wrongInner["revision"]=r
            var parsed=try ConversationRevisionWorkReceipt.decode(data(wrongInner));r["receipt_hash"]=try parsed.revision.immutableHash();wrongInner["revision"]=r;parsed=try ConversationRevisionWorkReceipt.decode(data(wrongInner));wrongInner["receipt_hash"]=try parsed.immutableHash()
            try rejected("foreign inner scope with both hashes recalculated case \(index)"){try ConversationRevisionWorkReceipt.decode(data(wrongInner)).validate(request:request,intent:intent,callID:call)}
            for path in ["outer","grant","reference","plan"] {var extra=c["accepted"] as! [String:Any];switch path {
                case "outer":extra["execution_authorized"]=true
                case "grant":var g=extra["grant_reference"] as! [String:Any];g["scope"]=NSNull();extra["grant_reference"]=g
                default:var r=extra["revision"] as! [String:Any];let k=path=="reference" ? "base_reference":"base_plan_reference";var ref=r[k] as! [String:Any];ref["execution_authorized"]=true;r[k]=ref;extra["revision"]=r
                };try rejected("unknown authority field \(path) case \(index)"){_=try ConversationRevisionWorkReceipt.decode(data(extra))}}
            var boolean=c["accepted"] as! [String:Any];boolean["schema_version"]=true
            try rejected("boolean cannot become integer schema case \(index)"){_=try ConversationRevisionWorkReceipt.decode(data(boolean))}
            let encoded=String(data:try data(c["accepted"] as! [String:Any]),encoding:.utf8)!
            try rejected("duplicate receipt field rejected case \(index)"){_=try ConversationRevisionWorkReceipt.decode(Data(("{\"schema_version\":1,"+encoded.dropFirst()).utf8))}
            let changedText=try changeRequest(request){row in var h=row["history"] as! [[String:Any]];h[h.count-1]["content"]=text+" revised";row["history"]=h}
            try rejected("full original text immutable case \(index)"){try intent.validate(request:changedText)}
            let changedContext=try changeRequest(request){$0["context"]=[["id":"user-context","text":"changed"]]}
            try rejected("explicit context immutable case \(index)"){try intent.validate(request:changedContext)}
            let foreign=try changeRequest(request){$0["continuationSubjectID"]=UUID().uuidString}
            try rejected("foreign account cannot reuse frozen revision case \(index)"){try intent.validate(request:foreign)}
            let wrongTarget=try changeRequest(request){row in var t=row["continuation"] as! [String:Any];t["expected_plan_revision"]=4;row["continuation"]=t}
            try rejected("CAS target cannot change under original wrapper case \(index)"){try intent.validate(request:wrongTarget)}
            try rejected("image bytes not allowed case \(index)"){_=try ConversationRevisionWorkIntent(request:request.withImageBytes(Data([1])),selection:selection,expectedRevision:7,expectedGrantEpoch:2)}
            let explain=ConversationArtifactContinuationIntent(intent:.explainReport,runID:target.runID,taskID:target.taskID,artifactReference:target.artifactReference,expectedGrantEpoch:target.expectedGrantEpoch,expectedPlanRevision:target.expectedPlanRevision,expectedPlanHash:target.expectedPlanHash)
            try rejected("explain does not acquire revision work grant case \(index)"){_=try ConversationRevisionWorkSelection(authorization:authorization,target:explain,originalText:text)}
            let normal=ConversationTurnRequest(scope:localScope,conversationID:cid,threadID:nil,operationID:operation,epoch:14,history:request.history),ordinary=try ConversationAcceptedWorkIntent(request:normal,selection:authorization,expectedRevision:7,expectedGrantEpoch:2)
            let mixed=ConversationTurnRequest(scope:localScope,conversationID:cid,threadID:nil,operationID:operation,epoch:14,history:request.history,continuation:target,continuationOriginalBinding:binding,continuationSubjectID:subject,acceptedWork:ordinary)
            try rejected("ordinary accepted work and revision work never combine case \(index)"){_=try ConversationRevisionWorkIntent(request:mixed,selection:selection,expectedRevision:7,expectedGrantEpoch:2)}
            try rejected("old ordinary accepted-work continuation guard remains case \(index)"){_=try ConversationAcceptedWorkIntent(request:request,selection:authorization,expectedRevision:7,expectedGrantEpoch:2)}
            if index==0 {
                let changedCap=ConversationAcceptedWorkCapability(available:true,routeHash:String(repeating:"7",count:64),subjectID:subject,serverScopeID:serverScope,publicSourcesAvailable:true)
                try rejected("changed route before dispatch must be reviewed again"){try intent.validateForFirstPost(request:request,capability:changedCap,now:now)}
                let noSources=ConversationAcceptedWorkCapability(available:true,routeHash:cap.routeHash,subjectID:subject,serverScopeID:serverScope,publicSourcesAvailable:false)
                try rejected("public source grant cannot silently use unavailable capability"){try intent.validateForFirstPost(request:request,capability:noSources,now:now)}
                let oldDecision=try ConversationAcceptedWorkSelection(decisionID:binding.operation_id,options:options,capability:cap),bad=try ConversationRevisionWorkSelection(authorization:oldDecision,target:target,originalText:text)
                try rejected("new decision must differ from old operation"){_=try ConversationRevisionWorkIntent(request:request,selection:bad,expectedRevision:7,expectedGrantEpoch:2)}
                let wrongScope=try changeRequest(request){var row=$0["scope"] as! [String:Any];row["workspaceID"]=UUID().uuidString;$0["scope"]=row}
                try rejected("local account partition mismatch rejected"){try intent.validate(request:wrongScope)}
                try require(ConversationRevisionWorkCodec.toolName=="revise_current_report_work_v1" && ConversationRevisionWorkCodec.contract=="catpaw.task-revision-work.v1","specific versioned tool and route contract")
            }
        }
        print("PASS revision-work portable: \(checks) assertions / \(cases.count) Node golden cases; no HTTP/Auth/model/device effects")
    }
}
