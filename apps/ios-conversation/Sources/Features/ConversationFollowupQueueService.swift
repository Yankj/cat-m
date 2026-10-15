import Foundation
// State-machine behavior adapted from OpenMuse conversation-queue.ts, MIT.
// Copyright (c) 2026 OpenMuse contributors. Full attribution: docs/conversation-first/upstream-review/LICENSE.
public actor ConversationFollowupQueueService {
    public enum Disposition: Sendable, Equatable { case sent, heldBeforeAdmission }
    private let repository: Repository
    private let scope: DataScope
    private let conversationID: UUID
    private var draining = false
    // Actor methods await Repository; serialize read/modify/commit across reentrancy.
    private var stateLocked = false
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []
    private func lockState() async {
        if !stateLocked { stateLocked = true;return }
        await withCheckedContinuation { stateWaiters.append($0) }
    }
    private func unlockState() {
        if stateWaiters.isEmpty { stateLocked = false } else { stateWaiters.removeFirst().resume() }
    }
    public init(repository: Repository, scope: DataScope, conversationID: UUID) { self.repository = repository; self.scope = scope; self.conversationID = conversationID }
    public func state() async throws -> ConversationFollowupState {
        await lockState();defer { unlockState() }
        var value = try await load().0
        if !draining && value.inflight != nil && !value.paused { value.paused = true;value.pauseReason = .recovery }
        return value
    }
    public func enqueue(_ message: ConversationFollowup, remainingDraft: String? = nil,remainingContinuationDraft:ConversationArtifactContinuationDraft?=nil,continuationService:ConversationArtifactContinuationService?=nil,acceptedWorkDraft:ConversationAcceptedWorkDraft?=nil,acceptedWorkDraftService:ConversationAcceptedWorkDraftService?=nil) async throws {
        await lockState();defer { unlockState() }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.text.utf16.count <= 8000 else { throw CatpawError.invalid("后续消息超过范围。") }
        if let intent=message.continuation {try intent.validate();guard message.image==nil,remainingDraft==nil else {throw ConversationArtifactContinuationError.invalidReference}}
        else {guard remainingContinuationDraft==nil else {throw ConversationArtifactContinuationError.invalidReference}}
        if message.acceptedWork != nil {guard message.image==nil,message.continuation==nil,acceptedWorkDraft != nil else {throw ConversationSessionError.invalidEvent}}
        else {guard acceptedWorkDraft==nil else {throw ConversationSessionError.invalidEvent}}
        var (state, record) = try await load()
        if let same = (state.pending + [state.inflight].compactMap { $0 }).first(where: { $0.id == message.id }) { guard same==message else { throw CatpawError.conflict }; return }
        state.pending.append(message)
        var additional: [Mutation] = []
        if let target=remainingContinuationDraft,let continuationService,let intent=message.continuation {
            guard continuationService.scope==scope,target.reference.binding.conversation_id==conversationID else {throw CatpawError.scopeMismatch}
            additional.append(try await continuationService.queueMutation(remainingDraft:target,intent:intent))
        } else if remainingContinuationDraft != nil {throw ConversationArtifactContinuationError.invalidReference}
        if let remainingDraft {
            let conversation = try await repository.record(conversationID,scope:scope)
            guard var value = conversation.conversation else { throw CatpawError.missing }
            value.draftText = remainingDraft
            additional = [.update(conversation.id,conversation.header.revision,.core(.conversation(value)))]
        }
        if let draft=acceptedWorkDraft,let selection=message.acceptedWork,let draftService=acceptedWorkDraftService {
            guard draft.conversationID==conversationID,draft.raw==message.text,draftService.scope==scope else {throw CatpawError.conflict}
            additional.append(try await draftService.queueMutation(draft:draft,selection:selection))
        } else if acceptedWorkDraft != nil {throw ConversationSessionError.invalidEvent}
        try Task.checkCancellation()
        try await save(state, record, additional:additional)
    }
    public func remove(_ id: UUID) async throws { await lockState();defer { unlockState() }; var (s,r) = try await load(); s.pending.removeAll { $0.id == id }; try await save(s,r) }
    /// Pause is explicit and persists after editing/closing. Claim and edit share the same lock.
    public func edit(_ expected:ConversationFollowup,text:String,session:ConversationSessionService) async throws -> ConversationFollowup {
        await lockState();defer {unlockState()}
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf16.count <= 8000 else {throw CatpawError.invalid("请输入不超过 8000 字符的内容。")}
        var (s,r)=try await load()
        guard s.paused,let i=s.pending.firstIndex(where:{$0.id == expected.id}),s.pending[i]==expected else {throw CatpawError.conflict}
        // Image authorization is bound to its caption and must be reviewed in the composer.
        guard expected.image == nil else {throw CatpawError.invalid("图片处理许可绑定当前文字。请移除后在输入器重新编辑。")}
        guard expected.acceptedWork == nil else {throw CatpawError.invalid("工作约定绑定原请求。请移除后重新确认，不能沿用旧期限和预算。")}
        let cancellation=try await session.cancellationForQueueEdit(scope:scope,conversationID:conversationID,operationID:expected.id)
        let replacement=ConversationFollowup(text:text,continuation:expected.continuation)
        s.pending[i]=replacement
        try await save(s,r,additional:cancellation.map{[$0]} ?? [])
        return replacement
    }
    public func pause(reason:FollowupPauseReason = .user) async throws { await lockState();defer { unlockState() }; var (s,r) = try await load();if reason == .background,s.paused,s.pauseReason == .user || s.pauseReason == nil { return };s.paused = true;s.pauseReason=reason;try await save(s,r) }
    public func resume(backgroundOnly:Bool = false) async throws { await lockState();defer { unlockState() }; var (s,r) = try await load();if backgroundOnly,s.pauseReason != .background { return };guard s.inflight == nil else { throw ConversationSessionError.unresolvedOperation };s.paused = false;s.pauseReason=nil;try await save(s,r) }
    /// Called only after checking the durable conversation's exact original operation ID.
    public func reconcileInflight(admitted: Bool) async throws {
        guard !draining else { throw ConversationSessionError.busy }
        await lockState();defer { unlockState() }
        var (s,r) = try await load(); guard let original = s.inflight else { return }
        if !admitted { s.pending.insert(original, at: 0) }
        s.inflight = nil; s.paused = true;if s.pauseReason != .background && s.pauseReason != .user { s.pauseReason = .recovery };try await save(s,r)
    }
    public func flush(_ send: @Sendable (ConversationFollowup) async throws -> Disposition) async throws {
        guard !draining else { return }; draining = true; defer { draining = false }
        while let first = try await claimNext() {
            do { let result = try await send(first);try await settle(first,held:result == .heldBeforeAdmission) }
            catch { try await settle(first,failed:true);throw error }
        }
    }
    private func claimNext() async throws -> ConversationFollowup? {
        await lockState();defer { unlockState() }
        var (s,r) = try await load()
        guard !s.paused,s.inflight == nil,let first=s.pending.first else { return nil }
        s.pending.removeFirst();s.inflight=first;try await save(s,r);return first
    }
    private func settle(_ message:ConversationFollowup,held:Bool=false,failed:Bool=false) async throws {
        await lockState();defer { unlockState() }
        var (s,r) = try await load();guard s.inflight == message else { throw CatpawError.conflict }
        s.inflight=nil
        if held { s.pending.insert(message,at:0) }
        if held || failed { s.paused=true;if s.pauseReason != .background && s.pauseReason != .user { s.pauseReason = held ? .preflight : .recovery } }
        try await save(s,r)
    }
    private var recordID: UUID { stableID("conversation-followup-queue-\(conversationID)") }
    private func load() async throws -> (ConversationFollowupState, StoredRecord?) {
        _ = try await repository.record(conversationID, scope: scope)
        let record: StoredRecord
        do { record = try await repository.record(recordID, scope: scope) } catch CatpawError.missing { return (ConversationFollowupState(), nil) }
        guard case .preference(let preference) = record.payload, preference.key == "conversation_followups:\(conversationID)", let data = preference.value.data(using: .utf8) else { throw CatpawError.corrupt("后续消息无法读取，原记录已保留。") }
        return (try JSONDecoder().decode(ConversationFollowupState.self, from: data),record)
    }
    private func save(_ value: ConversationFollowupState, _ record: StoredRecord?, additional:[Mutation] = []) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = Payload.preference(Preference(key: "conversation_followups:\(conversationID)", value: String(decoding: try encoder.encode(value), as: UTF8.self)))
        let mutation: Mutation = record.map { .update($0.id,$0.header.revision,payload) } ?? .create(recordID,payload)
        let conversation=try await repository.record(conversationID,scope:scope)
        guard conversation.conversation != nil else {throw CatpawError.missing}
        try await repository.commit(scope: scope, mutations: [.requireRevision(conversation.id,conversation.header.revision),mutation] + additional)
    }
}
