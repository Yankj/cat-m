import Foundation
#if !MEMORY_PORTABLE
import XCTest
@testable import CatpawM
#endif

private enum MemoryTestFailure:Error {case expected(String)}
private func memoryCheck(_ value:Bool,_ description:String) throws {guard value else {throw MemoryTestFailure.expected(description)}}
private struct MemoryFixtureIDs {
    static let scope=UUID(uuidString:"62000000-0000-4000-8000-000000000001")!,subject=UUID(uuidString:"62000000-0000-4000-8000-000000000002")!,conversation=UUID(uuidString:"62000000-0000-4000-8000-000000000003")!
    static let reference=ConversationMemoryReference(scope:Profiles.user,serverScopeID:scope,subjectID:subject)
    static func state(generation:Int=1,enabled:Bool=false) throws -> ConversationMemorySnapshot {
        try JSONDecoder().decode(ConversationMemorySnapshot.self,from:JSONSerialization.data(withJSONObject:["schema_version":1,"contract":ConversationMemoryCodec.contract,"scope_id":scope.uuidString,"subject_id":subject.uuidString,"memory_generation":generation,"enabled":enabled,"claims":[],"candidates":[],"sources":[]]))
    }
    static func receipt(_ request:ConversationMemoryRequest) throws -> ConversationMemoryReceipt {
        let result:[String:Any]=["memory_generation":request.expected_memory_generation+1,"enabled":request.command.enabled ?? true,"status":request.command.type == .forget ? "purged":"active","claim_id":NSNull(),"version":NSNull(),"deletion_id":request.command.type == .forget ? UUID().uuidString as Any:NSNull(),"purge_scope":request.command.type == .forget ? "primary_memory_and_derived_index" as Any:NSNull(),"backups":request.command.type == .forget ? "not_verified" as Any:NSNull(),"source_id":NSNull()]
        let operation:[String:Any]=["operation_id":request.id.uuidString,"request_hash":try request.requestHash(),"expected_memory_generation":request.expected_memory_generation,"command_type":request.command.type.rawValue,"accepted_at":"2026-10-15T03:00:00.000Z","result":result]
        return try JSONDecoder().decode(ConversationMemoryReceipt.self,from:JSONSerialization.data(withJSONObject:["schema_version":1,"contract":ConversationMemoryCodec.contract,"scope_id":scope.uuidString,"subject_id":subject.uuidString,"operation":operation]))
    }
}
private actor MemoryFixtureBackend:ConversationMemoryBackend {
    var snapshot:ConversationMemorySnapshot
    var posts=0,reads=0,originals=0,closed=false,loseResponse=false
    var receipt:ConversationMemoryReceipt?
    var beforePost:(@Sendable(ConversationMemoryRequest)async throws->Void)?
    var readGate:CheckedContinuation<Void,Never>?,holdRead=false
    init() throws {snapshot=try MemoryFixtureIDs.state()}
    func readMemory(_ reference:ConversationMemoryReference) async throws -> ConversationMemorySnapshot {reads+=1;if holdRead {await withCheckedContinuation{readGate=$0}};return snapshot}
    func submitMemory(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt {
        posts+=1;try await beforePost?(request);let response=try MemoryFixtureIDs.receipt(request);receipt=response;snapshot=try MemoryFixtureIDs.state(generation:response.operation.result.memory_generation,enabled:response.operation.result.enabled)
        if loseResponse {throw URLError(.networkConnectionLost)};return response
    }
    func readMemoryOperation(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt {originals+=1;guard let receipt else {throw ConversationMemoryError.originalNotFound};return receipt}
    func readMemorySource(_ reference:ConversationMemoryReference,id:UUID) async throws -> ConversationMemorySource {throw ConversationMemoryError.unavailable}
    func close(){closed=true}
    func configureLoss(_ check:@escaping @Sendable(ConversationMemoryRequest)async throws->Void){loseResponse=true;beforePost=check}
    func stopLosing(){loseResponse=false;beforePost=nil}
    func pauseRead(){holdRead=true}
    func releaseRead(){readGate?.resume();readGate=nil;holdRead=false}
    func counts()->(Int,Int,Int){(posts,reads,originals)}
}
private enum MemoryChecks {
    static func repository(_ directory:URL) throws -> Repository {try Repository(persistence:FilePersistence(url:directory.appendingPathComponent("memory-synthetic.json")))}
    static func run() async throws {
        #if MEMORY_PORTABLE
        let wireURLs=CommandLine.arguments.dropFirst().prefix(2).map{URL(fileURLWithPath:$0)}
        let canonicalURL=URL(fileURLWithPath:CommandLine.arguments[3])
        #else
        let wireURLs=["memory-wire-v1","memory-wire-v2"].map{Bundle(for:ConversationMemoryTests.self).url(forResource:$0,withExtension:"json")!}
        let canonicalURL=Bundle(for:ConversationMemoryTests.self).url(forResource:"memory-canonical-v1",withExtension:"json")!
        #endif
        let golden=try JSONSerialization.jsonObject(with:Data(contentsOf:canonicalURL)) as! [String:Any]
        for row in golden["cases"] as! [[String:Any]] {
            let raw=Data((row["raw"] as! String).utf8),expected=Data((row["canonical"] as! String).utf8)
            let actual=try ConversationCanonicalJSON.data(raw)
            try memoryCheck(actual==expected,"Canonical UTF8 bytes differ from actual maintained Node encoder: "+(row["name"] as! String))
            try memoryCheck(bytesHash(actual)==row["sha256"] as? String,"Canonical SHA256 differs: "+(row["name"] as! String))
            if row["name"] as? String=="recorded_memory_numeric_request" {
                let request=try JSONDecoder().decode(ConversationMemoryRequest.self,from:raw)
                try memoryCheck(try request.requestHash()==row["sha256"] as? String,"Memory request still uses different number canonicalization")
                try memoryCheck(bytesHash(try ConversationMemoryCodec.encoded(request)) != row["sha256"] as? String,"The recorded numeric RED no longer exercises a serializer mismatch")
            }
        }
        for row in golden["invalid"] as! [[String:Any]] {
            do{_=try ConversationCanonicalJSON.data(Data((row["raw"] as! String).utf8),maxBytes:row["max_bytes"] as? Int ?? 16000);throw MemoryTestFailure.expected("Canonical prevalidation accepted "+(row["name"] as! String))}catch is MemoryTestFailure {throw MemoryTestFailure.expected("Canonical prevalidation accepted "+(row["name"] as! String))}catch{}
        }
        for wireURL in wireURLs {
        let wire=try JSONSerialization.jsonObject(with:Data(contentsOf:wireURL)) as! [String:Any]
        let request=try JSONDecoder().decode(ConversationMemoryRequest.self,from:JSONSerialization.data(withJSONObject:wire["request"]!))
        try memoryCheck(try request.requestHash()==wire["request_hash"] as? String,"Actual maintained Node wire hash differs from native encoding")
        let state=try JSONDecoder().decode(ConversationMemorySnapshot.self,from:JSONSerialization.data(withJSONObject:wire["state"]!))
        let actualReference=ConversationMemoryReference(scope:Profiles.user,serverScopeID:state.scope_id,subjectID:state.subject_id)
        try state.validate(actualReference)
        let actualReceipt=try JSONDecoder().decode(ConversationMemoryReceipt.self,from:JSONSerialization.data(withJSONObject:wire["receipt"]!));try actualReceipt.validate(actualReference,request:request)
        let sourceEnvelope=wire["source"] as! [String:Any],source=try JSONDecoder().decode(ConversationMemorySource.self,from:JSONSerialization.data(withJSONObject:sourceEnvelope["source"]!));try ConversationMemoryCodec.validateSource(source)
        try memoryCheck(state.claims.first?.source_id==source.id && state.claims.first?.source_hash==source.content_hash,"Actual source lineage differs")
        var correction=ConversationMemoryCommand(type:.correct);correction.conversation_id=request.command.conversation_id;correction.source_text=request.command.source_text;correction.claim=request.command.claim;correction.target_id=state.claims[0].id;correction.expected_version=state.claims[0].version;correction.allow_relearn=false;correction.sensitive_consent=false
        let corrected=try ConversationMemoryRequest(generation:state.memory_generation,command:correction)
        var receiptObject=wire["receipt"] as! [String:Any],operation=receiptObject["operation"] as! [String:Any],result=operation["result"] as! [String:Any]
        operation["operation_id"]=corrected.id.uuidString;operation["request_hash"]=try corrected.requestHash();operation["expected_memory_generation"]=corrected.expected_memory_generation;operation["command_type"]="correct"
        result["claim_id"]=correction.target_id!.uuidString;result["version"]=correction.expected_version!+1;result["source_id"]=UUID().uuidString;result["memory_generation"]=state.memory_generation+1
        operation["result"]=result;receiptObject["operation"]=operation
        let exactReceipt=try JSONDecoder().decode(ConversationMemoryReceipt.self,from:JSONSerialization.data(withJSONObject:receiptObject));try exactReceipt.validate(actualReference,request:corrected)
        for field in ["claim_id","version","source_id"] {
            var wrong=result;wrong[field]=field=="claim_id" ? UUID().uuidString as Any:field=="version" ? correction.expected_version!+2 as Any:NSNull()
            var badOperation=operation;badOperation["result"]=wrong;var bad=receiptObject;bad["operation"]=badOperation
            let invalidReceipt=try JSONDecoder().decode(ConversationMemoryReceipt.self,from:JSONSerialization.data(withJSONObject:bad))
            do{try invalidReceipt.validate(actualReference,request:corrected);throw MemoryTestFailure.expected("Correction accepted wrong "+field)}catch ConversationMemoryError.invalidResponse{}
        }
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-memory-portable-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let backend=try MemoryFixtureBackend(),repo=try repository(directory),reference=MemoryFixtureIDs.reference
        let service=ConversationMemoryService(repository:repo,reference:reference,backend:backend)
        do{_ = try await service.refresh();throw MemoryTestFailure.expected("Default admission must reject before network")}catch is CancellationError{}
        try memoryCheck(await backend.counts().1==0,"Default service performed network")
        var draft=ConversationMemoryDraft();draft.topic="Fictional reply language";draft.text="Use fictional concise replies";draft.workspaceWide=false
        let initialDraftEpoch=try await service.localState().draftEpoch
        try await service.saveDraft(draft,expectedDraftEpoch:initialDraftEpoch)
        let cold=ConversationMemoryService(repository:try repository(directory),reference:reference,backend:backend)
        try memoryCheck(try await cold.localState().draft==draft,"Cold review changed raw draft/scope")
        let other=ConversationMemoryService(repository:repo,reference:.init(scope:Profiles.user,serverScopeID:reference.serverScopeID,subjectID:UUID()),backend:backend)
        try memoryCheck(try await other.localState().draft.text.isEmpty,"Account partition exposed another subject's draft")
        await service.setAdmissionAllowed(true);let initial=try await service.refresh();try memoryCheck(initial.latest?.enabled==false,"Read auto-enabled memory")
        var command=ConversationMemoryCommand(type:.set_enabled);command.enabled=true
        await backend.configureLoss {request in
            let disk=try repository(directory);let snapshot=await disk.read(scope:Profiles.user)
            let preferences=snapshot.records.values.compactMap{record->Preference? in if case .preference(let p)=record.payload{return p};return nil}
            let journal=try preferences.map{try JSONDecoder().decode(ConversationMemoryLocalState.self,from:Data($0.value.utf8))}.first{$0.pending?.request.id==request.id}
            try memoryCheck(journal?.pending?.request==request,"POST began before durable exact command")
        }
        do{_ = try await service.submit(command);throw MemoryTestFailure.expected("Expected lost response")}catch is URLError{}
        let unknown=try await service.localState();try memoryCheck(unknown.pending != nil,"Lost response discarded original identity")
        let recovering=ConversationMemoryService(repository:try repository(directory),reference:reference,backend:backend);await recovering.setAdmissionAllowed(true)
        _ = try await recovering.readOriginal();let counts=await backend.counts();try memoryCheck(counts.0==1 && counts.2==1,"Cold recovery resent command")
        let recovered=try await recovering.localState();try memoryCheck(recovered.pending==nil && recovered.draft.text.isEmpty && recovered.latest==nil,"Applied command kept stale authority or private raw")
        do{try await recovering.saveDraft(draft,expectedDraftEpoch:initialDraftEpoch);throw MemoryTestFailure.expected("Old draft epoch wrote after applied command")}catch ConversationMemoryError.stale{}
        _=try await recovering.refresh();let beforeForget=try await recovering.localState();try await recovering.saveDraft(draft,expectedDraftEpoch:beforeForget.draftEpoch)
        await backend.stopLosing();var forget=ConversationMemoryCommand(type:.forget);forget.target_id=UUID();forget.expected_version=1;forget.no_relearn=true
        _=try await recovering.submit(forget)
        do{try await recovering.saveDraft(draft,expectedDraftEpoch:beforeForget.draftEpoch);throw MemoryTestFailure.expected("Late onDisappear/debounce resurrected forgotten raw")}catch ConversationMemoryError.stale{}
        try memoryCheck(try await recovering.localState().draft.text.isEmpty,"Forget kept old draft text")
        var invalid=ConversationMemoryCommand(type:.forget);invalid.target_id=UUID();invalid.expected_version=1
        do{try invalid.validate();throw MemoryTestFailure.expected("Missing explicit no-relearn must reject")}catch ConversationMemoryError.invalidResponse{}
        let lateBackend=try MemoryFixtureBackend();await lateBackend.pauseRead();let late=ConversationMemoryService(repository:repo,reference:reference,backend:lateBackend);await late.setAdmissionAllowed(true)
        let task=Task{try await late.refresh()}
        while await lateBackend.counts().1==0 {await Task.yield()}
        await late.invalidate();await lateBackend.releaseRead()
        do{_ = try await task.value;throw MemoryTestFailure.expected("Late account callback admitted")}catch is CancellationError{}
        try memoryCheck(await lateBackend.closed,"Invalidate failed to close existential backend")
        print("PASS memory: actual maintained Node v1/v2 wire/hash/source lineage, exact correction receipt and3negatives, default deny, durable draft/cold scope, account partition, disabled read, journal-before-POST, cold unknown GET-only, payload erasure/draft epoch afterforget, explicit forget guard, late callback fence/close")
    }
}
#if MEMORY_PORTABLE
@main struct MemoryPortableMain {static func main() async throws {try await MemoryChecks.run()}}
#else
final class ConversationMemoryTests:XCTestCase {
    func testDurableMemoryAuthorityAndUnknownRecovery() async throws {try await MemoryChecks.run()}
    @MainActor func testImmediateRefreshPreservesUnsavedRawAndScope() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("memory-refresh-synthetic-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let service=ConversationMemoryService(repository:try MemoryChecks.repository(directory),reference:MemoryFixtureIDs.reference,backend:try MemoryFixtureBackend())
        await service.setAdmissionAllowed(true)
        let model=ConversationMemoryModel(service:service,conversationID:MemoryFixtureIDs.conversation)
        await model.load(admissionAllowed:true);model.draft.topic="Unflushed fictional topic";model.draft.text="Newest unflushed fictional raw";model.draft.workspaceWide=true
        let expected=model.draft;model.stageDraft();await model.load(admissionAllowed:true)
        XCTAssertEqual(model.draft,expected,"Explicit refresh must not overwrite a live draft during the debounce window")
        await model.flush();let disk=try await service.localState();XCTAssertEqual(disk.draft,expected)
    }
    @MainActor func testStalePageCannotReopenClosedNetworkAdmission() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("memory-page-admission-synthetic-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let backend=try MemoryFixtureBackend(),service=ConversationMemoryService(repository:try MemoryChecks.repository(directory),reference:MemoryFixtureIDs.reference,backend:backend)
        let model=ConversationMemoryModel(service:service,conversationID:MemoryFixtureIDs.conversation)
        await model.load(admissionAllowed:true);let initial=await backend.counts();XCTAssertEqual(initial.1,0)
        await service.setAdmissionAllowed(true);await model.load(admissionAllowed:true)
        await service.setAdmissionAllowed(false);await model.load(admissionAllowed:true)
        let counts=await backend.counts();XCTAssertEqual(counts.1,1);XCTAssertFalse(model.loadedFresh)
    }
}
#endif
