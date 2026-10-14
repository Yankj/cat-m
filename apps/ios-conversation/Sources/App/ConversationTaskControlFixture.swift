#if DEBUG
import Foundation

/// Separate persisted fake server for native UI delivery tests. No Auth/provider/effect executor exists here.
actor ConversationTaskControlFixtureBackend:ConversationTaskControlBackend {
    enum Mode {case normal,unknown,unresolved}
    private struct Run:Codable {var control:ConversationTaskControlSnapshot;var operations:[String:ConversationTaskControlReceipt]=[:]}
    private struct Store:Codable {var schemaVersion=1;var runs:[String:Run]=[:];var posts=0,originalReads=0,stateReads=0}
    private let url:URL,mode:Mode
    private let statsUpdated:(@Sendable([String:Int])->Void)?
    private var store:Store
    init(url:URL,mode:Mode = .normal,statsUpdated:(@Sendable([String:Int])->Void)?=nil) throws {
        self.url=url;self.mode=mode;self.statsUpdated=statsUpdated
        if FileManager.default.fileExists(atPath:url.path){let value=try JSONDecoder().decode(Store.self,from:Data(contentsOf:url));guard value.schemaVersion==1 else {throw ConversationTaskControlError.invalidResponse};store=value}else{store=Store()}
    }
    func publishStats(){statsUpdated?(debugStats())}
    func debugStats()->[String:Int] {["control_posts":store.posts,"control_original_reads":store.originalReads,"control_state_reads":store.stateReads,"control_committed_operations":store.runs.values.reduce(0){$0+$1.operations.count}]}
    func controlAvailability(_ reference:ConversationTaskControlReference) async throws -> Bool {true}
    func readControl(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlEnvelope {let value=try ensure(reference);store.stateReads += 1;try persist();return .init(control:value.control)}
    func readControlOperation(_ reference:ConversationTaskControlReference,operationID:UUID) async throws -> ConversationTaskControlEnvelope {
        let value=try ensure(reference);store.originalReads += 1;try persist();guard let receipt=value.operations[operationID.uuidString.lowercased()] else {throw ConversationTaskControlError.originalNotFound};return .init(control:value.control,operation:receipt)
    }
    func submitControl(_ reference:ConversationTaskControlReference,request:ConversationTaskControlRequest) async throws -> ConversationTaskControlEnvelope {
        try request.validate(reference:reference)
        let identity=key(reference),operation=request.operationID.uuidString.lowercased();var value=try ensure(reference)
        store.posts += 1
        if let receipt=value.operations[operation] {
            guard receipt.action==request.action,receipt.base_execution_revision==request.expected_execution_revision,receipt.base_snapshot_hash==request.expected_snapshot_hash else {try persist();throw CatpawError.conflict};try persist();return .init(control:value.control,operation:receipt)
        }
        let base=value.control
        guard base.snapshot_hash==request.expected_snapshot_hash,base.execution_revision==request.expected_execution_revision,base.grant_epoch==request.expected_grant_epoch,base.plan_reference.revision==request.expected_plan_revision,base.plan_reference.plan_hash==request.expected_plan_hash,base.allows(request.action) else {try persist();throw CatpawError.conflict}
        value.control.execution_revision += 1;value.control.task_status=request.action == .pause ? "paused":request.action == .resume ? "scheduled":"cancelled"
        value.control.can_pause=request.action == .resume;value.control.can_resume=request.action == .pause && value.control.unresolved_operations.isEmpty;value.control.can_revoke=request.action != .revoke
        value.control.blocked_reason=request.action == .revoke ? "grant_changed":!value.control.unresolved_operations.isEmpty ? "original_outcome_unknown":request.action == .pause ? "user_paused":nil
        if request.action == .revoke {value.control.authority_reference.state="revoked";value.control.authority_reference.grant_epoch += 1;value.control.authority_reference.delegation_revision += 1}
        value.control.snapshot_hash=try value.control.digest()
        var receipt=ConversationTaskControlReceipt(operation_id:operation,operation_hash:textHash("Explicit offline control operation "+operation),scope_id:base.scope_id,subject_id:base.subject_id,conversation_id:base.conversation_id,run_id:base.run_id,task_id:base.task_id,run_request_hash:base.run_request_hash,action:request.action,base_execution_revision:base.execution_revision,accepted_execution_revision:value.control.execution_revision,base_snapshot_hash:base.snapshot_hash,grant_epoch:base.grant_epoch,plan_reference:base.plan_reference,result_task_status:value.control.task_status,applied_at:Self.utc(Date()),state:"applied",receipt_hash:"")
        receipt.receipt_hash=try receipt.digest();let envelope=ConversationTaskControlEnvelope(control:value.control,operation:receipt);try envelope.validateApplied(reference:reference,request:request,base:base)
        value.operations[operation]=receipt;store.runs[identity]=value
        // Fake server commit is separately durable before intentionally losing the response.
        try persist()
        if mode == .unknown {throw CatpawError.unavailable("Named offline control fixture lost its POST response after the fake server commit")}
        return envelope
    }
    func goal(_ reference:ConversationTaskControlReference) throws -> ConversationGoalProjection {
        let value=try ensure(reference).control,state:ConversationGoalProjection.State
        switch value.task_status {case "paused":state = .paused;case "cancelled":state = .cancelled;case "running":state = .working;default:state = .queued}
        var goal=ConversationGoalProjection(id:reference.binding.task_id,revision:value.plan_reference.revision,title:reference.title,state:state,summary:"Explicit offline persisted control fixture; no server execution, model, source read or system effect.",updatedAt:Date());goal.binding=reference.binding;goal.sourceAuthorizationCurrent=value.originalGrantCurrent && value.source_authorization_current;goal.planReference = .init(revision:value.plan_reference.revision,planHash:value.plan_reference.plan_hash);return goal
    }
    private func ensure(_ reference:ConversationTaskControlReference) throws -> Run {
        let identity=key(reference)
        if let value=store.runs[identity] {try value.control.validate(reference:reference);return value}
        let b=reference.binding,unknown:[ConversationTaskControlUnresolvedOperation]=mode == .unresolved ? [.init(kind:"model",operation_id:textHash("Explicit offline unresolved original model request"),state:"dispatched")]:[]
        var control=ConversationTaskControlSnapshot(scope_id:b.scope_id.uuidString.lowercased(),subject_id:reference.subjectID,conversation_id:b.conversation_id.uuidString.lowercased(),run_id:b.run_id.uuidString.lowercased(),task_id:b.task_id,run_request_hash:b.request_hash,delegation_id:b.delegation_id.uuidString.lowercased(),delegation_revision:b.delegation_revision,grant_epoch:b.grant_epoch,authority_reference:.init(delegation_revision:b.delegation_revision,grant_epoch:b.grant_epoch,state:"active"),execution_revision:0,task_status:mode == .unresolved ? "running":"queued",plan_reference:.init(revision:1,plan_hash:textHash("Explicit offline task control plan")),source_authorization_current:true,blocked_reason:unknown.isEmpty ? nil:"original_outcome_unknown",unresolved_operations:unknown,can_pause:true,can_resume:false,can_revoke:true,snapshot_hash:"")
        control.snapshot_hash=try control.digest();try control.validate(reference:reference);let value=Run(control:control);store.runs[identity]=value;try persist();return value
    }
    private func key(_ reference:ConversationTaskControlReference)->String {textHash("\(reference.scope.profileID):\(reference.scope.workspaceID):\(reference.subjectID):\(reference.binding.scope_id):\(reference.binding.run_id)")}
    private func persist() throws {try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try ConversationTaskActionJSON.encoded(store).write(to:url,options:.atomic);publishStats()}
    private static func utc(_ date:Date)->String {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:date)}
}

/// The native host/session path is real; every response and authority fact here is explicitly synthetic.
actor ConversationTaskControlConversationFixture:ConversationBackend {
    let controls:ConversationTaskControlFixtureBackend,subjectID:UUID
    init(controls:ConversationTaskControlFixtureBackend,subjectID:UUID){self.controls=controls;self.subjectID=subjectID}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"Named offline task control",detail:"No Auth/model/network/SQL")}
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        await MainActor.run {P0ExperienceFixture.replyCalls += 1}
        let values=try await events(request)
        return AsyncThrowingStream {stream in for value in values {stream.yield(value)};stream.finish()}
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {
        await MainActor.run {P0ExperienceFixture.observeCalls += 1}
        let reference=reference(request),goal=try await controls.goal(reference),values=try await events(request)
        return .init(request:request,events:values,requestHash:requestHash(request),grantEpoch:1,goals:[goal])
    }
    private func events(_ request:ConversationTurnRequest) async throws -> [ConversationTurnEvent] {
        let reference=reference(request),goal=try await controls.goal(reference),body="Explicit offline task control fixture. No Auth, model, source read, SQL or device effect.",message=stableID("control-fixture-assistant-"+request.operationID.uuidString),call=reference.binding.call_id
        let payloads:[ConversationTurnEvent.Payload]=[.started(requestHash:requestHash(request),conversationRevision:1,grantEpoch:1),.toolStarted(callID:call,name:"delegate_task",arguments:"{}"),.toolResult(.init(callID:call,name:"delegate_task",content:String(decoding:try JSONEncoder().encode(reference.binding),as:UTF8.self),committedGoals:[goal])),.textDelta(messageID:message,text:body),.completed(messageID:message,finalTextHash:textHash(body))]
        return payloads.enumerated().map{.init(operationID:request.operationID,epoch:request.epoch,sequence:$0.offset+1,payload:$0.element)}
    }
    private func reference(_ r:ConversationTurnRequest)->ConversationTaskControlReference {
        let call="named-control-fixture-"+r.operationID.uuidString,run=stableID(call+"-run")
        let binding=ConversationTaskBinding(scope_id:r.scope.workspaceID,conversation_id:r.conversationID,turn_id:r.operationID,call_id:call,delegation_id:stableID(call+"-delegation"),operation_id:stableID(call+"-operation"),run_id:run,task_id:textHash(call+"-task"),request_hash:textHash(call),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+r.scope.workspaceID.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        return .init(scope:r.scope,binding:binding,subjectID:subjectID.uuidString.lowercased(),title:"Synthetic persistent work with an intentionally long title that preserves its plan version")
    }
    private func requestHash(_ r:ConversationTurnRequest)->String {textHash("Explicit offline task control conversation:"+r.operationID.uuidString)}
}
#endif
