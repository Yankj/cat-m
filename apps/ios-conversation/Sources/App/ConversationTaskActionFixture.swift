#if DEBUG
import Foundation

/// Explicit offline server fixture, persisted separately from the application journal.
/// No model, network, calendar access, schedule or real effect exists in this fixture.
actor ConversationTaskActionFixtureBackend:ConversationTaskActionBackend {
    enum Mode {case normal,unknown,unavailable}
    private struct Run:Codable {var action:ConversationTaskActionSnapshot;var decisions:[String:ConversationTaskActionEnvelope]=[:]}
    private struct Store:Codable {var schemaVersion=1;var runs:[String:Run]=[:];var decisionPosts=0;var decisionReads=0;var catalogReads=0}
    private let url:URL
    private let mode:Mode
    private let statsUpdated:(@Sendable([String:Int])->Void)?
    private var store:Store
    init(url:URL,mode:Mode = .normal,statsUpdated:(@Sendable([String:Int])->Void)?=nil) throws {
        self.url=url;self.mode=mode;self.statsUpdated=statsUpdated
        if FileManager.default.fileExists(atPath:url.path){let decoded=try JSONDecoder().decode(Store.self,from:Data(contentsOf:url));guard decoded.schemaVersion==1 else {throw ConversationTaskActionError.invalidResponse};store=decoded}else{store=Store()}
    }
    func debugStats()->[String:Int] {["action_posts":store.decisionPosts,"action_reads":store.decisionReads,"action_catalog_reads":store.catalogReads,"action_committed_decisions":store.runs.values.reduce(0){$0+$1.decisions.count}]}
    func decisionAvailability(_ reference:ConversationTaskActionReference) async throws -> Bool {mode != .unavailable}
    func readActions(_ reference:ConversationTaskActionReference) async throws -> ConversationTaskActionCatalog {let run=try ensure(reference);store.catalogReads += 1;try persist();return .init(reference:reference,actions:[current(run.action)])}
    func readAction(_ reference:ConversationTaskActionReference,actionID:String) async throws -> ConversationTaskActionEnvelope {let run=try ensure(reference);guard run.action.id==actionID else {throw ConversationTaskActionError.invalidResponse};return .init(action:current(run.action))}
    func decideAction(_ reference:ConversationTaskActionReference,actionID:String,request:ConversationTaskActionDecisionRequest) async throws -> ConversationTaskActionEnvelope {
        guard mode != .unavailable else {throw ConversationTaskActionDispatchFailure.notSent}
        let identity=key(reference),operation=request.operationID.uuidString.lowercased();var run=try ensure(reference)
        store.decisionPosts += 1
        if let original=run.decisions[operation] {
            guard original.action.id==actionID,original.decision?.decision==request.decision,original.action.action_digest==request.action_digest,original.action.frozen.grant_epoch==request.expected_grant_epoch,original.action.revision>request.expected_revision,original.action.revision-1==request.expected_revision else {try persist();throw catError.conflict}
            try persist();return original
        }
        guard run.action.id==actionID,run.action.action_digest==request.action_digest,run.action.revision==request.expected_revision,request.expected_grant_epoch==reference.binding.grant_epoch,run.action.canDecide(at:Date()) else {try persist();throw catError.conflict}
        run.action.revision += 1;run.action.approval_status=request.decision == .approve ? "approved":"denied";run.action.decision_operation_id=operation;run.action.effect = .init(status:request.decision == .approve ? "waiting_device":"not_dispatched")
        let receipt=ConversationTaskActionDecisionReceipt(operation_id:operation,action_id:actionID,decision:request.decision,action_digest:request.action_digest,committed_at:Self.utc(Date()))
        let envelope=ConversationTaskActionEnvelope(action:run.action,decision:receipt);run.decisions[operation]=envelope;store.runs[identity]=run
        // Fake server commit precedes response loss, so cold restart can read this exact original UUID.
        try persist()
        if mode == .unknown {throw catError.unavailable("Explicit offline fixture lost the decision response after its fake server commit")}
        return envelope
    }
    func readDecision(_ reference:ConversationTaskActionReference,actionID:String,operationID:UUID) async throws -> ConversationTaskActionEnvelope {
        let run=try ensure(reference);store.decisionReads += 1;try persist()
        guard var original=run.decisions[operationID.uuidString.lowercased()],original.action.id==actionID else {throw ConversationTaskActionError.originalNotFound};original.action=current(run.action);return original
    }
    private func ensure(_ reference:ConversationTaskActionReference) throws -> Run {
        let identity=key(reference)
        if let run=store.runs[identity] {try run.action.validate(reference:reference);return run}
        let b=reference.binding,proposal=stableID("P0-action-proposal-"+b.run_id.uuidString).uuidString.lowercased(),created=Self.utc(Date()),createdDate=ConversationTaskActionValidation.utc(created)!,start=createdDate.addingTimeInterval(86400)
        let target=ConversationDeviceCalendarTarget(device_id:stableID("P0-action-device").uuidString.lowercased(),environment_id:stableID("P0-action-environment").uuidString.lowercased(),calendar_id:"synthetic-local-calendar",calendar_display_name:"Synthetic local calendar",calendar_snapshot_hash:textHash("Explicit offline calendar snapshot"))
        let parameters=try ConversationTaskActionJSON.value(ConversationCalendarCreateParameters(title:"Synthetic exact calendar review",start_at:Self.utc(start),end_at:Self.utc(start.addingTimeInterval(3600)),time_zone:"Asia/Shanghai",reminder_offset_seconds:-600))
        let frozen=ConversationTaskActionFrozen(id:try ConversationTaskActionValidation.actionID(runID:b.run_id.uuidString.lowercased(),proposalID:proposal),proposal_operation_id:proposal,scope_id:b.scope_id.uuidString.lowercased(),subject_id:reference.subjectID,conversation_id:b.conversation_id.uuidString.lowercased(),turn_id:b.turn_id.uuidString.lowercased(),run_id:b.run_id.uuidString.lowercased(),task_id:b.task_id,request_hash:b.request_hash,delegation_id:b.delegation_id.uuidString.lowercased(),delegation_revision:b.delegation_revision,grant_epoch:b.grant_epoch,plan_reference:.init(revision:1,plan_hash:textHash("Explicit offline action plan")),kind:"calendar.create.v1",tool_version:1,target:try .value(target),parameters:parameters,parameters_hash:try parameters.digest(),artifact_reference:nil,created_at:created,expires_at:Self.utc(createdDate.addingTimeInterval(1800)))
        let value=ConversationTaskActionSnapshot(frozen:frozen,action_digest:try frozen.digest(),capability:.init(kind:frozen.kind));try value.validate(reference:reference)
        let run=Run(action:value);store.runs[identity]=run;try persist();return run
    }
    private func current(_ stored:ConversationTaskActionSnapshot)->ConversationTaskActionSnapshot {
        var action=stored
        if ConversationTaskActionValidation.utc(action.frozen.expires_at).map({$0<=Date()}) ?? true {action.approval_binding_current=false;action.invalidation_reason="expired";if action.approval_status=="pending" {action.approval_status="expired"};action.effect = .init()}
        return action
    }
    private func key(_ reference:ConversationTaskActionReference)->String {textHash("\(reference.scope.profileID):\(reference.scope.workspaceID):\(reference.subjectID):\(reference.binding.scope_id):\(reference.binding.run_id)")}
    private func persist() throws {let data=try ConversationTaskActionJSON.encoded(store);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url,options:.atomic);statsUpdated?(debugStats())}
    private static func utc(_ date:Date)->String {let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return formatter.string(from:date)}
}
#endif
