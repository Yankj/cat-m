import Foundation

public struct ConversationTaskControlSubmission:Codable,Sendable,Equatable,Identifiable {
    public enum State:String,Codable,Sendable {case unknown,applied,rejected,notSent}
    public enum Issue:String,Codable,Sendable {case unknown,originalNotFound,rejected,notSent}
    public let request:ConversationTaskControlRequest,requestHash:String,base:ConversationTaskControlSnapshot
    public var state:State,issue:Issue?,receipt:ConversationTaskControlReceipt?
    public var id:String {request.operationID.uuidString.lowercased()}
}
public struct ConversationTaskControlLocalState:Codable,Sendable,Equatable {
    public var schemaVersion=1
    public var latest:ConversationTaskControlSnapshot?
    public var submissions:[String:ConversationTaskControlSubmission]=[:]
    /// Availability and freshness are live process facts, never restored from disk as authority.
    public var controlAvailable=false
    private enum CodingKeys:String,CodingKey {case schemaVersion,latest,submissions}
    public init(){}
    public var hasUnresolvedSubmission:Bool {submissions.values.contains{$0.state == .unknown}}
    public var orderedSubmissions:[ConversationTaskControlSubmission] {submissions.values.sorted{a,b in a.base.execution_revision==b.base.execution_revision ? a.id<b.id : a.base.execution_revision>b.base.execution_revision}}
}
/// A scoped delivery journal. Only the existing server can pause or execute the original Task.
public actor ConversationTaskControlService {
    public nonisolated let scope:DataScope
    private let repository:Repository
    private let backend:any ConversationTaskControlBackend
    private var admitted=true,invalidated=false,locked=false
    private var generation=0
    private var active:Set<UUID>=[]
    private var fresh:[UUID:String]=[:]
    private var availability:[UUID:Bool]=[:]
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    public init(repository:Repository,scope:DataScope = Profiles.user,backend:any ConversationTaskControlBackend = UnconfiguredConversationTaskControlBackend()){self.repository=repository;self.scope=scope;self.backend=backend}
    public func setAdmissionAllowed(_ allowed:Bool){if !allowed {generation += 1;fresh.removeAll();availability.removeAll()};admitted=allowed && !invalidated}
    public func invalidate() async {
        generation += 1;admitted=false;invalidated=true;fresh.removeAll();availability.removeAll()
        // Join admitted local writes before account teardown returns; HTTP never owns this barrier.
        await lock();unlock()
    }
    public func localState(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlLocalState {var state=try await load(reference).0;state.controlAvailable=false;return state}
    public func isFresh(_ reference:ConversationTaskControlReference)->Bool {admitted && !invalidated && reference.scope==scope && fresh[reference.id] != nil}
    public func refresh(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlLocalState {
        guard admitted,!active.contains(reference.id) else {throw ConversationTaskControlError.busy}
        active.insert(reference.id);defer{active.remove(reference.id)}
        let epoch=generation
        let initial=try await load(reference).0;try ensure(epoch)
        fresh[reference.id]=nil;availability[reference.id]=nil
        let canControl=try await backend.controlAvailability(reference);try ensure(epoch)
        // Recover every unknown original UUID before admitting another control. A GET 404 proves no success or failure.
        var resolved:[String:ConversationTaskControlEnvelope]=[:],notFound:Set<String>=[]
        for submission in initial.orderedSubmissions where submission.state == .unknown {
            do {
                let envelope=try await backend.readControlOperation(reference,operationID:submission.request.operationID);try ensure(epoch)
                try envelope.validateApplied(reference:reference,request:submission.request,base:submission.base);resolved[submission.id]=envelope
            } catch ConversationTaskControlError.originalNotFound {try ensure(epoch);notFound.insert(submission.id)}
        }
        let current=try await backend.readControl(reference);try ensure(epoch);try current.validate(reference:reference)
        guard current.operation==nil else {throw ConversationTaskControlError.invalidResponse}
        await lock();defer{unlock()};try ensure(epoch)
        var (state,record)=try await load(reference);try ensure(epoch)
        for submission in initial.orderedSubmissions {
            if let envelope=resolved[submission.id] {
                guard state.submissions[submission.id]==submission else {throw ConversationTaskControlError.invalidResponse}
                try merge(envelope.control,into:&state)
                state.submissions[submission.id]?.state = .applied;state.submissions[submission.id]?.issue=nil;state.submissions[submission.id]?.receipt=envelope.operation
            } else if notFound.contains(submission.id),state.submissions[submission.id]==submission {state.submissions[submission.id]?.issue = .originalNotFound}
        }
        try merge(current.control,into:&state)
        try await save(state,record:record,reference:reference,epoch:epoch);try ensure(epoch)
        fresh[reference.id]=current.control.snapshot_hash;availability[reference.id]=canControl
        state.controlAvailable=canControl;return state
    }
    public func submit(_ reference:ConversationTaskControlReference,action:ConversationTaskControlAction,expectedSnapshotHash:String) async throws -> ConversationTaskControlEnvelope {
        guard admitted,!active.contains(reference.id) else {throw ConversationTaskControlError.busy}
        active.insert(reference.id);defer{active.remove(reference.id)}
        let epoch=generation
        let initial=try await load(reference).0;try ensure(epoch)
        guard !initial.hasUnresolvedSubmission else {throw ConversationTaskControlError.busy}
        guard availability[reference.id]==true else {throw ConversationTaskControlError.unavailable}
        guard let shown=initial.latest,shown.snapshot_hash==expectedSnapshotHash,fresh[reference.id]==expectedSnapshotHash,shown.allows(action) else {throw ConversationTaskControlError.stale}
        guard initial.submissions.count<64 else {throw ConversationTaskControlError.journalFull}
        // Re-read the exact object before journaling; the server still performs the authoritative CAS.
        let current=try await backend.readControl(reference);try ensure(epoch);try current.validate(reference:reference)
        guard current.operation==nil,current.control==shown,current.control.allows(action) else {fresh[reference.id]=nil;throw ConversationTaskControlError.stale}
        let request=ConversationTaskControlRequest(operationID:UUID(),action:action,base:shown);try request.validate(reference:reference)
        let submission=ConversationTaskControlSubmission(request:request,requestHash:try request.requestHash(reference:reference),base:shown,state:.unknown,issue:.unknown,receipt:nil)
        await lock()
        do {
            try ensure(epoch);var (state,record)=try await load(reference);try ensure(epoch)
            guard !state.hasUnresolvedSubmission,state.latest==shown,state.submissions.count<64 else {throw ConversationTaskControlError.busy}
            state.submissions[submission.id]=submission
            // Durable UUID + exact original snapshot precede the first POST, including a crash here.
            try await save(state,record:record,reference:reference,epoch:epoch);fresh[reference.id]=nil;unlock()
        } catch {unlock();throw error}
        var provenNotSent=false,serverRejected=false
        do {
            try ensure(epoch)
            let envelope:ConversationTaskControlEnvelope
            do {envelope=try await backend.submitControl(reference,request:request)}
            catch {
                provenNotSent=error is ConversationTaskControlDispatchFailure
                if case catError.conflict=error {serverRejected=true}
                throw error
            }
            try ensure(epoch)
            try envelope.validateApplied(reference:reference,request:request,base:shown)
            await lock();defer{unlock()};try ensure(epoch)
            var (state,record)=try await load(reference);try ensure(epoch)
            guard state.submissions[submission.id]==submission else {throw ConversationTaskControlError.invalidResponse}
            try merge(envelope.control,into:&state)
            state.submissions[submission.id]?.state = .applied;state.submissions[submission.id]?.issue=nil;state.submissions[submission.id]?.receipt=envelope.operation
            try await save(state,record:record,reference:reference,epoch:epoch);try ensure(epoch)
            return envelope
        } catch {
            guard generation==epoch,!invalidated,!Task.isCancelled else {throw error}
            await lock();defer{unlock()};try ensure(epoch)
            var (state,record)=try await load(reference);try ensure(epoch)
            if state.submissions[submission.id]?.request==request {
                if provenNotSent {state.submissions[submission.id]?.state = .notSent;state.submissions[submission.id]?.issue = .notSent}
                else if serverRejected {state.submissions[submission.id]?.state = .rejected;state.submissions[submission.id]?.issue = .rejected}
                // Transport loss, malformed receipts and cancellation remain unknown; never resend.
                try await save(state,record:record,reference:reference,epoch:epoch)
            }
            throw error
        }
    }
    public func appliedEnvelope(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlEnvelope? {
        let state=try await localState(reference)
        guard let control=state.latest,let submission=state.orderedSubmissions.first(where:{$0.state == .applied}),let receipt=submission.receipt else {return nil}
        let envelope=ConversationTaskControlEnvelope(control:control,operation:receipt)
        try envelope.validateApplied(reference:reference,request:submission.request,base:submission.base);return envelope
    }
    private func merge(_ value:ConversationTaskControlSnapshot,into state:inout ConversationTaskControlLocalState) throws {
        if let old=state.latest {
            guard value.execution_revision>=old.execution_revision,value.plan_reference.revision>=old.plan_reference.revision,value.authority_reference.grant_epoch>=old.authority_reference.grant_epoch,value.authority_reference.delegation_revision>=old.authority_reference.delegation_revision else {throw ConversationTaskControlError.invalidResponse}
            if value.plan_reference.revision==old.plan_reference.revision {guard value.plan_reference.plan_hash==old.plan_reference.plan_hash else {throw ConversationTaskControlError.invalidResponse}}
            if old.authority_reference.state=="revoked" {guard value.authority_reference.state=="revoked" else {throw ConversationTaskControlError.invalidResponse}}
            if old.terminal && value.task_status != old.task_status {
                guard old.task_status != "cancelled",old.originalGrantCurrent,value.originalGrantCurrent,value.source_authorization_current,value.plan_reference.revision>old.plan_reference.revision else {throw ConversationTaskControlError.invalidResponse}
            }
        }
        state.latest=value
    }
    private func load(_ reference:ConversationTaskControlReference) async throws -> (ConversationTaskControlLocalState,StoredRecord?) {
        guard !invalidated,reference.scope==scope else {throw catError.scopeMismatch}
        try reference.validate()
        let conversation=try await repository.record(reference.binding.conversation_id,scope:scope);guard conversation.conversation != nil else {throw ConversationTaskControlError.invalidResponse}
        let record:StoredRecord
        do {record=try await repository.record(stableID(key(reference)),scope:scope)} catch catError.missing {return (.init(),nil)}
        guard case .preference(let preference)=record.payload,preference.key==key(reference),preference.value.utf8.count<=1_048_576 else {throw ConversationTaskControlError.invalidResponse}
        let state=try JSONDecoder().decode(ConversationTaskControlLocalState.self,from:Data(preference.value.utf8))
        guard state.schemaVersion==1,state.submissions.count<=64,state.submissions.values.filter({$0.state == .unknown}).count<=1 else {throw ConversationTaskControlError.invalidResponse}
        if let latest=state.latest {try latest.validate(reference:reference)}
        for (id,submission) in state.submissions {
            try submission.base.validate(reference:reference);try submission.request.validate(reference:reference)
            guard id==submission.id,submission.requestHash==(try submission.request.requestHash(reference:reference)),submission.request.expected_execution_revision==submission.base.execution_revision,submission.request.expected_snapshot_hash==submission.base.snapshot_hash,submission.request.expected_plan_revision==submission.base.plan_reference.revision,submission.request.expected_plan_hash==submission.base.plan_reference.plan_hash,submission.base.allows(submission.request.action) else {throw ConversationTaskControlError.invalidResponse}
            if submission.state == .applied {
                guard let latest=state.latest,let receipt=submission.receipt else {throw ConversationTaskControlError.invalidResponse}
                try ConversationTaskControlEnvelope(control:latest,operation:receipt).validateApplied(reference:reference,request:submission.request,base:submission.base)
            } else {guard submission.receipt==nil else {throw ConversationTaskControlError.invalidResponse}}
        }
        return (state,record)
    }
    private func save(_ state:ConversationTaskControlLocalState,record:StoredRecord?,reference:ConversationTaskControlReference,epoch:Int) async throws {
        try ensure(epoch);let conversation=try await repository.record(reference.binding.conversation_id,scope:scope);try ensure(epoch)
        let data=try ConversationTaskActionJSON.encoded(state);guard data.count<=1_048_576 else {throw ConversationTaskControlError.invalidResponse}
        let payload=Payload.preference(.init(key:key(reference),value:String(decoding:data,as:UTF8.self)))
        let mutation:Mutation=record.map{.update($0.id,$0.header.revision,payload)} ?? .create(stableID(key(reference)),payload)
        try await repository.commit(scope:scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation])
    }
    private func key(_ reference:ConversationTaskControlReference)->String {
        let b=reference.binding
        return "conversation_task_controls:\(b.conversation_id):\(b.run_id):"+textHash("\(scope.profileID):\(scope.workspaceID):\(reference.subjectID):\(b.scope_id):\(b.conversation_id):\(b.turn_id):\(b.run_id):\(b.task_id):\(b.delegation_id):\(b.delegation_revision):\(b.grant_epoch):\(b.request_hash)")
    }
    private func ensure(_ epoch:Int) throws {guard admitted,!invalidated,generation==epoch,!Task.isCancelled else {throw CancellationError()}}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock(){if waiters.isEmpty {locked=false}else{waiters.removeFirst().resume()}}
}
