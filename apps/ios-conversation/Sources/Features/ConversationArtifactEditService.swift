import Foundation

public struct ConversationArtifactEditDraft:Codable,Sendable,Equatable {
    public let baseReference:ConversationArtifactVersionReference
    public let planReference:ConversationArtifactEditPlanReference
    public var content:ConversationArtifactEditContent
    public let editSequence:Int
    public init(baseReference:ConversationArtifactVersionReference,planReference:ConversationArtifactEditPlanReference,content:ConversationArtifactEditContent,editSequence:Int=0) {self.baseReference=baseReference;self.planReference=planReference;self.content=content;self.editSequence=editSequence}
}
public struct ConversationArtifactEditSubmission:Codable,Sendable,Equatable {
    public enum State:String,Codable,Sendable {case unknown,applied,rejected,notSent}
    public let request:ConversationArtifactEditAmendRequest
    public let base:ConversationArtifactEditSnapshot
    public let draftKey:String
    public let submittedDraft:ConversationArtifactEditDraft
    public var state:State
    public var message:String?
    public var receipt:ConversationArtifactEditEnvelope?
}
public struct ConversationArtifactEditLocalState:Codable,Sendable,Equatable {
    public var latest:ConversationArtifactEditSnapshot?
    public var versions:[String:ConversationArtifactEditSnapshot]=[:]
    /// Each original reader selection has its own draft; rebase changes only that draft's base.
    public var drafts:[String:ConversationArtifactEditDraft]=[:]
    public var submission:ConversationArtifactEditSubmission?
    public init() {}
    public var hasUnresolvedSubmission:Bool {submission?.state == .unknown}
    public func draft(for reference:ConversationArtifactEditReference)->ConversationArtifactEditDraft? {drafts[reference.selection.id]}
    public func base(for reference:ConversationArtifactEditReference)->ConversationArtifactEditSnapshot? {versions[draft(for:reference)?.baseReference.identity.id ?? reference.selection.id]}
    public var currentReference:ConversationArtifactVersionReference? {latest?.versionReference ?? submission?.receipt?.artifact.currentReference}
}
/// Persists only local editing and verified receipt delivery. Server CAS owns the immutable revision.
public actor ConversationArtifactEditService {
    public nonisolated let scope:DataScope
    nonisolated let localDraftDrains:ConversationLocalDraftDrains
    private let repository:Repository
    private let backend:any ConversationArtifactEditBackend
    private var admitted=true
    private var invalidated=false
    private var closing=false
    private var drainSucceeded=true
    private var teardownWaiters:[CheckedContinuation<Bool,Never>]=[]
    private var generation=0
    private var fresh:Set<String>=[]
    private var active:Set<String>=[]
    private var locked=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    public init(repository:Repository,scope:DataScope = Profiles.user,backend:any ConversationArtifactEditBackend = UnconfiguredConversationArtifactEditBackend()) {self.repository=repository;self.scope=scope;self.backend=backend;localDraftDrains=ConversationLocalDraftDrains(scope:scope)}
    /// Application lifecycle observers may join this fixed-scope local drain; no HTTP is admitted.
    public nonisolated func registerLocalDraftFlusher(_ flusher:@escaping @Sendable () async -> Void)->UUID {
        let id=UUID();_=localDraftDrains.register(id,scope:scope){await flusher();return true};return id
    }
    public nonisolated func unregisterLocalDraftFlusher(_ id:UUID){localDraftDrains.unregister(id)}
    public func setAdmissionAllowed(_ allowed:Bool) async {
        if !allowed {generation += 1;fresh.removeAll()};admitted=allowed && !invalidated && !closing
        if !allowed {await lock();unlock()}
    }
    @discardableResult public func invalidate() async -> Bool {
        if invalidated {return drainSucceeded}
        if closing {return await withCheckedContinuation{teardownWaiters.append($0)}}
        generation += 1;admitted=false;closing=true;fresh.removeAll()
        let drains=localDraftDrains.closeAndSnapshot()
        for drain in drains {if !(await drain()) {drainSucceeded=false}}
        // This barrier also completes already admitted direct local writes. HTTP owns no lock here.
        await lock();invalidated=true;localDraftDrains.finish();unlock()
        let result=drainSucceeded;teardownWaiters.forEach{$0.resume(returning:result)};teardownWaiters=[];return result
    }
    public func isFresh(_ reference:ConversationArtifactEditReference)->Bool {admitted && !invalidated && !closing && reference.scope==scope && fresh.contains(key(reference))}
    public func localState(_ reference:ConversationArtifactEditReference) async throws -> ConversationArtifactEditLocalState {try await load(reference).0}
    public func refresh(_ reference:ConversationArtifactEditReference) async throws -> ConversationArtifactEditLocalState {
        guard admitted,!invalidated,!closing else {throw ConversationArtifactEditError.notConfigured}
        let epoch=generation
        let state=try await load(reference).0
        try requireAdmission(epoch)
        if let submission=state.submission,state.hasUnresolvedSubmission {
            let envelope=try await backend.readAmendment(reference,operationID:submission.request.operationID)
            _ = try await acceptApplied(envelope,reference:reference,submission:submission,epoch:epoch)
            return try await localState(reference)
        }
        if state.versions[reference.selection.id]==nil {
            let selected=try await backend.readArtifact(reference,version:reference.artifact.version)
            guard selected.artifact.identity==reference.selection,selected.artifact.body==reference.artifact.body else {throw ConversationArtifactEditError.invalidResponse}
            try await acceptRead(selected,reference:reference,epoch:epoch,head:false)
        }
        try requireAdmission(epoch)
        let head=try await backend.readArtifact(reference,version:nil)
        try await acceptRead(head,reference:reference,epoch:epoch,head:true)
        try requireAdmission(epoch);fresh.insert(key(reference))
        return try await localState(reference)
    }
    public func saveDraft(_ reference:ConversationArtifactEditReference,draft:ConversationArtifactEditDraft) async throws {
        guard !closing,!invalidated else {throw CancellationError()}
        try await saveAcceptedDraft(reference,draft:draft)
    }
    func saveDraft(_ reference:ConversationArtifactEditReference,draft:ConversationArtifactEditDraft,ticket:ConversationLocalDraftTicket) async throws {
        guard !invalidated,reference.scope==scope,localDraftDrains.consume(ticket) else {throw CancellationError()}
        try await saveAcceptedDraft(reference,draft:draft)
    }
    private func saveAcceptedDraft(_ reference:ConversationArtifactEditReference,draft:ConversationArtifactEditDraft) async throws {
        await lock();defer{unlock()}
        var (state,record)=try await load(reference)
        try draft.content.validateLocal();try draft.baseReference.validate();try draft.planReference.validate()
        guard draft.editSequence>=0,draft.baseReference.artifactID==reference.artifact.id,
              let base=state.versions[draft.baseReference.identity.id],base.planReference==draft.planReference else {throw ConversationArtifactEditError.invalidResponse}
        state.drafts[reference.selection.id]=draft
        try await save(state,record:record,reference:reference)
    }
    public func discardDraft(_ reference:ConversationArtifactEditReference) async throws {
        await lock();defer{unlock()}
        var (state,record)=try await load(reference)
        state.drafts.removeValue(forKey:reference.selection.id)
        try await save(state,record:record,reference:reference)
    }
    public func rebaseDraft(_ reference:ConversationArtifactEditReference) async throws -> ConversationArtifactEditLocalState {
        await lock();defer{unlock()}
        var (state,record)=try await load(reference)
        guard !state.hasUnresolvedSubmission,isFresh(reference),let head=state.latest,head.editable,let draft=state.draft(for:reference) else {throw ConversationArtifactEditError.notFresh}
        let next=ConversationArtifactEditDraft(baseReference:head.versionReference,planReference:head.planReference,content:draft.content,editSequence:draft.editSequence+1)
        state.drafts[reference.selection.id]=next
        try await save(state,record:record,reference:reference);return state
    }
    public func submit(_ reference:ConversationArtifactEditReference) async throws -> ConversationArtifactEditEnvelope {
        let work=key(reference)
        guard admitted,!invalidated,!closing,!active.contains(work) else {throw ConversationArtifactEditError.busy}
        active.insert(work);defer{active.remove(work)}
        let epoch=generation
        await lock()
        let submission:ConversationArtifactEditSubmission
        do {
            var (state,record)=try await load(reference)
            try requireAdmission(epoch)
            guard !state.hasUnresolvedSubmission else {throw ConversationArtifactEditError.busy}
            guard fresh.contains(work) else {throw ConversationArtifactEditError.notFresh}
            guard let head=state.latest,head.editable else {throw ConversationArtifactEditError.notEditable}
            guard let draft=state.draft(for:reference),let base=state.versions[draft.baseReference.identity.id] else {throw ConversationArtifactEditError.invalidResponse}
            guard draft.baseReference==head.versionReference,draft.planReference==head.planReference,base.sourceAuthHash==head.sourceAuthHash else {throw ConversationArtifactEditError.staleDraft}
            try draft.content.validate()
            let request=ConversationArtifactEditAmendRequest(operationID:UUID(),expectedVersion:draft.baseReference.version,expectedContentHash:draft.baseReference.contentHash,expectedGrantEpoch:head.grantEpoch,expectedPlanRevision:head.planReference.revision,expectedPlanHash:head.planReference.planHash,content:draft.content)
            submission=ConversationArtifactEditSubmission(request:request,base:base,draftKey:reference.selection.id,submittedDraft:draft,state:.unknown,message:nil,receipt:nil)
            state.submission=submission
            // Durable original ID precedes the first POST; interrupted admission must use GET.
            try await save(state,record:record,reference:reference,epoch:epoch)
            fresh.remove(work);unlock()
        } catch {unlock();throw error}
        do {
            try requireAdmission(epoch)
            let envelope=try await backend.amendArtifact(reference,request:submission.request)
            return try await acceptApplied(envelope,reference:reference,submission:submission,epoch:epoch)
        } catch {
            fresh.remove(work)
            guard !invalidated,generation==epoch else {throw error}
            await lock();defer{unlock()}
            var (state,record)=try await load(reference)
            if state.submission?.request.operationID==submission.request.operationID {
                state.submission?.state = error is ConversationDispatchFailure ? .notSent : (Self.isConflict(error) ? .rejected : .unknown)
                state.submission?.message=error.localizedDescription
                try await save(state,record:record,reference:reference,epoch:epoch)
            }
            throw error
        }
    }
    /// Replay delivery of an already validated receipt never repeats the write.
    public func appliedEnvelope(_ reference:ConversationArtifactEditReference) async throws -> ConversationArtifactEditEnvelope? {
        let state=try await localState(reference)
        guard let submission=state.submission,submission.state == .applied,let envelope=submission.receipt else {return nil}
        try envelope.validateApplied(reference:reference,request:submission.request,base:submission.base)
        return envelope
    }
    private func acceptRead(_ envelope:ConversationArtifactEditEnvelope,reference:ConversationArtifactEditReference,epoch:Int,head:Bool) async throws {
        try requireAdmission(epoch);try envelope.validate(reference:reference)
        guard envelope.amendment==nil,!head || envelope.artifact.isCurrent else {throw ConversationArtifactEditError.invalidResponse}
        await lock();defer{unlock()}
        try requireAdmission(epoch)
        var (state,record)=try await load(reference)
        try cache(envelope.artifact,state:&state)
        if head {
            if let old=state.latest {guard envelope.artifact.version>=old.version,envelope.artifact.version != old.version || envelope.artifact.contentHash==old.contentHash else {throw ConversationArtifactEditError.invalidResponse}}
            state.latest=envelope.artifact
        }
        try await save(state,record:record,reference:reference,epoch:epoch)
    }
    private func acceptApplied(_ envelope:ConversationArtifactEditEnvelope,reference:ConversationArtifactEditReference,submission:ConversationArtifactEditSubmission,epoch:Int) async throws -> ConversationArtifactEditEnvelope {
        try requireAdmission(epoch)
        try envelope.validateApplied(reference:reference,request:submission.request,base:submission.base)
        await lock();defer{unlock()}
        try requireAdmission(epoch)
        var (state,record)=try await load(reference)
        guard state.submission?.request==submission.request,state.submission?.base==submission.base else {throw ConversationArtifactEditError.invalidResponse}
        try cache(envelope.artifact,state:&state)
        if envelope.artifact.isCurrent {
            if let old=state.latest,old.version>envelope.artifact.version {throw ConversationArtifactEditError.invalidResponse}
            state.latest=envelope.artifact
        }
        state.submission?.state = .applied;state.submission?.message=nil;state.submission?.receipt=envelope
        if state.drafts[submission.draftKey]==submission.submittedDraft {state.drafts.removeValue(forKey:submission.draftKey)}
        try await save(state,record:record,reference:reference,epoch:epoch)
        return envelope
    }
    private func cache(_ snapshot:ConversationArtifactEditSnapshot,state:inout ConversationArtifactEditLocalState) throws {
        if let old=state.versions[snapshot.identity.id] {guard old.body==snapshot.body,old.planReference==snapshot.planReference,old.sourceAuthHash==snapshot.sourceAuthHash,old.createdAt==snapshot.createdAt else {throw ConversationArtifactEditError.invalidResponse}}
        if let old=state.versions.values.first {guard old.sourceAuthHash==snapshot.sourceAuthHash else {throw ConversationArtifactEditError.invalidResponse}}
        for old in state.versions.values where old.version==snapshot.version {guard old.contentHash==snapshot.contentHash else {throw ConversationArtifactEditError.invalidResponse}}
        state.versions[snapshot.identity.id]=snapshot
    }
    private func load(_ reference:ConversationArtifactEditReference) async throws -> (ConversationArtifactEditLocalState,StoredRecord?) {
        guard !invalidated,reference.scope==scope else {throw CatpawError.scopeMismatch}
        let conversation=try await repository.record(reference.binding.conversation_id,scope:scope)
        guard conversation.conversation != nil,reference.artifact.version>0,ConversationArtifactEditCodec.isHash(reference.artifact.id),ConversationArtifactEditCodec.isHash(reference.artifact.contentHash),textHash(reference.artifact.body)==reference.artifact.contentHash else {throw ConversationArtifactEditError.invalidResponse}
        let document=try ConversationArtifactEditCodec.document(reference.artifact.body)
        guard document.title==reference.artifact.title,document.summary==reference.artifact.summary,document.content==reference.artifact.content else {throw ConversationArtifactEditError.invalidResponse}
        let record:StoredRecord
        do {record=try await repository.record(recordID(reference),scope:scope)} catch CatpawError.missing {return (ConversationArtifactEditLocalState(),nil)}
        guard case .preference(let value)=record.payload,value.key==key(reference) else {throw ConversationArtifactEditError.invalidResponse}
        let state=try JSONDecoder().decode(ConversationArtifactEditLocalState.self,from:Data(value.value.utf8))
        for snapshot in state.versions.values {try snapshot.validate(reference:reference)}
        return (state,record)
    }
    private func save(_ state:ConversationArtifactEditLocalState,record:StoredRecord?,reference:ConversationArtifactEditReference,epoch:Int?=nil) async throws {
        guard !invalidated else {throw CancellationError()};if let epoch {try requireAdmission(epoch)}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let payload=Payload.preference(Preference(key:key(reference),value:String(decoding:try encoder.encode(state),as:UTF8.self)))
        let mutation:Mutation=record.map{.update($0.id,$0.header.revision,payload)} ?? .create(recordID(reference),payload)
        let conversation=try await repository.record(reference.binding.conversation_id,scope:scope)
        guard conversation.conversation != nil,!invalidated else {throw CancellationError()};if let epoch {try requireAdmission(epoch)}
        try await repository.commit(scope:scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation])
    }
    private func requireAdmission(_ epoch:Int) throws {guard admitted,!invalidated,!closing,generation==epoch else {throw CancellationError()}}
    private func key(_ reference:ConversationArtifactEditReference)->String {"conversation_artifact_edit:\(reference.binding.conversation_id):\(reference.binding.run_id):\(reference.artifact.id)"}
    private func recordID(_ reference:ConversationArtifactEditReference)->UUID {stableID(key(reference))}
    private static func isConflict(_ error:Error)->Bool {if case CatpawError.conflict=error {return true};return false}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock() {if waiters.isEmpty {locked=false}else{waiters.removeFirst().resume()}}
}
