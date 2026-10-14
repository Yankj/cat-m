import Foundation

public struct ConversationTaskActionSubmission:Codable,Sendable,Equatable {
    public enum State:String,Codable,Sendable {case unknown,accepted,rejected,notSent}
    public enum Issue:String,Codable,Sendable {case unknown,originalNotFound,rejected,notSent}
    public let actionID:String
    public let request:ConversationTaskActionDecisionRequest
    public let requestHash:String
    public var state:State
    public var issue:Issue?
}
public struct ConversationTaskActionLocalState:Codable,Sendable {
    public var schemaVersion=1
    public var actions:[ConversationTaskActionSnapshot]=[]
    public var submissions:[String:ConversationTaskActionSubmission]=[:]
    /// Current availability is deliberately never restored as authority from disk.
    public var decisionAvailable=false
    private enum CodingKeys:String,CodingKey {case schemaVersion,actions,submissions}
    public init(){}
    public var hasUnresolvedDecision:Bool {submissions.values.contains{$0.state == .unknown}}
}
/// Local journal only. Server transactions own approval facts; this service has no effect executor.
public actor ConversationTaskActionService {
    public nonisolated let scope:DataScope
    private let repository:Repository
    private let backend:any ConversationTaskActionBackend
    private var admitted=true,invalidated=false,locked=false
    private var generation=0
    private var active:Set<UUID>=[]
    private var fresh:[UUID:Set<String>]=[:]
    private var availability:[UUID:Bool]=[:]
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    private let clock:@Sendable()->Date
    public init(repository:Repository,scope:DataScope = Profiles.user,backend:any ConversationTaskActionBackend = UnconfiguredConversationTaskActionBackend(),clock:@escaping @Sendable()->Date = {Date()}) {self.repository=repository;self.scope=scope;self.backend=backend;self.clock=clock}
    public func setAdmissionAllowed(_ allowed:Bool){if !allowed {generation += 1;fresh.removeAll();availability.removeAll()};admitted=allowed && !invalidated}
    public func invalidate(){generation += 1;admitted=false;invalidated=true;fresh.removeAll();availability.removeAll()}
    public func localState(_ reference:ConversationTaskActionReference) async throws -> ConversationTaskActionLocalState {var state=try await load(reference).0;state.decisionAvailable=false;return state}
    public func refresh(_ reference:ConversationTaskActionReference) async throws -> ConversationTaskActionLocalState {
        guard admitted,!active.contains(reference.id) else {throw ConversationTaskActionError.busy}
        active.insert(reference.id);defer{active.remove(reference.id)}
        let epoch=generation
        let initial=try await load(reference).0
        try ensure(epoch)
        let canDecide=try await backend.decisionAvailability(reference);try ensure(epoch)
        let catalog=try await backend.readActions(reference);try ensure(epoch);try catalog.validate(reference:reference)
        // An unknown decision always reads its immutable original UUID, including after a new plan or grant.
        var resolved:[String:ConversationTaskActionEnvelope]=[:],notFound:Set<String>=[]
        for submission in initial.submissions.values.sorted(by:{$0.actionID<$1.actionID}) where submission.state == .unknown {
            do {let envelope=try await backend.readDecision(reference,actionID:submission.actionID,operationID:submission.request.operationID);try ensure(epoch);try validate(envelope,reference:reference,submission:submission);resolved[submission.actionID]=envelope}
            catch ConversationTaskActionError.originalNotFound {try ensure(epoch);notFound.insert(submission.actionID)}
        }
        await lock();defer{unlock()};try ensure(epoch)
        var (state,record)=try await load(reference);try ensure(epoch)
        for snapshot in catalog.actions {try merge(snapshot,into:&state)}
        for (id,envelope) in resolved {
            guard state.submissions[id]==initial.submissions[id] else {throw ConversationTaskActionError.invalidResponse}
            try merge(envelope.action,into:&state);state.submissions[id]?.state = .accepted;state.submissions[id]?.issue=nil
        }
        for id in notFound {if state.submissions[id]?.request==initial.submissions[id]?.request {state.submissions[id]?.issue = .originalNotFound}}
        try await save(state,record:record,reference:reference,epoch:epoch);try ensure(epoch)
        fresh[reference.id]=Set(catalog.actions.map(Self.token));availability[reference.id]=canDecide
        state.decisionAvailable=canDecide;return state
    }
    public func decide(_ reference:ConversationTaskActionReference,actionID:String,expectedDigest:String,expectedRevision:Int,decision:ConversationTaskActionDecision) async throws -> ConversationTaskActionLocalState {
        guard admitted,!active.contains(reference.id) else {throw ConversationTaskActionError.busy}
        active.insert(reference.id);defer{active.remove(reference.id)}
        let epoch=generation
        let initial=try await load(reference).0;try ensure(epoch)
        guard availability[reference.id]==true else {throw ConversationTaskActionError.unavailable}
        guard let shown=initial.actions.first(where:{$0.id==actionID}),shown.action_digest==expectedDigest,shown.revision==expectedRevision,fresh[reference.id]?.contains(Self.token(shown))==true,shown.canDecide(at:clock()) else {throw ConversationTaskActionError.stale}
        guard initial.submissions[actionID]?.state != .unknown else {throw ConversationTaskActionError.busy}
        let current=try await backend.readAction(reference,actionID:actionID);try ensure(epoch)
        try validate(current,reference:reference)
        guard current.action.id==actionID,current.action.action_digest==expectedDigest,current.action.revision==expectedRevision,current.action.canDecide(at:clock()),current.decision==nil else {throw ConversationTaskActionError.stale}
        let request=ConversationTaskActionDecisionRequest(operationID:UUID(),decision:decision,expected_revision:expectedRevision,action_digest:expectedDigest,expected_grant_epoch:reference.binding.grant_epoch)
        let submission=ConversationTaskActionSubmission(actionID:actionID,request:request,requestHash:try request.requestHash(reference:reference,actionID:actionID),state:.unknown,issue:.unknown)
        await lock()
        do {
            try ensure(epoch);var (state,record)=try await load(reference);try ensure(epoch)
            guard state.submissions[actionID]?.state != .unknown,let saved=state.actions.first(where:{$0.id==actionID}),saved.action_digest==expectedDigest,saved.revision==expectedRevision else {throw ConversationTaskActionError.busy}
            state.submissions[actionID]=submission
            // Durable original operation/request precedes HTTP, including the crash-before-dispatch case.
            try await save(state,record:record,reference:reference,epoch:epoch);unlock()
        } catch {unlock();throw error}
        do {
            try ensure(epoch)
            guard current.action.canDecide(at:clock()) else {throw ConversationTaskActionDispatchFailure.notSent}
            let envelope=try await backend.decideAction(reference,actionID:actionID,request:request);try ensure(epoch)
            try validate(envelope,reference:reference,submission:submission)
            await lock();defer{unlock()};try ensure(epoch)
            var (state,record)=try await load(reference);try ensure(epoch)
            guard state.submissions[actionID]?.request==request else {throw ConversationTaskActionError.invalidResponse}
            try merge(envelope.action,into:&state);state.submissions[actionID]?.state = .accepted;state.submissions[actionID]?.issue=nil
            try await save(state,record:record,reference:reference,epoch:epoch);try ensure(epoch)
            state.decisionAvailable=availability[reference.id]==true;return state
        } catch {
            guard generation==epoch,!invalidated else {throw error}
            await lock();defer{unlock()}
            var (state,record)=try await load(reference);try ensure(epoch)
            if state.submissions[actionID]?.request==request {
                if error is ConversationTaskActionDispatchFailure {state.submissions[actionID]?.state = .notSent;state.submissions[actionID]?.issue = .notSent}
                else if case CatpawError.conflict=error {state.submissions[actionID]?.state = .rejected;state.submissions[actionID]?.issue = .rejected}
                // Malformed/lost receipts and 404s are unknown, never an inferred rejection.
                try await save(state,record:record,reference:reference,epoch:epoch)
            }
            fresh[reference.id]=nil;throw error
        }
    }
    private func validate(_ envelope:ConversationTaskActionEnvelope,reference:ConversationTaskActionReference,submission:ConversationTaskActionSubmission?=nil) throws {
        guard envelope.schema_version==1,envelope.contract=="catpaw.task-action.v1" else {throw ConversationTaskActionError.invalidResponse}
        try envelope.action.validate(reference:reference)
        if let submission {
            guard let receipt=envelope.decision,receipt.operation_id==submission.request.operationID.uuidString.lowercased(),receipt.action_id==submission.actionID,receipt.action_digest==submission.request.action_digest,receipt.decision==submission.request.decision,receipt.state=="accepted",let committed=ConversationTaskActionValidation.utc(receipt.committed_at),let created=ConversationTaskActionValidation.utc(envelope.action.frozen.created_at),let expires=ConversationTaskActionValidation.utc(envelope.action.frozen.expires_at),committed>=created,committed<expires,envelope.action.id==submission.actionID,envelope.action.action_digest==submission.request.action_digest,envelope.action.revision>=submission.request.expected_revision+1,envelope.action.decision_operation_id==receipt.operation_id,envelope.action.approval_status==(receipt.decision == .approve ? "approved":"denied") else {throw ConversationTaskActionError.invalidResponse}
        } else {guard envelope.decision==nil else {throw ConversationTaskActionError.invalidResponse}}
    }
    private func merge(_ action:ConversationTaskActionSnapshot,into state:inout ConversationTaskActionLocalState) throws {
        if let index=state.actions.firstIndex(where:{$0.id==action.id}) {
            let old=state.actions[index]
            guard action.action_digest==old.action_digest,action.frozen==old.frozen,action.revision>=old.revision else {throw ConversationTaskActionError.invalidResponse}
            if ["approved","denied"].contains(old.approval_status) {guard action.approval_status==old.approval_status,action.decision_operation_id==old.decision_operation_id else {throw ConversationTaskActionError.invalidResponse}}
            state.actions[index]=action
        }
        else {guard state.actions.count<32 else {throw ConversationTaskActionError.invalidResponse};state.actions.append(action)}
        state.actions.sort{$0.id<$1.id}
    }
    private func load(_ reference:ConversationTaskActionReference) async throws -> (ConversationTaskActionLocalState,StoredRecord?) {
        guard !invalidated,reference.scope==scope else {throw CatpawError.scopeMismatch}
        guard ConversationTaskActionValidation.uuid(reference.subjectID),reference.binding.grant_epoch>0 else {throw ConversationTaskActionError.invalidResponse}
        let conversation=try await repository.record(reference.binding.conversation_id,scope:scope);guard conversation.conversation != nil else {throw ConversationTaskActionError.invalidResponse}
        let record:StoredRecord
        do {record=try await repository.record(stableID(key(reference)),scope:scope)}catch CatpawError.missing{return (.init(),nil)}
        guard case .preference(let preference)=record.payload,preference.key==key(reference),preference.value.utf8.count<=1_048_576 else {throw ConversationTaskActionError.invalidResponse}
        let state=try JSONDecoder().decode(ConversationTaskActionLocalState.self,from:Data(preference.value.utf8))
        guard state.schemaVersion==1,state.actions.count<=32,Set(state.actions.map(\.id)).count==state.actions.count,state.submissions.count<=32 else {throw ConversationTaskActionError.invalidResponse}
        for action in state.actions {try action.validate(reference:reference)}
        for (id,submission) in state.submissions {
            guard id==submission.actionID,let action=state.actions.first(where:{$0.id==id}),ConversationTaskActionValidation.positive(submission.request.expected_revision),submission.request.expected_grant_epoch==reference.binding.grant_epoch,submission.request.action_digest==action.action_digest,submission.requestHash==(try submission.request.requestHash(reference:reference,actionID:id)) else {throw ConversationTaskActionError.invalidResponse}
            guard ![id,action.frozen.proposal_operation_id,action.frozen.run_id,action.frozen.delegation_id,action.frozen.conversation_id,action.frozen.turn_id].contains(submission.request.operationID.uuidString.lowercased()) else {throw ConversationTaskActionError.invalidResponse}
            if submission.state == .accepted {guard action.decision_operation_id==submission.request.operationID.uuidString.lowercased(),action.revision>=submission.request.expected_revision+1,action.approval_status==(submission.request.decision == .approve ? "approved":"denied") else {throw ConversationTaskActionError.invalidResponse}}
        }
        return (state,record)
    }
    private func save(_ state:ConversationTaskActionLocalState,record:StoredRecord?,reference:ConversationTaskActionReference,epoch:Int) async throws {
        try ensure(epoch);let conversation=try await repository.record(reference.binding.conversation_id,scope:scope);try ensure(epoch)
        let data=try ConversationTaskActionJSON.encoded(state);guard data.count<=1_048_576 else {throw ConversationTaskActionError.invalidResponse}
        let payload=Payload.preference(.init(key:key(reference),value:String(decoding:data,as:UTF8.self)))
        let mutation:Mutation=record.map{.update($0.id,$0.header.revision,payload)} ?? .create(stableID(key(reference)),payload)
        try await repository.commit(scope:scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation])
    }
    private func key(_ reference:ConversationTaskActionReference)->String {"conversation_task_actions:\(reference.binding.conversation_id):\(reference.binding.run_id):"+textHash("\(scope.profileID):\(scope.workspaceID):\(reference.subjectID):\(reference.binding.scope_id):\(reference.binding.conversation_id):\(reference.binding.turn_id):\(reference.binding.run_id):\(reference.binding.task_id):\(reference.binding.delegation_id):\(reference.binding.delegation_revision):\(reference.binding.grant_epoch):\(reference.binding.request_hash)")}
    private static func token(_ action:ConversationTaskActionSnapshot)->String {"\(action.id):\(action.revision):\(action.action_digest)"}
    private func ensure(_ epoch:Int) throws {guard admitted,!invalidated,generation==epoch,!Task.isCancelled else {throw CancellationError()}}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock(){if waiters.isEmpty {locked=false}else{waiters.removeFirst().resume()}}
}
