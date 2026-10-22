import Foundation
import XCTest
@testable import cat

private actor MemoryApplicationBackend:ConversationMemoryBackend {
    let reference:ConversationMemoryReference
    var reads=0,posts=0,closes=0
    var hold=false
    var pending:CheckedContinuation<Void,Never>?
    init(_ reference:ConversationMemoryReference,hold:Bool=false){self.reference=reference;self.hold=hold}
    func readMemory(_ value:ConversationMemoryReference) async throws -> ConversationMemorySnapshot {
        reads+=1
        if hold {await withCheckedContinuation{pending=$0}}
        return .init(schema_version:1,contract:ConversationMemoryCodec.contract,scope_id:reference.serverScopeID,subject_id:reference.subjectID,memory_generation:1,enabled:false,claims:[],candidates:[],sources:[])
    }
    func submitMemory(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt {posts+=1;throw ConversationMemoryError.unavailable}
    func readMemoryOperation(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt {throw ConversationMemoryError.unavailable}
    func readMemorySource(_ reference:ConversationMemoryReference,id:UUID) async throws -> ConversationMemorySource {throw ConversationMemoryError.unavailable}
    func close(){closes+=1;hold=false;pending?.resume();pending=nil}
    func counters()->[Int] {[reads,posts,closes]}
}

@MainActor final class ConversationMemoryApplicationTests:XCTestCase {
    private func make(hold:Bool=false) throws -> (Repository,ConversationMemoryService,MemoryApplicationBackend,ConversationFirstModel) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("memory-host-"+UUID().uuidString)
        addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
        let repository=try Repository(persistence:FilePersistence(url:directory.appendingPathComponent("store.json")))
        let subject=UUID(),reference=ConversationMemoryReference(scope:Profiles.user,serverScopeID:UUID(),subjectID:subject)
        let backend=MemoryApplicationBackend(reference,hold:hold)
        let memory=ConversationMemoryService(repository:repository,reference:reference,backend:backend)
        let model=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository),memoryService:memory,subjectID:subject)
        return (repository,memory,backend,model)
    }
    private func rejects(_ action:() async throws -> Void) async {
        do {try await action();XCTFail("Admission must be closed")}catch{}
    }
    private func counts(_ backend:MemoryApplicationBackend,_ expected:[Int]) async {let values=await backend.counters();XCTAssertEqual(values,expected)}
    func testHostForegroundBackgroundAndLogoutControlMemoryAdmission() async throws {
        let (_,memory,backend,model)=try make()
        XCTAssertTrue(model.memoryConfigured)
        await rejects{_=try await memory.refresh()}
        await model.start();_=try await memory.refresh()
        await counts(backend,[1,0,0])
        let page=ConversationMemoryModel(service:memory,conversationID:model.conversationID)
        await model.suspend();await rejects{_=try await memory.refresh()}
        await page.load(admissionAllowed:true)
        await counts(backend,[1,0,0])
        await model.resumeForeground();_=try await memory.refresh()
        await counts(backend,[2,0,0])
        _=await model.deactivate();await rejects{_=try await memory.refresh()}
        await counts(backend,[2,0,1])
    }
    func testLateReadAfterHostDetachmentCannotPopulateAccountCache() async throws {
        let (repository,memory,backend,model)=try make(hold:true)
        await model.start()
        let reading=Task {try await memory.refresh()}
        for _ in 0..<100 {if await backend.counters().first==1 {break};try await Task.sleep(nanoseconds:10_000_000)}
        let first=await backend.counters().first;XCTAssertEqual(first,1)
        _=await model.deactivate()
        await rejects{_=try await reading.value}
        let snapshot=await repository.read(scope:Profiles.user)
        let cached=snapshot.records.values.filter {if case .preference(let p)=$0.payload {return p.key.hasPrefix("conversation_memory_v1:")};return false}
        XCTAssertTrue(cached.isEmpty,"A detached account cannot acquire a late memory snapshot")
        await counts(backend,[1,0,1])
    }
    func testHostRejectsMemoryServiceFromAnotherSubject() async throws {
        let (repository,memory,backend,_)=try make()
        let model=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository),memoryService:memory,subjectID:UUID())
        XCTAssertFalse(model.memoryConfigured);XCTAssertNil(model.memoryService)
        await model.start();await rejects{_=try await memory.refresh()}
        await counts(backend,[0,0,0]);_=await model.deactivate();await memory.invalidate()
    }
}
