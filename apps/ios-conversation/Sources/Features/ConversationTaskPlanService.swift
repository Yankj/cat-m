import Foundation

public struct ConversationTaskPlanDraft:Codable,Sendable,Equatable {
    public let baseRevision:Int
    public let basePlanHash:String
    public var goal:String
    public var requirements:String
    public init(baseRevision:Int,basePlanHash:String,goal:String,requirements:String) {self.baseRevision=baseRevision;self.basePlanHash=basePlanHash;self.goal=goal;self.requirements=requirements}
}
public struct ConversationTaskPlanSubmission:Codable,Sendable {
    public enum State:String,Codable,Sendable {case unknown,pending,applied,rejected,notSent}
    public let request:ConversationTaskPlanAmendRequest
    public var state:State
    public var message:String?
}
public struct ConversationTaskPlanLocalState:Codable,Sendable {
    public var snapshot:ConversationTaskPlanSnapshot?
    public var drafts:[String:ConversationTaskPlanDraft]=[:]
    public var activeDraftRevision:Int?
    public var submission:ConversationTaskPlanSubmission?
    public init() {}
    public var draft:ConversationTaskPlanDraft? {activeDraftRevision.flatMap{drafts[String($0)]}}
    public var hasUnresolvedSubmission:Bool {submission.map{[.unknown,.pending].contains($0.state)} ?? false}
}
/// Persists local editing and original submission identity. The backend owns plan/application facts.
public actor ConversationTaskPlanService {
    public nonisolated let scope:DataScope
    nonisolated let localDraftDrains:ConversationLocalDraftDrains
    private let repository:Repository
    private let backend:any ConversationTaskPlanBackend
    private var admitted=true
    private var generation=0
    private var invalidated=false
    private var closing=false
    private var drainSucceeded=true
    private var teardownWaiters:[CheckedContinuation<Bool,Never>]=[]
    private var active:Set<UUID>=[]
    private var locked=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    public init(repository:Repository,scope:DataScope = Profiles.user,backend:any ConversationTaskPlanBackend = UnconfiguredConversationTaskPlanBackend()) {self.repository=repository;self.scope=scope;self.backend=backend;localDraftDrains=ConversationLocalDraftDrains(scope:scope)}
    public nonisolated func registerLocalDraftFlusher(_ flusher:@escaping @Sendable () async -> Void)->UUID {
        let id=UUID();_=localDraftDrains.register(id,scope:scope){await flusher();return true};return id
    }
    public nonisolated func unregisterLocalDraftFlusher(_ id:UUID){localDraftDrains.unregister(id)}
    public func setAdmissionAllowed(_ allowed:Bool) async {
        if !allowed {generation += 1};admitted=allowed && !invalidated && !closing
        if !allowed {await lock();unlock()}
    }
    @discardableResult public func invalidate() async -> Bool {
        if invalidated {return drainSucceeded}
        if closing {return await withCheckedContinuation{teardownWaiters.append($0)}}
        generation += 1;admitted=false;closing=true
        let drains=localDraftDrains.closeAndSnapshot()
        for drain in drains {if !(await drain()) {drainSucceeded=false}}
        // Accepted local tickets may finish while closing. No HTTP call holds this lock.
        await lock();invalidated=true;localDraftDrains.finish();unlock()
        let result=drainSucceeded;teardownWaiters.forEach{$0.resume(returning:result)};teardownWaiters=[];return result
    }
    public func localState(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanLocalState {try await load(reference).0}
    public func refresh(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanLocalState {
        guard admitted else {throw ConversationTaskPlanError.notConfigured}
        let epoch=generation
        let state=try await load(reference).0
        guard admitted,generation==epoch,!invalidated else {throw CancellationError()}
        if let submission=state.submission,state.hasUnresolvedSubmission {
            let envelope=try await backend.readAmendment(reference,operationID:submission.request.operationID)
            return try await accept(envelope,reference:reference,request:submission.request,generation:epoch)
        }
        let envelope=try await backend.readPlan(reference)
        return try await accept(envelope,reference:reference,generation:epoch)
    }
    public func saveDraft(_ reference:ConversationTaskPlanReference,draft:ConversationTaskPlanDraft) async throws {
        guard !closing,!invalidated else {throw CancellationError()}
        try await saveAcceptedDraft(reference,draft:draft)
    }
    func saveDraft(_ reference:ConversationTaskPlanReference,draft:ConversationTaskPlanDraft,ticket:ConversationLocalDraftTicket) async throws {
        guard !invalidated,reference.scope==scope,localDraftDrains.consume(ticket) else {throw CancellationError()}
        try await saveAcceptedDraft(reference,draft:draft)
    }
    private func saveAcceptedDraft(_ reference:ConversationTaskPlanReference,draft:ConversationTaskPlanDraft) async throws {
        await lock();defer{unlock()}
        var (state,record)=try await load(reference)
        guard draft.baseRevision>0,draft.basePlanHash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,draft.goal.utf16.count<=8000,draft.requirements.utf16.count<=8000 else {throw ConversationTaskPlanError.invalidResponse}
        state.drafts[String(draft.baseRevision)]=draft;state.activeDraftRevision=draft.baseRevision
        try await save(state,record:record,reference:reference)
    }
    public func discardDraft(_ reference:ConversationTaskPlanReference) async throws {
        await lock();defer{unlock()}
        var (state,record)=try await load(reference)
        if let revision=state.activeDraftRevision {state.drafts.removeValue(forKey:String(revision))};state.activeDraftRevision=nil
        try await save(state,record:record,reference:reference)
    }
    public func rebaseDraft(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanLocalState {
        await lock();defer{unlock()}
        var (state,record)=try await load(reference)
        guard let snapshot=state.snapshot,let draft=state.draft,!state.hasUnresolvedSubmission else {throw ConversationTaskPlanError.busy}
        let next=ConversationTaskPlanDraft(baseRevision:snapshot.acceptedRevision,basePlanHash:snapshot.acceptedPlanHash,goal:draft.goal,requirements:draft.requirements)
        state.drafts[String(next.baseRevision)]=next;state.activeDraftRevision=next.baseRevision
        try await save(state,record:record,reference:reference);return state
    }
    public func submit(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanLocalState {
        guard admitted,!active.contains(reference.id) else {throw ConversationTaskPlanError.busy}
        active.insert(reference.id);defer{active.remove(reference.id)}
        let epoch=generation
        await lock()
        let request:ConversationTaskPlanAmendRequest
        do {
            var (state,record)=try await load(reference)
            guard admitted,!state.hasUnresolvedSubmission,let snapshot=state.snapshot,let draft=state.draft else {throw ConversationTaskPlanError.busy}
            guard snapshot.editable else {throw ConversationTaskPlanError.notEditable}
            guard draft.baseRevision==snapshot.acceptedRevision,draft.basePlanHash==snapshot.acceptedPlanHash else {throw ConversationTaskPlanError.staleDraft}
            var content=snapshot.content;content.goal=draft.goal;content.requirements=draft.requirements;try content.validate()
            request=ConversationTaskPlanAmendRequest(operationID:UUID(),expectedRevision:draft.baseRevision,expectedPlanHash:draft.basePlanHash,expectedGrantEpoch:reference.binding.grant_epoch,content:content)
            // Save before HTTP. A crash between this commit and dispatch must reconcile this ID.
            state.submission=ConversationTaskPlanSubmission(request:request,state:.unknown,message:nil)
            try await save(state,record:record,reference:reference,epoch:epoch);unlock()
        } catch {unlock();throw error}
        do {
            guard admitted,generation==epoch,!invalidated else {throw ConversationDispatchFailure.notSent(reason:ConversationTaskPlanError.notConfigured.localizedDescription)}
            let envelope=try await backend.amendPlan(reference,request:request)
            return try await accept(envelope,reference:reference,request:request,generation:epoch)
        } catch {
            guard generation==epoch,!invalidated else {throw error}
            await lock();defer{unlock()}
            var (state,record)=try await load(reference)
            if state.submission?.request.operationID==request.operationID {
                state.submission?.state = error is ConversationDispatchFailure ? .notSent : (Self.isConflict(error) ? .rejected : .unknown)
                state.submission?.message=error.localizedDescription
                try await save(state,record:record,reference:reference,epoch:epoch)
            }
            throw error
        }
    }
    private func accept(_ envelope:ConversationTaskPlanEnvelope,reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest?=nil,generation epoch:Int) async throws -> ConversationTaskPlanLocalState {
        guard admitted,generation==epoch,!invalidated else {throw CancellationError()}
        guard envelope.schemaVersion==1,envelope.contract=="catpaw.task-plan.v1" else {throw ConversationTaskPlanError.invalidResponse}
        try envelope.plan.validate(reference:reference)
        if let request {
            guard let receipt=envelope.amendment,receipt.operationID==request.operationID,
                  receipt.acceptedRevision==request.expectedRevision+1,try receipt.acceptedPlanHash==request.content.canonicalHash(),
                  envelope.plan.acceptedRevision>=receipt.acceptedRevision else {throw ConversationTaskPlanError.invalidResponse}
            if receipt.state == .applied {guard envelope.plan.appliedRevision>=receipt.acceptedRevision else {throw ConversationTaskPlanError.invalidResponse}}
            if envelope.plan.acceptedRevision==receipt.acceptedRevision {guard envelope.plan.acceptedPlanHash==receipt.acceptedPlanHash,receipt.state==envelope.plan.applicationState else {throw ConversationTaskPlanError.invalidResponse}}
        } else {guard envelope.amendment==nil else {throw ConversationTaskPlanError.invalidResponse}}
        await lock();defer{unlock()}
        guard admitted,generation==epoch,!invalidated else {throw CancellationError()}
        var (state,record)=try await load(reference)
        if let old=state.snapshot {
            guard envelope.plan.acceptedRevision>=old.acceptedRevision,envelope.plan.appliedRevision>=old.appliedRevision,
                  envelope.plan.acceptedRevision != old.acceptedRevision || envelope.plan.acceptedPlanHash==old.acceptedPlanHash,
                  envelope.plan.appliedRevision != old.appliedRevision || envelope.plan.appliedPlanHash==old.appliedPlanHash else {throw ConversationTaskPlanError.invalidResponse}
        }
        if let request {
            guard state.submission?.request==request,let receipt=envelope.amendment else {throw ConversationTaskPlanError.invalidResponse}
            state.submission?.state = receipt.state == .applied ? .applied : (receipt.state == .pending ? .pending : .unknown)
            state.submission?.message=nil
            if receipt.state == .applied,let draft=state.draft,draft.baseRevision==request.expectedRevision,draft.goal==request.content.goal,draft.requirements==request.content.requirements {state.activeDraftRevision=nil}
        }
        state.snapshot=envelope.plan
        try await save(state,record:record,reference:reference,epoch:epoch);return state
    }
    private func load(_ reference:ConversationTaskPlanReference) async throws -> (ConversationTaskPlanLocalState,StoredRecord?) {
        guard !invalidated,reference.scope==scope else {throw CatpawError.scopeMismatch}
        let conversation=try await repository.record(reference.binding.conversation_id,scope:reference.scope)
        // The fixed local account partition differs from the authenticated server workspace.
        // The HTTP adapter verifies binding.scope_id against its configured serverScopeID.
        guard conversation.conversation != nil,reference.binding.grant_epoch>0,!reference.binding.task_id.isEmpty,reference.binding.task_id.utf16.count<=200 else {throw ConversationTaskPlanError.invalidResponse}
        let record:StoredRecord
        do {record=try await repository.record(recordID(reference),scope:reference.scope)} catch CatpawError.missing {return (ConversationTaskPlanLocalState(),nil)}
        guard case .preference(let value)=record.payload,value.key==recordKey(reference) else {throw ConversationTaskPlanError.invalidResponse}
        return (try JSONDecoder().decode(ConversationTaskPlanLocalState.self,from:Data(value.value.utf8)),record)
    }
    private func save(_ state:ConversationTaskPlanLocalState,record:StoredRecord?,reference:ConversationTaskPlanReference,epoch:Int?=nil) async throws {
        guard !invalidated else {throw CancellationError()};if let epoch {try requireAdmission(epoch)}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let payload=Payload.preference(Preference(key:recordKey(reference),value:String(decoding:try encoder.encode(state),as:UTF8.self)))
        let mutation:Mutation=record.map{.update($0.id,$0.header.revision,payload)} ?? .create(recordID(reference),payload)
        let conversation=try await repository.record(reference.binding.conversation_id,scope:scope)
        guard conversation.conversation != nil,!invalidated else {throw CancellationError()};if let epoch {try requireAdmission(epoch)}
        try await repository.commit(scope:reference.scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation])
    }
    private func requireAdmission(_ epoch:Int) throws {guard admitted,!invalidated,!closing,generation==epoch else {throw CancellationError()}}
    private func recordID(_ reference:ConversationTaskPlanReference)->UUID {stableID(recordKey(reference))}
    private static func isConflict(_ error:Error)->Bool {if case CatpawError.conflict=error {return true};return false}
    private func recordKey(_ reference:ConversationTaskPlanReference)->String {"conversation_task_plan:\(reference.binding.conversation_id):\(reference.binding.run_id)"}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock() {if waiters.isEmpty {locked=false}else{waiters.removeFirst().resume()}}
}
