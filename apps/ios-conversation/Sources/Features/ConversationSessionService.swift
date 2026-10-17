import Foundation
import os
private let observeLog=Logger(subsystem:"catpaw",category:"observe")

public actor ConversationSessionService {
    private let repository: Repository
    private let backend: any ConversationBackend
    // A business epoch stays stable across recovery; each local observer needs its own fence.
    private var active: [UUID: UUID] = [:]
    private static let selectionKey = "conversation_first_selected"
    public nonisolated var supportsArtifactContinuations:Bool {backend.supportsArtifactContinuations}
    public nonisolated var artifactContinuationSubjectID:UUID? {backend.artifactContinuationSubjectID}
    public init(repository: Repository, backend: any ConversationBackend = UnconfiguredConversationBackend(), resilience: (any ConversationStreamResilience)? = nil, reconnectPolicy: ConversationReconnectPolicy = .init(), outbox: ConversationOutbox? = nil, principal: AccountToken? = nil, principalAccount: String? = nil) { self.repository = repository; self.backend = backend; self.resilience = resilience; self.reconnectPolicy = reconnectPolicy; self.outbox = outbox; self.principal = principal; self.principalAccount = principal?.account ?? principalAccount }
    /// Codex p89d-4: the authenticated principal this service was opened for (AccountEpoch token captured by the auth model
    /// when it opened the workspace for that user). Device-call lifecycle events carry THIS token — never "current global".
    /// nil (fixtures / previews) → legacy: the token is captured when the observation is claimed.
    private let principal: AccountToken?
    /// The authenticated user id this service belongs to. A token captured for any other account is never attached.
    private let principalAccount: String?
    private let outbox: ConversationOutbox?
    private struct BusyRetry: Sendable { var due: Date; var operationID: UUID; var autoRetried: Bool }
    private var busyRetry: [UUID: BusyRetry] = [:]
    /// Automatic busy retries already spent per turn (server restarts the SAME turn in place, limit 3).
    private var autoRetryCounts: [UUID: Int] = [:]
    private var busyRetryCancelled: Set<UUID> = []
    public static let maxAutomaticBusyRetries = ConversationBusyRetryPolicy.maxAttempts
    /// Automatic busy retry delay (`ConversationBusyRetryPolicy`): server `retry_after_seconds` wins, else 5 / 15 / 30 s.
    /// attempt is 1-based; past the last attempt the 30 s step is returned (callers check the attempt count first).
    /// `jitter` is kept for source compatibility and ignored: the card counts down to the real due time.
    public static func busyRetryDelay(attempt: Int, retryAfterSeconds: Int?, jitter: Double) -> TimeInterval {
        ConversationBusyRetryPolicy.delay(attempt: min(max(1, attempt), ConversationBusyRetryPolicy.maxAttempts), retryAfterSeconds: retryAfterSeconds) ?? 30
    }
    private var turnObservers: [UUID: AsyncStream<ConversationTurnEvent>.Continuation] = [:]
    private var emittedCancellations: Set<UUID> = []
    private var cancelling: Set<UUID> = []
    /// catpaw.ui.v1 decisions waiting for the current stream to end (FIFO per conversation).
    private final class QueuedUIDecision: @unchecked Sendable {
        let id = UUID(); let scope: DataScope; let conversationID: UUID; let turnID: UUID; let interruptID: String
        let decision: ConversationUIDecision; let argsHash: String; let response: Data?; let operationID: UUID
        /// p89g-1: login source pinned at the PUBLIC submit entry; carried through the queue and checked at dequeue.
        let source: AccountToken?
        var waiters: [CheckedContinuation<UUID, Error>] = []
        init(scope: DataScope, conversationID: UUID, turnID: UUID, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, source: AccountToken?) {
            self.source = source; self.scope = scope; self.conversationID = conversationID; self.turnID = turnID; self.interruptID = interruptID; self.decision = decision; self.argsHash = argsHash; self.response = response; self.operationID = operationID
        }
        func finish(_ result: Result<UUID, Error>) { let all = waiters; waiters = []; for w in all { w.resume(with: result) } }
    }
    private var uiQueue: [UUID: [QueuedUIDecision]] = [:]
    /// catpaw.device.v1: call_id → (conversation, turn) of `device_call`s applied in this process.
    private var deviceCallIndex: [String: (UUID, UUID)] = [:]
    private var uiDraining: Set<UUID> = []
    private var uiClock: @Sendable () -> Date = { Date() }
    /// Test seam for queued-decision expiry.
    public func setUIClock(_ clock: @escaping @Sendable () -> Date) { uiClock = clock }
    private let resilience: (any ConversationStreamResilience)?
    private let reconnectPolicy: ConversationReconnectPolicy
    public func imageCapabilities(scope:DataScope,conversationID:UUID) async throws -> ConversationImageCapability { try await backend.imageCapabilities(scope:scope,conversationID:conversationID) }
    public func revisionWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {try await backend.revisionWorkCapability(scope:scope,conversationID:conversationID)}
    public func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {try await backend.acceptedWorkCapability(scope:scope,conversationID:conversationID)}
    public func imageConsent(scope:DataScope,conversationID:UUID,previewID:UUID,previewHash:String) async throws -> ConversationImageConsent {try await backend.imageConsent(scope:scope,conversationID:conversationID,previewID:previewID,previewHash:previewHash)}
    public func allowImageConsent(scope:DataScope,consent:ConversationImageConsent,nonSensitiveConfirmed:Bool) async throws -> Int {try await backend.allowImageConsent(scope:scope,consent:consent,nonSensitiveConfirmed:nonSensitiveConfirmed)}
    public func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? { try await backend.modelConsent(scope:scope,conversationID:conversationID) }
    public func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws { try await backend.allowModelConsent(scope:scope,consent:consent) }
    public func openLatest(scope: DataScope) async throws -> UUID {
        let snapshot = await repository.read(scope: scope)
        let eligible = snapshot.list("conversation", scope: scope).filter { snapshot.records[Self.journalID($0.id)] != nil }
        let selected = snapshot.list("preference", scope: scope).compactMap { record -> UUID? in
            guard case .preference(let value) = record.payload,value.key == Self.selectionKey else { return nil };return UUID(uuidString:value.value)
        }.first
        if let existing = eligible.first(where: { $0.id == selected }) ?? eligible.first {
            var (saved, savedRevision) = try await readVersioned(scope: scope, conversationID: existing.id)
            if active[existing.id] == nil {
                var changed = false
                for index in saved.turns.indices where [.dispatched, .running].contains(saved.turns[index].state) { saved.turns[index].state = .unknown; saved.turns[index].error = "对话已重开，先读取原请求状态。"; changed = true }
                if changed { try await save(saved, expectedRevision: savedRevision) }
            }
            return existing.id
        }
        return try await create(scope: scope, id: stableID("conversation-first-initial-\(scope.workspaceID)"))
    }
    public func rememberSelection(scope: DataScope, conversationID: UUID) async throws {
        let record = try await repository.record(conversationID,scope:scope)
        guard record.conversation != nil else { throw CatpawError.missing }
        _ = try await read(scope:scope,conversationID:conversationID)
        try await repository.setPreference(scope:scope,key:Self.selectionKey,value:conversationID.uuidString)
    }
    struct NavigationSelectionReceipt:Sendable {
        let recordID:UUID,revision:Int,selectedID:UUID,previous:Preference?
    }
    /// Retains the exact local preference revision so a cancelled preparation can
    /// restore its prior selection without overwriting any later writer.
    func prepareNavigationSelection(scope:DataScope,conversationID:UUID) async throws -> NavigationSelectionReceipt {
        let conversation=try await repository.record(conversationID,scope:scope)
        guard conversation.conversation != nil else {throw CatpawError.missing}
        _=try await read(scope:scope,conversationID:conversationID)
        let id=stableID("preference-\(scope.workspaceID)-\(Self.selectionKey)")
        let old:StoredRecord?
        do {old=try await repository.record(id,scope:scope)}catch CatpawError.missing {old=nil}
        let previous:Preference?
        if let old {guard case .preference(let value)=old.payload,value.key==Self.selectionKey else {throw ConversationSessionError.invalidEvent};previous=value}else{previous=nil}
        let payload=Payload.preference(.init(key:Self.selectionKey,value:conversationID.uuidString))
        let mutation:Mutation=old.map{.update(id,$0.header.revision,payload)} ?? .create(id,payload)
        try Task.checkCancellation()
        try await repository.commit(scope:scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation])
        return .init(recordID:id,revision:(old?.header.revision ?? 0)+1,selectedID:conversationID,previous:previous)
    }
    func rollbackNavigationSelection(scope:DataScope,receipt:NavigationSelectionReceipt) async throws {
        let current=try await repository.record(receipt.recordID,scope:scope)
        guard current.header.revision==receipt.revision,case .preference(let value)=current.payload,
              value.key==Self.selectionKey,value.value==receipt.selectedID.uuidString else {return}
        let mutation:Mutation=receipt.previous.map{.update(current.id,current.header.revision,.preference($0))} ?? .remove(current.id,current.header.revision)
        try await repository.commit(scope:scope,mutations:[mutation])
    }
    public func create(scope: DataScope, id: UUID = UUID()) async throws -> UUID {
        guard Profiles.inEnvironment(.local, profile: scope) == scope else { throw CatpawError.scopeMismatch }
        let snapshot = await repository.read(scope: scope)
        let env = stableID("conversation-first-environment-\(scope.workspaceID)")
        var mutations: [Mutation] = []
        if snapshot.records[env] == nil { mutations.append(.create(env, .core(.environment(ExecutionEnvironment(name: "本机", kind: .local, connection: .connected, capabilityIDs: ["local_conversation"], verifiedAt: nil))))) }
        let conversation = Conversation(title: "新对话", projectID: nil, expertID: nil, skillIDs: [], environmentID: env, archivedAt: nil, draftText: "")
        mutations += [.create(id, .core(.conversation(conversation))), .create(Self.journalID(id), .preference(Preference(key: "conversation_session:\(id)", value: try Self.encode(ConversationSession(scope: scope, conversationID: id)))))]
        try await repository.commit(operationID: stableID("conversation-first-create-\(id)"), scope: scope, mutations: mutations)
        return id
    }
    public func read(scope: DataScope, conversationID: UUID) async throws -> ConversationSession {
        try await readVersioned(scope: scope, conversationID: conversationID).0
    }
    /// Receives an authenticated read projection only for a task already bound in
    /// this local conversation journal. It never invents a turn or grants work.
    public func recordReceivedGoal(scope:DataScope,goal:ConversationGoalProjection) async throws {
        guard let binding=goal.binding else {throw ConversationSessionError.invalidEvent}
        var (saved,revision)=try await readVersioned(scope:scope,conversationID:binding.conversation_id)
        guard saved.goals[goal.id]?.binding==binding else {throw ConversationSessionError.invalidEvent}
        try Self.merge(goal,into:&saved)
        if var current=saved.goals[goal.id],current.sourceAuthorizationCurrent != false {
            for artifact in goal.artifactHistory {
                guard artifact.version>0,textHash(artifact.body)==artifact.contentHash else {throw ConversationSessionError.invalidEvent}
                if let old=(current.artifacts+current.artifactHistory).first(where:{$0.id==artifact.id && $0.version==artifact.version}) {
                    guard old.contentHash==artifact.contentHash,old.body==artifact.body else {throw ConversationSessionError.invalidEvent}
                } else {current.artifactHistory.append(artifact)}
            }
            saved.goals[goal.id]=current
        }
        let record=try await repository.record(binding.conversation_id,scope:scope)
        try Task.checkCancellation()
        try await save(saved,expectedRevision:revision,additional:[.requireRevision(record.id,record.header.revision)])
    }
    /// Records a verified artifact projection without changing task completion or sending a turn.
    public func recordArtifactRevision(scope:DataScope,binding:ConversationTaskBinding,artifact:ConversationArtifactProjection) async throws {
        var (saved,revision)=try await readVersioned(scope:scope,conversationID:binding.conversation_id)
        guard let goal=saved.goals[binding.task_id],goal.binding==binding,goal.sourceAuthorizationCurrent != false,
              goal.artifacts.contains(where:{$0.id==artifact.id}),artifact.version>0,
              artifact.body.utf8.count<=1_000_000,textHash(artifact.body)==artifact.contentHash else {throw ConversationSessionError.invalidEvent}
        let object=try JSONSerialization.jsonObject(with:Data(artifact.body.utf8)) as? [String:Any]
        let data=object?["data"] as? [String:Any]
        guard object?["title"] as? String==artifact.title,object?["summary"] as? String==artifact.summary,
              data?["content"] as? String==artifact.content else {throw ConversationSessionError.invalidEvent}
        var updated=ConversationGoalProjection(id:goal.id,revision:goal.revision,title:artifact.title,state:goal.state,summary:artifact.summary,updatedAt:Date())
        updated.binding=goal.binding;updated.artifactHistory=goal.artifactHistory;updated.sourceAuthorizationCurrent=goal.sourceAuthorizationCurrent;updated.revisionRequiresNewWork=goal.revisionRequiresNewWork;updated.revisionWorkPolicy=goal.revisionWorkPolicy
        updated.artifacts=goal.artifacts.map{$0.id==artifact.id ? artifact : $0}
        try Self.merge(updated,into:&saved)
        let conversation=try await repository.record(binding.conversation_id,scope:scope)
        guard conversation.conversation != nil else {throw CatpawError.missing}
        try await save(saved,expectedRevision:revision,additional:[.requireRevision(conversation.id,conversation.header.revision)])
    }
    private func readVersioned(scope: DataScope, conversationID: UUID) async throws -> (ConversationSession, Int) {
        _ = try await repository.record(conversationID, scope: scope)
        let record = try await repository.record(Self.journalID(conversationID), scope: scope)
        guard case .preference(let stored) = record.payload, let data = stored.value.data(using: .utf8) else { throw CatpawError.corrupt("对话历史无法读取。") }
        let value = try JSONDecoder().decode(ConversationSession.self, from: data)
        guard value.scope == scope, value.conversationID == conversationID else { throw CatpawError.scopeMismatch }
        return (value, record.header.revision)
    }
    public func connection(scope: DataScope) async -> ConversationConnection { await backend.connection(scope: scope) }
    public func recordedReplyEvidence(scope:DataScope) async -> ConversationConnection? {await backend.recordedReplyEvidence(scope:scope)}
    public func saveDraft(scope: DataScope, conversationID: UUID, text: String) async throws {
        let record = try await repository.record(conversationID, scope: scope)
        guard var value = record.conversation else { throw CatpawError.missing }
        value.draftText = text
        try await repository.commit(scope: scope, mutations: [.update(record.id, record.header.revision, .core(.conversation(value)))])
    }
    /// Idempotent merge of the server transcript into the local one. Known ids keep the local row (createdAt,
    /// failure, tool metadata) in local order; server-only rows are inserted where the server places them,
    /// i.e. before the next locally known server row. Local-only rows (unsent messages, failure notices, tool rows)
    /// keep their position. A server-only row gets the createdAt of the row before it (keeps createdAt sorting stable).
    static func mergeServerTranscript(local: [ConversationTranscriptMessage], server: [ConversationTranscriptMessage]) -> [ConversationTranscriptMessage] {
        let localIDs = Set(local.map(\.id))
        var seen = Set<UUID>(), result: [ConversationTranscriptMessage] = [], next = 0
        func place(_ message: ConversationTranscriptMessage) {
            guard seen.insert(message.id).inserted else { return }
            let anchor = result.last?.createdAt ?? .distantPast
            result.append(ConversationTranscriptMessage(id: message.id, role: message.role, content: message.content, complete: true, createdAt: max(anchor, message.createdAt)))
        }
        for message in local {
            if let at = server.firstIndex(where: { $0.id == message.id }), at >= next {
                for pending in server[next..<at] where !localIDs.contains(pending.id) { place(pending) }
                next = at + 1
            }
            if seen.insert(message.id).inserted { result.append(message) }
        }
        for pending in server[min(next, server.count)...] where !localIDs.contains(pending.id) { place(pending) }
        return result
    }
    /// Pull the server transcript and merge it (open conversation / before send). Returns true when rows were added.
    /// Skipped while a turn is in flight or unresolved so streaming rows are never reordered.
    @discardableResult public func syncServerTranscript(scope: DataScope, conversationID: UUID) async throws -> Bool {
        guard active[conversationID] == nil, let server = try await backend.serverTranscript(scope: scope, conversationID: conversationID), !server.isEmpty else { return false }
        var (session, revision) = try await readVersioned(scope: scope, conversationID: conversationID)
        guard session.unresolved == nil, active[conversationID] == nil else { return false }
        let merged = Self.mergeServerTranscript(local: session.messages, server: server)
        guard merged.count != session.messages.count else { return false }
        sendDiagnostic("catpaw.send transcript synced server=\(server.count) local=\(session.messages.count) merged=\(merged.count)")
        session.messages = merged
        try await save(session, expectedRevision: revision)
        return true
    }
    /// Wire history for a turn: the local transcript minus user messages of other turns that never reached the
    /// server (notSent / cancelledBeforeSend). Those stay visible locally but would make the server history a
    /// strict prefix of ours, which prepare() correctly rejects as a conflict and which used to deadlock the queue.
    static func dispatchHistory(_ session: ConversationSession, current: UUID) -> [ConversationTranscriptMessage] {
        let unsent = Set(session.turns.filter { $0.id != current && [.notSent, .cancelledBeforeSend].contains($0.state) }.map { stableID("conversation-user-\($0.id)") })
        return session.messages.filter { !unsent.contains($0.id) }
    }
    public func send(scope: DataScope, conversationID: UUID, text: String, operationID: UUID, context: [ConversationExplicitContext] = [], preserveDraft:Bool = false,image:ConversationVisionPayload?=nil,continuation:ConversationArtifactContinuationIntent?=nil,acceptedWork:ConversationAcceptedWorkSelection?=nil,revisionWork:ConversationRevisionWorkSelection?=nil) async throws -> UUID {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let turnToken = ConversationSideChannelEvents.beginTurnToken(operationID)   // Codex PR91 #1: one token per turn, bound before any await; resumed streams use the registry
        // R7 offline send: a plain text turn is journaled and parked in the outbox without any POST.
        let plainSend = context.isEmpty && image == nil && continuation == nil && acceptedWork == nil && revisionWork == nil && outbox != nil
        let offline = plainSend ? !(await resilience?.isPathSatisfied() ?? true) : false
        let connection = offline ? ConversationConnection(state: .providerUnverified, provider: "", detail: "") : await backend.connection(scope: scope)
        guard [.connected, .providerUnverified].contains(connection.state) else {
            if connection.state == .unavailable { throw CatpawError.unavailable(connection.detail) }
            throw ConversationSessionError.notConfigured
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8000 else { throw CatpawError.invalid("请输入不超过 8000 字符的内容。") }
        if plainSend, !offline {
            do { try await syncServerTranscript(scope: scope, conversationID: conversationID) }
            catch { sendDiagnostic("catpaw.send transcript sync skipped: \(String(describing: error))") }
        }
        var (session, journalRevision) = try await readVersioned(scope: scope, conversationID: conversationID)
        var request: ConversationTurnRequest
        let epoch: Int
        if let index = session.turns.firstIndex(where: { $0.id == operationID }) {
            let prior = session.turns[index]
            guard prior.request.image == image?.reference,prior.request.continuation==continuation,prior.request.acceptedWork?.selection==acceptedWork,prior.request.revisionWork?.selection==revisionWork else {sendDiagnostic("catpaw.send conflict site=resend.payload op=\(operationID.uuidString.prefix(8))");throw CatpawError.conflict}
            guard prior.request.history.last?.content == text, try Self.encode(prior.request.context) == Self.encode(context) else { sendDiagnostic("catpaw.send conflict site=resend.text op=\(operationID.uuidString.prefix(8)) priorLen=\(prior.request.history.last?.content.utf16.count ?? -1) len=\(text.utf16.count)");throw CatpawError.conflict }
            guard prior.state != .cancelledBeforeSend else { sendDiagnostic("catpaw.send conflict site=resend.cancelled op=\(operationID.uuidString.prefix(8))");throw CatpawError.conflict }
            guard prior.state == .notSent else { return operationID }
            guard session.unresolved == nil else { throw ConversationSessionError.unresolvedOperation }
            if prior.request.acceptedWork == nil, prior.request.revisionWork == nil {
                // Resend of a held message: rebuild history from what the server can have seen, with this
                // message last. Other unsent messages never enter the wire history.
                guard let own = prior.request.history.last, own.role == .user else { sendDiagnostic("catpaw.send conflict site=resend.own op=\(operationID.uuidString.prefix(8))");throw CatpawError.conflict }
                let history = Self.dispatchHistory(session, current: operationID).filter { $0.id != own.id } + [own]
                request = prior.request.withHistory(history).withImageBytes(image?.bytes); epoch = request.epoch
                session.turns[index] = ConversationTurnRecord(id: operationID, request: request.withImageBytes(nil), state: .dispatched, lastSequence: 0, error: nil)
            } else {
                guard try Self.encode(prior.request.history) == Self.encode(Self.dispatchHistory(session, current: operationID)) else { throw ConversationSessionError.unresolvedOperation }
                request = prior.request.withImageBytes(image?.bytes); epoch = request.epoch
                session.turns[index].state = .dispatched; session.turns[index].error = nil
            }
        } else {
            guard session.unresolved == nil else { throw ConversationSessionError.unresolvedOperation }
            guard session.pendingUnsent == nil else { throw ConversationSessionError.pendingUnsent }
            epoch = session.turns.count + 1
            guard context.count <= 8, Set(context.map(\.id)).count == context.count, context.allSatisfy({ !$0.id.isEmpty && $0.id.utf16.count <= 80 && $0.text.utf16.count <= 8000 }) else { throw CatpawError.invalid("附加上下文超过服务范围。") }
            var originalBinding:ConversationTaskBinding?,continuationSubject:UUID?
            if let continuation {
                try continuation.validate()
                guard image==nil,backend.supportsArtifactContinuations,let subject=backend.artifactContinuationSubjectID,
                      let goal=session.goals[continuation.taskID],(goal.sourceAuthorizationCurrent != false || (revisionWork != nil && goal.revisionRequiresNewWork==true)),
                      let binding=goal.binding,binding.conversation_id==conversationID,binding.run_id==continuation.runID,binding.task_id==continuation.taskID,binding.grant_epoch==continuation.expectedGrantEpoch,
                      (goal.artifacts+goal.artifactHistory).contains(where:{$0.id==continuation.artifactReference.artifactID && $0.version==continuation.artifactReference.version && $0.contentHash==continuation.artifactReference.contentHash}) else {throw ConversationDispatchFailure.notSent(reason:ConversationArtifactContinuationError.invalidReference.localizedDescription)}
                guard continuation.intent != .reviseReport || goal.revisionRequiresNewWork != true || revisionWork != nil else {throw ConversationDispatchFailure.notSent(reason:"修改这份成果需要新的工作约定，请先核对后确认。")}
                originalBinding=binding;continuationSubject=subject
            }
            session.messages.append(ConversationTranscriptMessage(id: stableID("conversation-user-\(operationID)"), role: .user, content: text,image:image?.reference.receipt))
            var provisional = ConversationTurnRequest(scope: scope, conversationID: conversationID, threadID: session.threadID, operationID: operationID, epoch: epoch, history: Self.dispatchHistory(session, current: operationID), context: context,image:image?.reference,imageBytes:image?.bytes,continuation:continuation,continuationOriginalBinding:originalBinding,continuationSubjectID:continuationSubject)
            if let selection=acceptedWork {
                guard image==nil,continuation==nil else {throw ConversationDispatchFailure.notSent(reason:"工作约定不能与图片或成果修改混用。")}
                let capability=try await backend.acceptedWorkCapability(scope:scope,conversationID:conversationID)
                try Task.checkCancellation();try selection.validate(capability:capability,now:Date())
                // The explicit confirmed queue entry precedes this optional empty-conversation creation.
                // No turn/model/grant can be sent until the exact wire is frozen and journaled below.
                try await backend.ensureConversationForExplicitSend(provisional);try Task.checkCancellation()
                let intent=try await backend.freezeAcceptedWork(provisional,selection:selection);try Task.checkCancellation()
                guard intent.selection==selection else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
                provisional=try provisional.withAcceptedWork(intent)
            }
            if let selection=revisionWork {
                guard acceptedWork==nil,image==nil,continuation==selection.target,session.goals[selection.target.taskID]?.revisionRequiresNewWork==true else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
                guard let policy=session.goals[selection.target.taskID]?.revisionWorkPolicy else {throw ConversationAcceptedWorkError.invalidSelection};try policy.validate(options:selection.options)
                let capability=try await backend.revisionWorkCapability(scope:scope,conversationID:conversationID);try Task.checkCancellation();try selection.validate(capability:capability,now:Date())
                let intent=try await backend.freezeRevisionWork(provisional,selection:selection);try Task.checkCancellation()
                guard intent.selection==selection else {throw ConversationAcceptedWorkError.invalidFrozenIntent};provisional=try provisional.withRevisionWork(intent)
            }
            request=provisional
            if let image,let message=request.history.last {try image.reference.validate(image.bytes,messageID:message.id)}
            session.turns.append(ConversationTurnRecord(id: operationID, request: request, state: .dispatched, lastSequence: 0, error: nil))
        }
        request.accountToken = turnToken
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let observationToken = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == observationToken { releaseActive(conversationID) } }
        let cr = try await repository.record(conversationID, scope: scope)
        guard var conversation = cr.conversation else { throw CatpawError.missing }
        if !preserveDraft && request.continuation == nil { conversation.draftText = "" }; if conversation.title == "新对话" { conversation.title = String(text.prefix(40)) }
        try await save(session, expectedRevision: journalRevision, fence: request, observationToken: observationToken, additional: [.update(cr.id, cr.header.revision, .core(.conversation(conversation)))])
        do {
            if offline { throw ConversationDispatchFailure.notSent(reason: Self.waitingForNetwork) }
            return try await pump(try await backend.reply(request), request: request, observationToken: observationToken)
        } catch {
            if active[conversationID] == observationToken {
                if error is ConversationDispatchFailure {
                    try await markNotSent(request, reason: error.localizedDescription, observationToken: observationToken)
                    let pathOK = await resilience?.isPathSatisfied() ?? true
                    if plainSend, let outbox, offline || !pathOK {
                        try? await outbox.enqueue(ConversationOutboxEntry(id: operationID, scope: scope, conversationID: conversationID, text: text))
                        await resilience?.outboxChanged(pending: await outbox.entries().map(\.id))
                    }
                }
                else { try await markUnknown(request, reason: error.localizedDescription, observationToken: observationToken) }
            }
            throw error
        }
    }
    /// Single turn event pump for send, busy retry and outbox drain (same apply → journal → turnEvents path).
    private func pump(_ first: AsyncThrowingStream<ConversationTurnEvent, Error>, request: ConversationTurnRequest, observationToken: UUID) async throws -> UUID {
        var stream = first
        let scope = request.scope, conversationID = request.conversationID, operationID = request.operationID
        var attempt = 0
        // R7 §5.3: a transport drop after POST is resumed by GET-after-lastSequence with backoff;
        // events at or below lastSequence are ignored by apply(), so text is only appended.
        resumeLoop: while true {
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    guard active[conversationID] == observationToken else { throw CancellationError() }
                    observeLog.info("pump event seq=\(event.sequence, privacy: .public) \(String(describing: event.payload).prefix(60), privacy: .public)")
                    try await apply(event, request: request, observationToken: observationToken)
                    if attempt > 0 { attempt = 0; await resilience?.resumed() }
                    let saved = try await read(scope: scope, conversationID: conversationID)
                    if let turn = saved.turns.last, [.completed, .failed, .unknown].contains(turn.state) { break resumeLoop }
                    // Stop only at turn_suspended: approval_requested alone already sets pendingApprovals,
                    // and breaking there would drop the suspension event (and any further interrupts of the round).
                    if case .suspended = event.payload, saved.turns.last?.awaitingApproval == true { break resumeLoop }
                }
                break resumeLoop
            } catch let interrupted as ConversationStreamInterrupted {
                await resilience?.waitForPath() // offline does not count an attempt
                guard let delay = reconnectPolicy.delay(forAttempt: attempt) else { await resilience?.unreachable(); throw CatpawError.unavailable(interrupted.reason + "已显示的部分都保留了；继续获取会从断点接上，不会重新发送你的消息。") }
                attempt += 1; await resilience?.reconnecting(attempt: attempt, retryIn: delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard active[conversationID] == observationToken else { throw CancellationError() }
                let last = try await read(scope: scope, conversationID: conversationID).turns.first(where: { $0.id == operationID })?.lastSequence ?? 0
                do { stream = try await backend.resumeEvents(request, afterSequence: last) }
                catch let again as ConversationStreamInterrupted { stream = AsyncThrowingStream<ConversationTurnEvent, Error> { $0.finish(throwing: again) } }
            }
        }
        await resilience?.settled()
        let saved = try await read(scope: scope, conversationID: conversationID)
        if let last = saved.turns.last, last.id == operationID, last.state == .failed, last.error == Self.rateLimitedCode {
            // Busy: the card counts down to the real due time, then foregroundTick retries the SAME turn in place.
            // Only plain turns can be restarted in place; an image turn (bytes are not kept by the server) and an
            // exhausted / cancelled turn get no countdown: the bubble shows 「发送失败 · 重试 / 删除」 instead.
            let spent = autoRetryCounts[operationID] ?? 0
            let delay = Self.isPlain(request) && !busyRetryCancelled.contains(operationID) ? ConversationBusyRetryPolicy.delay(attempt: spent + 1, retryAfterSeconds: last.retryAfterSeconds) : nil
            sendDiagnostic("catpaw.send busy retry scheduled op=\(operationID.uuidString.prefix(8)) attempt=\(spent + 1)/\(Self.maxAutomaticBusyRetries) exhausted=\(delay == nil) delay=\(delay.map { ConversationBusyRetryPolicy.displaySeconds($0) } ?? -1)")
            if let delay {
                busyRetry[conversationID] = BusyRetry(due: Date().addingTimeInterval(delay), operationID: operationID, autoRetried: false)
                await resilience?.busy(retryIn: ConversationBusyRetryPolicy.displaySeconds(delay))
            } else {
                // Kept (autoRetried) so the manual 重试 can still restart a plain turn; never a frozen "0 秒" card.
                busyRetry[conversationID] = Self.isPlain(request) ? BusyRetry(due: Date(), operationID: operationID, autoRetried: true) : nil
                await resilience?.clearBusy()
            }
        }
        if saved.turns.last?.state == .completed { try? await outbox?.remove(operationID); await backend.recordCommittedReply(request);return operationID }
        // catpaw.approval.v1: a suspended turn is admitted and waiting for submitApproval (not an error).
        if let last = saved.turns.last, last.id == operationID, last.awaitingApproval { try? await outbox?.remove(operationID); return operationID }
        if saved.turns.last?.state == .failed { throw CatpawError.unavailable(saved.turns.last?.error ?? "服务请求失败。") }
        throw ConversationSessionError.unresolvedOperation
    }
    private func save(_ value: ConversationSession, expectedRevision: Int, fence: ConversationTurnRequest? = nil, observationToken: UUID? = nil, additional: [Mutation] = []) async throws {
        let r = try await repository.record(Self.journalID(value.conversationID), scope: value.scope)
        guard r.header.revision == expectedRevision else { sendDiagnostic("catpaw.send conflict site=journal.revision expected=\(expectedRevision) actual=\(r.header.revision)");throw CatpawError.conflict }
        if fence != nil { guard let observationToken,active[value.conversationID] == observationToken else { throw CancellationError() } }
        try await repository.commit(scope: value.scope, mutations: [.update(r.id, r.header.revision, .preference(Preference(key: "conversation_session:\(value.conversationID)", value: try Self.encode(value))))] + additional)
    }
    private func apply(_ event: ConversationTurnEvent, request: ConversationTurnRequest, observing: Bool = false, observationToken: UUID) async throws {
        guard active[request.conversationID] == observationToken else { throw CancellationError() }
        guard event.operationID == request.operationID, event.epoch == request.epoch else { throw ConversationSessionError.invalidEvent }
        var (session, journalRevision) = try await readVersioned(scope: request.scope, conversationID: request.conversationID)
        guard let index = session.turns.firstIndex(where: { $0.id == request.operationID }) else { throw CatpawError.missing }
        var turn = session.turns[index]
        if event.sequence <= turn.lastSequence {
            // Repair a former client's uncommitted blank row only after the original server
            // completion is read back. Other turns and unverified local history stay intact.
            if observing, event.sequence == turn.lastSequence, turn.state == .completed,
               case .completed(let id, let hash, _) = event.payload, turn.assistantMessageID == id,
               let message = session.messages.firstIndex(where: { $0.id == id }),
               Self.isBlankDelegationReply(session, message: message, request: request) {
                guard textHash(session.messages[message].content) == hash else { throw ConversationSessionError.invalidEvent }
                session.messages.remove(at: message)
                try await save(session, expectedRevision: journalRevision, fence: request, observationToken: observationToken)
            }
            return
        }
        // R7 busy retry: the server may restart the SAME turn after failed{rate_limited} with no output;
        // its events continue after lastSequence, so the failed state is reopened only in that case.
        let busyRestart = turn.state == .failed && turn.error == Self.rateLimitedCode && turn.assistantMessageID == nil && Self.isPlain(request)
        guard event.sequence == turn.lastSequence + 1, busyRestart || ![.completed, .failed].contains(turn.state), observing || turn.state != .unknown else { throw ConversationSessionError.invalidEvent }
        if busyRestart { turn.error = nil; turn.retryAfterSeconds = nil }
        turn.state = .running; turn.lastSequence = event.sequence
        let deviceCallsBefore = Set((turn.pendingDeviceCalls ?? []).map(\.callID))   // Codex PR #89: gate lifecycle
        switch event.payload {
        case .thread(let id):
            guard !id.isEmpty, session.threadID == nil || session.threadID == id else { throw ConversationSessionError.invalidEvent }; session.threadID = id
        case .started(let hash, let revision, let grant,let receipts):
            if let image=request.image {guard receipts == [image.receipt] else {throw ConversationSessionError.invalidEvent}} else if let ids=request.attachmentIDs,!ids.isEmpty {guard let receipts,receipts.map(\.id)==ids else {throw ConversationSessionError.invalidEvent}} else {guard receipts == nil || receipts?.isEmpty == true else {throw ConversationSessionError.invalidEvent}}
            guard hash.count == 64, revision > 0, grant > 0, turn.serverRequestHash == nil || turn.serverRequestHash == hash, turn.serverGrantEpoch == nil || turn.serverGrantEpoch == grant else { throw ConversationSessionError.invalidEvent }
            turn.serverRequestHash = hash; turn.serverConversationRevision = revision; turn.serverGrantEpoch = grant; session.threadID = request.conversationID.uuidString
        case .textDelta(let id, let text):
            if let known = turn.assistantMessageID { guard known == id else { throw ConversationSessionError.invalidEvent } }
            else { guard !session.messages.contains(where: { $0.id == id }) else { throw ConversationSessionError.invalidEvent }; turn.assistantMessageID = id; session.messages.append(ConversationTranscriptMessage(id: id, role: .assistant, content: "", complete: false)) }
            guard let message = session.messages.firstIndex(where: { $0.id == id }) else { throw ConversationSessionError.invalidEvent }
            session.messages[message].content += text
        case .toolStarted(let call, let name, let arguments):
            guard request.image==nil else {throw ConversationSessionError.invalidEvent}
            guard (["delegate_task", "delegate_plan_v1", "delegate_sources_v1", "agent_status", "present_cgui_v1", "propose_memory_v1"].contains(name) && request.continuation == nil) || (Self.approvalToolNames.contains(name) && Self.isPlain(request)) || (name == (request.revisionWork==nil ? "revise_current_report_v1":ConversationRevisionWorkCodec.toolName) && request.continuation?.intent == .reviseReport), !call.isEmpty else { throw ConversationSessionError.invalidEvent }
            let id = stableID("conversation-call-\(request.operationID)-\(call)")
            guard !session.messages.contains(where: { $0.id == id }) else { throw ConversationSessionError.invalidEvent }
            session.messages.append(ConversationTranscriptMessage(id: id, role: .assistant, content: arguments, toolCallID: call, toolName: name, complete: false))
        case .toolResult(let result):
            guard request.image==nil else {throw ConversationSessionError.invalidEvent}
            let callID = stableID("conversation-call-\(request.operationID)-\(result.callID)")
            guard let call = session.messages.firstIndex(where: { $0.id == callID }), session.messages[call].toolName == result.name, !session.messages[call].complete else { throw ConversationSessionError.invalidEvent }
            // A compiled presentation tool can carry data, never committed domain authority.
            guard result.name != "present_cgui_v1" || result.committedGoals.isEmpty else { throw ConversationSessionError.invalidEvent }
            if result.name=="propose_memory_v1" {
                guard result.committedGoals.isEmpty,result.continuationReceipt==nil,let receipt=result.memoryProposalReceipt,
                      try ConversationMemoryProposalReceipt.decode(Data(result.content.utf8),request:request)==receipt else {throw ConversationSessionError.invalidEvent}
            } else {guard result.memoryProposalReceipt==nil else {throw ConversationSessionError.invalidEvent}}
            if result.name == "revise_current_report_v1" || result.name == ConversationRevisionWorkCodec.toolName {
                if let intent=request.revisionWork {
                    guard result.name==ConversationRevisionWorkCodec.toolName,let outer=result.revisionWorkReceipt,try ConversationRevisionWorkReceipt.decode(Data(result.content.utf8))==outer,result.continuationReceipt==outer.revision,turn.revisionWorkReceipt==nil || turn.revisionWorkReceipt==outer else {throw ConversationSessionError.invalidEvent}
                    try outer.validate(request:request,intent:intent,callID:result.callID);turn.revisionWorkReceipt=outer
                } else {guard result.revisionWorkReceipt==nil,result.name=="revise_current_report_v1" else {throw ConversationSessionError.invalidEvent}}
                guard let receipt=result.continuationReceipt,receipt.state=="accepted",let target=request.continuation,let original=request.continuationOriginalBinding,
                      session.goals[target.taskID]?.binding==original,(session.goals[target.taskID]?.sourceAuthorizationCurrent != false || (request.revisionWork != nil && session.goals[target.taskID]?.revisionRequiresNewWork==true)),
                      result.committedGoals.count<=1 else {throw ConversationSessionError.invalidEvent}
                try receipt.validate(request:request,callID:result.callID)
                let receiptData=request.revisionWork==nil ? Data(result.content.utf8):try ConversationTaskActionJSON.encoded(receipt)
                let raw=try ConversationStrictJSON.object(receiptData,maxBytes:48000)
                guard Set(raw.keys).isSubset(of:ConversationTaskRevisionReceipt.immutableKeys.union(["state","receipt_hash"])),
                      try JSONDecoder().decode(ConversationTaskRevisionReceipt.self,from:JSONSerialization.data(withJSONObject:raw))==receipt,
                      turn.continuationReceipt==nil || turn.continuationReceipt==receipt else {throw ConversationSessionError.invalidEvent}
                for goal in result.committedGoals {
                    guard goal.id==target.taskID,goal.binding==original,receipt.permitsCurrentPlan(goal.planReference),
                          goal.state != .completed || (goal.artifacts+goal.artifactHistory).contains(where:receipt.matchesModelArtifact) else {throw ConversationSessionError.invalidEvent}
                }
                turn.continuationReceipt=receipt
            } else {guard result.continuationReceipt==nil,result.revisionWorkReceipt==nil else {throw ConversationSessionError.invalidEvent}}
            session.messages[call].complete = true
            session.messages.append(ConversationTranscriptMessage(id: stableID("conversation-tool-result-\(request.operationID)-\(result.callID)"), role: .tool, content: result.content, toolCallID: result.callID, toolName: result.name))
            for goal in result.committedGoals {
                guard !goal.id.isEmpty, goal.revision > 0, goal.revision >= (session.goals[goal.id]?.revision ?? 0) else { throw ConversationSessionError.invalidEvent }
                try Self.merge(goal, into: &session,revisionWorkReceipt:result.revisionWorkReceipt)
            }
        case .completed(let id, let hash,let visionReceipt):
            if request.continuation?.intent == .reviseReport,session.messages.contains(where:{Self.isToolAttempt($0,for:request) && $0.toolName==(request.revisionWork==nil ? "revise_current_report_v1":ConversationRevisionWorkCodec.toolName)}) {guard turn.continuationReceipt != nil else {throw ConversationSessionError.invalidEvent}}
            if request.continuation?.intent != .reviseReport {guard turn.continuationReceipt==nil else {throw ConversationSessionError.invalidEvent}}
            if let image=request.image {guard let visionReceipt,visionReceipt.matches(image) else {throw ConversationSessionError.invalidEvent};turn.visionProviderReceipt=visionReceipt} else {guard visionReceipt == nil else {throw ConversationSessionError.invalidEvent}}
            guard session.messages.filter({ Self.isToolAttempt($0, for: request) && !$0.complete }).isEmpty else { throw ConversationSessionError.invalidEvent }
            if turn.assistantMessageID == nil { guard !session.messages.contains(where: { $0.id == id }) else { throw ConversationSessionError.invalidEvent }; turn.assistantMessageID = id; session.messages.append(ConversationTranscriptMessage(id: id, role: .assistant, content: "")) }
            guard turn.assistantMessageID == id, let message = session.messages.firstIndex(where: { $0.id == id }), textHash(session.messages[message].content) == hash else { throw ConversationSessionError.invalidEvent }
            session.messages[message].complete = true
            // The existing server completes a delegation receipt without committing blank prose.
            // Keep its turn/message identity and tool projection, but do not invent a transcript row:
            // that row would make the next turn disagree with the authoritative conversation history.
            if Self.isBlankDelegationReply(session, message: message, request: request) {
                session.messages.remove(at: message)
            }
            turn.state = .completed; turn.error = nil; turn.pendingApprovals = nil; turn.pendingDeviceCalls = nil
        case .reasoningSummary(_, let text, let ms):
            guard turn.assistantMessageID == nil else { throw ConversationSessionError.invalidEvent }
            turn.reasoningSummary = text; turn.thinkingMs = ms
        case .approvalRequested(let approval):
            let callRow = stableID("conversation-call-\(request.operationID)-\(approval.callID)")
            guard Self.isPlain(request), session.messages.contains(where: { $0.id == callRow && $0.toolName == approval.tool && !$0.complete }),
                  !(turn.pendingApprovals ?? []).contains(where: { $0.interruptID == approval.interruptID || $0.callID == approval.callID }) else { throw ConversationSessionError.invalidEvent }
            turn.pendingApprovals = (turn.pendingApprovals ?? []) + [approval]
            if !(turn.approvalLog ?? []).contains(where: { $0.interruptID == approval.interruptID }) { turn.approvalLog = (turn.approvalLog ?? []) + [approval] }   // chat-context-1522 #3
        case .uiBlock(let ui), .uiBlockUpdate(let ui), .uiBlockResolve(let ui):
            guard Self.isPlain(request), ui.sequence == event.sequence else { throw ConversationSessionError.invalidEvent }
            var journal = turn.uiEvents ?? []
            if !journal.contains(where: { $0.sequence == ui.sequence }) {
                switch ui.type {
                case .block: guard !journal.contains(where: { $0.type == .block && $0.id == ui.id }) else { throw ConversationSessionError.invalidEvent }
                case .update: guard journal.contains(where: { $0.type == .block && $0.id == ui.id && !$0.waitsForDecision }) else { throw ConversationSessionError.invalidEvent }
                case .resolve: guard journal.contains(where: { $0.type == .block && $0.id == ui.id }) else { throw ConversationSessionError.invalidEvent }
                }
                journal.append(ui); journal.sort { $0.sequence < $1.sequence }; turn.uiEvents = journal
            }
        case .deviceCall(let call):
            guard Self.isPlain(request) else { throw ConversationSessionError.invalidEvent }
            if !(turn.pendingDeviceCalls ?? []).contains(where: { $0.callID == call.callID }) { turn.pendingDeviceCalls = (turn.pendingDeviceCalls ?? []) + [call] }
            if !(turn.deviceCallLog ?? []).contains(where: { $0.callID == call.callID }) { turn.deviceCallLog = (turn.deviceCallLog ?? []) + [call] }   // chat-context-1522 #3
            deviceCallIndex[call.callID] = (request.conversationID, request.operationID); rememberDeviceTurn(call.callID, request.conversationID, request.operationID)
        case .suspended(let ids, _, let requiresApproval, let waitingFor):
            let pending = Set((turn.pendingApprovals ?? []).map(\.interruptID)).union((turn.pendingDeviceCalls ?? []).map(\.interruptID)).union(turn.pendingUIBlocks.compactMap(\.interruptID)).union((turn.pendingUIApprovals ?? []).map(\.interruptID))
            guard !ids.isEmpty, Set(ids).isSubset(of: pending) else { throw ConversationSessionError.invalidEvent }
            // A server-confirmed suspension proves the turn is alive and waiting on this client: an `unknown` left by an
            // earlier failed apply must become `running` again, otherwise awaitingApproval stays false and no card shows.
            if turn.state == .unknown { turn.state = .running }
            turn.suspendedRequiresApproval = requiresApproval; turn.suspendedWaitingFor = waitingFor
        case .approvalResolved(let id, let call, let decision, _):
            turn.interactionDecisions = (turn.interactionDecisions ?? [:]).merging([id.lowercased(): decision]) { _, new in new }   // chat-context-1522 #3
            // A replay/observe may resolve an interrupt this journal never saw pending (e.g. expired while offline).
            if let i = turn.pendingApprovals?.firstIndex(where: { $0.interruptID == id }) { guard turn.pendingApprovals?[i].callID == call else { throw ConversationSessionError.invalidEvent }; turn.pendingApprovals?.remove(at: i) }
            if turn.pendingApprovals?.isEmpty == true { turn.pendingApprovals = nil }
            turn.pendingUIApprovals?.removeAll { $0.interruptID == id.lowercased() }
            if turn.pendingUIApprovals?.isEmpty == true { turn.pendingUIApprovals = nil }
            turn.pendingDeviceCalls?.removeAll { $0.interruptID == id.lowercased() }
            if turn.pendingDeviceCalls?.isEmpty == true { turn.pendingDeviceCalls = nil }
        case .sideChannel:
            break // memory.used / memory.update / proactive_suggestion: forwarded by the backend, no journal change
        case .failed(let reason, let reconciliation):
            turn.state = reconciliation ? .unknown : .failed; turn.error = reason
            if !reconciliation { turn.pendingApprovals = nil; turn.pendingDeviceCalls = nil }
            if reason == Self.rateLimitedCode { turn.retryAfterSeconds = event.retryAfterSeconds }
            if !reconciliation {
                for i in session.messages.indices where Self.isToolAttempt(session.messages[i], for: request) && !session.messages[i].complete {
                    session.messages[i].complete = true; session.messages[i].failure = reason
                }
            }
        }
        session.turns[index] = turn; try await save(session, expectedRevision: journalRevision, fence: request, observationToken: observationToken)
        // Codex PR #89: only now (authenticated SSE event, journal saved) may the execution gate grant or revoke.
        if case .deviceCall(let call) = event.payload, (turn.pendingDeviceCalls ?? []).contains(where: { $0.callID == call.callID }) {
            ConversationDeviceCall.lifecycle?(.received(call, conversationID: request.conversationID, turnID: request.operationID, token: observationAccounts[observationToken]))
        }
        let deviceCallsGone = deviceCallsBefore.subtracting((turn.pendingDeviceCalls ?? []).map(\.callID))
        if !deviceCallsGone.isEmpty { ConversationDeviceCall.lifecycle?(.revoked(callIDs: deviceCallsGone.sorted())) }
        emit(event.stamped(conversationID: request.conversationID, turnID: request.operationID))
    }
    /// The SSE `turn_failed{cancelled}` and the cancel response are equivalent; turnEvents() sees one stop per turn.
    private func emit(_ event: ConversationTurnEvent) {
        if case .failed(let code, _) = event.payload, code == Self.cancelledCode {
            guard emittedCancellations.insert(event.operationID).inserted else { return }
        }
        for observer in turnObservers.values { observer.yield(event) }
    }
    private static func isToolAttempt(_ message: ConversationTranscriptMessage, for request: ConversationTurnRequest) -> Bool {
        guard message.role == .assistant, message.toolName != nil, let call = message.toolCallID else { return false }
        return message.id == stableID("conversation-call-\(request.operationID)-\(call)")
    }
    private static func isBlankDelegationReply(_ session: ConversationSession, message: Int, request: ConversationTurnRequest) -> Bool {
        let reply = session.messages[message]
        return reply.role == .assistant && reply.toolName == nil && reply.toolCallID == nil && reply.complete && isServerBlank(reply.content) && session.messages.contains(where: { isToolAttempt($0, for: request) && (["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains($0.toolName ?? "") || (request.continuation?.intent == .reviseReport && $0.toolName == (request.revisionWork==nil ? "revise_current_report_v1":ConversationRevisionWorkCodec.toolName))) && $0.complete && $0.failure == nil })
    }
    /// Match the existing server's ECMAScript String.trim(), including BOM but excluding NEL.
    private static func isServerBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
    }
    private func markNotSent(_ request: ConversationTurnRequest, reason: String, observationToken: UUID) async throws {
        var (saved, revision) = try await readVersioned(scope: request.scope, conversationID: request.conversationID)
        guard let i = saved.turns.firstIndex(where: { $0.id == request.operationID }), saved.turns[i].state == .dispatched, saved.turns[i].lastSequence == 0 else { throw ConversationSessionError.invalidEvent }
        let record = try await repository.record(request.conversationID, scope: request.scope)
        guard var core = record.conversation else { throw CatpawError.missing }
        if request.continuation == nil && core.draftText.isEmpty { core.draftText = request.history.last?.content ?? "" }
        saved.turns[i].state = .notSent; saved.turns[i].error = reason
        try await save(saved, expectedRevision: revision, fence: request, observationToken: observationToken, additional: [.update(record.id, record.header.revision, .core(.conversation(core)))])
    }
    public func discardUnsent(scope: DataScope, conversationID: UUID, operationID: UUID) async throws {
        var (saved, revision) = try await readVersioned(scope: scope, conversationID: conversationID)
        guard let i = saved.turns.firstIndex(where: { $0.id == operationID }), saved.turns[i].state == .notSent else { return }
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        saved.turns[i].state = .cancelledBeforeSend
        saved.messages.removeAll { $0.id == stableID("conversation-user-\(operationID)") }
        try await save(saved, expectedRevision: revision)
    }
    /// 「删除」 on a failed turn: the server already ended it (failed / rate_limited, no reply); it leaves the transcript
    /// locally and stops any pending busy retry. Returns true when something was removed.
    @discardableResult
    public func dismissFailed(scope: DataScope, conversationID: UUID, operationID: UUID) async throws -> Bool {
        var (saved, revision) = try await readVersioned(scope: scope, conversationID: conversationID)
        guard let i = saved.turns.firstIndex(where: { $0.id == operationID }), saved.turns[i].state == .failed, saved.turns[i].assistantMessageID == nil else { return false }
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        saved.turns[i].state = .cancelledBeforeSend
        saved.messages.removeAll { $0.id == stableID("conversation-user-\(operationID)") }
        try await save(saved, expectedRevision: revision)
        if busyRetry[conversationID]?.operationID == operationID { busyRetry[conversationID] = nil; await resilience?.clearBusy() }
        try? await outbox?.remove(operationID)
        return true
    }
    /// The queue commits this cancellation together with the replacement intent.
    /// A changed payload gets a new operation ID; an admitted/unknown request is immutable.
    public func cancellationForQueueEdit(scope:DataScope,conversationID:UUID,operationID:UUID) async throws -> Mutation? {
        var (saved,revision)=try await readVersioned(scope:scope,conversationID:conversationID)
        guard let i=saved.turns.firstIndex(where:{$0.id == operationID}) else {return nil}
        guard saved.turns[i].state == .notSent else {throw ConversationSessionError.unresolvedOperation}
        guard active[conversationID] == nil else {throw ConversationSessionError.busy}
        saved.turns[i].state = .cancelledBeforeSend
        saved.messages.removeAll {$0.id == stableID("conversation-user-\(operationID)")}
        return .update(Self.journalID(conversationID),revision,.preference(Preference(key:"conversation_session:\(conversationID)",value:try Self.encode(saved))))
    }
    private func markUnknown(_ request: ConversationTurnRequest, reason: String, observationToken: UUID) async throws {
        var (session, journalRevision) = try await readVersioned(scope: request.scope, conversationID: request.conversationID)
        guard let i = session.turns.firstIndex(where: { $0.id == request.operationID }), ![.completed, .failed].contains(session.turns[i].state) else { return }
        session.turns[i].state = .unknown; session.turns[i].error = reason
        try await save(session, expectedRevision: journalRevision, fence: request, observationToken: observationToken)
    }
    public func observe(scope: DataScope, conversationID: UUID) async throws {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let saved = try await read(scope: scope, conversationID: conversationID)
        guard let turn = saved.unresolved ?? saved.turns.last(where: { ![.notSent, .cancelledBeforeSend].contains($0.state) }) else { return }
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let observationToken = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == observationToken { releaseActive(conversationID) } }
        // R7 §5.3 rebuild: a still-running plain turn first reattaches by GET-after-lastSequence
        // (append only); the authoritative snapshot below then reconciles goals and terminal state.
        observeLog.info("observe start state=\(String(describing: turn.state), privacy: .public) seq=\(turn.lastSequence, privacy: .public)")
        defer { observeLog.info("observe end") }
        if Self.isPlain(turn.request), [.dispatched, .running, .unknown].contains(turn.state) {
            await resilience?.syncing()
            do {
                let stream = try await backend.resumeEvents(turn.request, afterSequence: turn.lastSequence)
                for try await event in stream {
                    observeLog.info("observe event seq=\(event.sequence, privacy: .public) \(String(describing: event.payload).prefix(80), privacy: .public)")
                    guard active[conversationID] == observationToken else { throw CancellationError() }
                    try await apply(event, request: turn.request, observing: true, observationToken: observationToken)
                    let current = try await read(scope: scope, conversationID: conversationID).turns.first(where: { $0.id == turn.id })
                    if let current, [.completed, .failed].contains(current.state) { break }
                    // Same stop rule as pump(): a turn suspended on an approval (device_call / UI decision) keeps the
                    // stream open until the client answers. Waiting for terminal here deadlocked the observer
                    // (busy forever → queue never drains, confirm card never restored).
                    if case .suspended = event.payload, current?.awaitingApproval == true { break }
                }
            } catch is CancellationError { await resilience?.settled(); throw CancellationError() }
            catch { observeLog.info("observe stream error \(String(describing: error).prefix(120), privacy: .public)") /* fall back to the snapshot read below */ }
            await resilience?.settled()
        }
        let observation: ConversationObservation
        do { observation = try await backend.observe(turn.request); observeFailures[turn.id] = nil }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Self-heal: an `unknown` turn the server never shows us (POST failed before admission, 404, persistent
            // read errors) must not block the conversation forever. After ~1 min of failed reads mark it failed
            // (resend allowed); a real server turn that later becomes readable is still reconciled by its id.
            let first = observeFailures[turn.id] ?? Date(); observeFailures[turn.id] = first
            if turn.state == .unknown, Date().timeIntervalSince(first) > Self.unknownTurnGiveUpSeconds, active[conversationID] == observationToken {
                observeLog.error("observe give up on unknown turn after \(Int(Date().timeIntervalSince(first)), privacy: .public)s")
                var (session, revision) = try await readVersioned(scope: scope, conversationID: conversationID)
                if let i = session.turns.firstIndex(where: { $0.id == turn.id }), session.turns[i].state == .unknown {
                    session.turns[i].state = .failed; session.turns[i].error = Self.unknownTurnGaveUp
                    try await save(session, expectedRevision: revision, fence: turn.request, observationToken: observationToken)
                }
                observeFailures[turn.id] = nil
                return
            }
            throw error
        }
        observeLog.info("observe snapshot server=\(observation.serverState ?? "nil", privacy: .public) events=\(observation.events.count, privacy: .public) approvals=\(observation.pendingApprovals.count, privacy: .public)")
        try Task.checkCancellation()
        guard active[conversationID] == observationToken else { throw CancellationError() }
        guard try Self.encode(observation.request) == Self.encode(turn.request) else { throw ConversationSessionError.invalidEvent }
        guard turn.serverRequestHash == nil || observation.requestHash == turn.serverRequestHash, turn.serverGrantEpoch == nil || observation.grantEpoch == turn.serverGrantEpoch else { throw ConversationSessionError.invalidEvent }
        for event in observation.events { guard active[conversationID] == observationToken else { throw CancellationError() }; try await apply(event, request: turn.request, observing: true, observationToken: observationToken) }
        try await restoreApprovals(observation, turnID: turn.id, observationToken: observationToken)
        if try await read(scope:scope,conversationID:conversationID).turns.first(where:{$0.id==turn.id})?.state == .completed {await backend.recordCommittedReply(turn.request)}
        if !observation.goals.isEmpty { var (current, revision) = try await readVersioned(scope: scope, conversationID: conversationID); for goal in observation.goals { try Self.merge(goal, into: &current) }; try await save(current, expectedRevision: revision, fence: turn.request, observationToken: observationToken) }
        try await settleOutcomeUnknown(observation, turnID: turn.id, scope: scope, conversationID: conversationID, request: turn.request, observationToken: observationToken)
    }
    /// v1 17:55: the server parks an interrupted turn as `outcome_unknown` for good (e.g. the 16:28 42501 memory_save turn).
    /// Re-observing it never changes anything, but kept the turn `.unknown` → `unresolved` → model.busy forever: 新对话,
    /// sending and 确认发送许可 disabled, the queue stuck at 「等待当前回复」. After `outcomeUnknownMaxObservations` snapshots
    /// (or `outcomeUnknownGiveUpSeconds`) with no pending approval, resolve it locally as 「结果待核对」: terminal, never
    /// auto-resent (the tool may have run), and the conversation is free again. A later readable completion still applies
    /// through 读取原请求进展, which reconciles by the turn id.
    private func settleOutcomeUnknown(_ observation: ConversationObservation, turnID: UUID, scope: DataScope, conversationID: UUID, request: ConversationTurnRequest, observationToken: UUID) async throws {
        guard observation.serverState == Self.serverOutcomeUnknown, observation.pendingApprovals.isEmpty, observation.pendingUIApprovals.isEmpty else { outcomeUnknownSeen[turnID] = nil; return }
        var (session, revision) = try await readVersioned(scope: scope, conversationID: conversationID)
        guard let i = session.turns.firstIndex(where: { $0.id == turnID }), [.dispatched, .running, .unknown].contains(session.turns[i].state), !session.turns[i].awaitingApproval else { outcomeUnknownSeen[turnID] = nil; return }
        let seen = outcomeUnknownSeen[turnID] ?? (0, Date()); let count = seen.count + 1
        guard count >= Self.outcomeUnknownMaxObservations || Date().timeIntervalSince(seen.first) >= Self.outcomeUnknownGiveUpSeconds else { outcomeUnknownSeen[turnID] = (count, seen.first); return }
        guard active[conversationID] == observationToken else { throw CancellationError() }
        observeLog.info("observe settle outcome_unknown after \(count, privacy: .public) snapshots")
        session.turns[i].state = .failed; session.turns[i].error = Self.outcomeUnverified
        try await save(session, expectedRevision: revision, fence: request, observationToken: observationToken)
        outcomeUnknownSeen[turnID] = nil
    }
    static let serverOutcomeUnknown = "outcome_unknown"
    /// Turn error code for a turn resolved as 「结果待核对」 (UI: bubbleStatus .unverified, no one-tap resend).
    static let outcomeUnverified = "outcome_unverified"
    static let outcomeUnknownMaxObservations = 3
    static let outcomeUnknownGiveUpSeconds: TimeInterval = 30
    private var outcomeUnknownSeen: [UUID: (count: Int, first: Date)] = [:]
    static let rateLimitedCode = "rate_limited"
    static let unknownTurnGiveUpSeconds: TimeInterval = 60
    static let unknownTurnGaveUp = "这条消息没能确认送达，已停止等待。可以重新发送。"
    private var observeFailures: [UUID: Date] = [:]
    static let cancelledCode = "cancelled"
    static let waitingForNetwork = "等待网络 · 联网后自动发送"
    private static func isPlain(_ r: ConversationTurnRequest) -> Bool { r.continuation == nil && r.acceptedWork == nil && r.revisionWork == nil && r.image == nil }

    /// "继续获取": read-only reattach to the original turn (never a resend). Same as observe.
    public func continueFetching(scope: DataScope, conversationID: UUID) async throws { try await observe(scope: scope, conversationID: conversationID) }

    /// Seconds until the automatic busy retry, nil when no busy turn is pending.
    public func busyRetryIn(conversationID: UUID) -> Int? {
        guard let entry = busyRetry[conversationID], !entry.autoRetried else { return nil }
        return max(0, Int(entry.due.timeIntervalSinceNow.rounded(.up)))
    }
    /// UI state for the busy card: "模型繁忙，正在重试（n/3）" while automatic retries remain, then a friendly
    /// error with the manual "现在重试" entry (retryBusy automatic:false).
    public func busyRetryStatus(conversationID: UUID) -> ConversationBusyRetryStatus? {
        guard let entry = busyRetry[conversationID] else { return nil }
        let spent = autoRetryCounts[entry.operationID] ?? 0
        return ConversationBusyRetryStatus(attempt: min(spent + 1, Self.maxAutomaticBusyRetries), maxAttempts: Self.maxAutomaticBusyRetries,
                                           secondsRemaining: max(0, Int(entry.due.timeIntervalSinceNow.rounded(.up))), automatic: !entry.autoRetried)
    }
    /// User cancel: stop automatic retries for the pending busy turn (manual retry stays available).
    public func cancelBusyRetry(conversationID: UUID) {
        guard var entry = busyRetry[conversationID] else { return }
        busyRetryCancelled.insert(entry.operationID); entry.autoRetried = true; busyRetry[conversationID] = entry
        sendDiagnostic("catpaw.send busy retry cancelled op=\(entry.operationID.uuidString.prefix(8))")
    }
    /// "现在重试" / "换一个免费模型": only for a turn the server reported as `failed{rate_limited}`
    /// before any assistant output. That original turn is terminal, so this is a new turn with the
    /// same text, never a resend of an accepted POST. `route` sets the DEBUG developer route first.
    @discardableResult
    public func retryBusy(scope: DataScope, conversationID: UUID, route: String? = nil, automatic: Bool = false) async throws -> UUID? {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        guard let entry = busyRetry[conversationID] else { return nil }
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        busyRetry[conversationID] = nil
        let saved = try await read(scope: scope, conversationID: conversationID)
        // Same operationID, same user message: no new transcript row; the server restarts the failed turn.
        guard let original = saved.turns.first(where: { $0.id == entry.operationID }), saved.turns.last?.id == original.id,
              original.state == .failed, original.error == Self.rateLimitedCode,
              original.assistantMessageID == nil, Self.isPlain(original.request) else { await resilience?.clearBusy(); return nil }   // never leave the card at 0 s
        if let route { ModelRouteSelection.select(route: route) }
        if automatic { autoRetryCounts[original.id, default: 0] += 1 } else { busyRetryCancelled.remove(original.id) }
        await resilience?.clearBusy()
        let observationToken = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == observationToken { releaseActive(conversationID) } }
        do {
            let stream = try await backend.retryBusyTurn(original.request, afterSequence: original.lastSequence)
            return try await pump(stream, request: original.request, observationToken: observationToken)
        } catch {
            // markUnknown leaves a still-failed (never restarted) turn untouched.
            if active[conversationID] == observationToken, !(error is CancellationError) {
                try? await markUnknown(original.request, reason: "连接中断，可以继续获取原回复。", observationToken: observationToken)
            }
            throw error
        }
    }
    /// Live turn events (after they are journaled) for AnswerPhaseProjection; covers send, busy retry and outbox drain.
    public func turnEvents() -> AsyncStream<ConversationTurnEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ConversationTurnEvent.self, bufferingPolicy: .bufferingNewest(256))
        turnObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeTurnObserver(id) } }
        return stream
    }
    private func removeTurnObserver(_ id: UUID) { turnObservers.removeValue(forKey: id) }
    /// Re-sends parked offline turns with their original operationID once the path is usable.
    /// Returns the number of entries resolved (sent or no longer sendable).
    @discardableResult
    public func drainOutbox(conversationID: UUID? = nil) async -> Int {
        guard let outbox, await resilience?.isPathSatisfied() ?? true else { return 0 }
        var resolved = 0
        let pending: [ConversationOutboxEntry]
        if let conversationID { pending = await outbox.entries(conversationID: conversationID) } else { pending = await outbox.entries() }
        for entry in pending {
            guard active[entry.conversationID] == nil else { continue }
            try? await outbox.recordAttempt(entry.id)
            do {
                _ = try await send(scope: entry.scope, conversationID: entry.conversationID, text: entry.text, operationID: entry.id, preserveDraft: true)
                try? await clearDraft(scope: entry.scope, conversationID: entry.conversationID, ifEqual: entry.text)
                try? await outbox.remove(entry.id); resolved += 1
            } catch is ConversationDispatchFailure {
                // still not sent (e.g. offline again): keep the entry
            } catch ConversationSessionError.busy {
                continue
            } catch {
                // Admitted-but-failed, conflict or discarded: the outbox no longer owns this message.
                let state = (try? await read(scope: entry.scope, conversationID: entry.conversationID))?.turns.first(where: { $0.id == entry.id })?.state
                if state != .notSent { try? await outbox.remove(entry.id); resolved += 1 }
            }
        }
        await resilience?.outboxChanged(pending: await outbox.entries().map(\.id))
        return resolved
    }
    /// Called by the foreground loop: due busy auto-retry (once) and outbox drain. Returns true when state changed.
    public func foregroundTick(scope: DataScope, conversationID: UUID) async -> Bool {
        var changed = false
        if let entry = busyRetry[conversationID], !entry.autoRetried, Date() >= entry.due, active[conversationID] == nil, await resilience?.isPathSatisfied() ?? true {
            _ = try? await retryBusy(scope: scope, conversationID: conversationID, automatic: true); changed = true
        }
        if await drainOutbox(conversationID: conversationID) > 0 { changed = true }
        return changed
    }
    private func clearDraft(scope: DataScope, conversationID: UUID, ifEqual text: String) async throws {
        let record = try await repository.record(conversationID, scope: scope)
        guard var core = record.conversation, core.draftText == text else { return }
        core.draftText = ""
        try await repository.commit(scope: scope, mutations: [.update(record.id, record.header.revision, .core(.conversation(core)))])
    }
    private static func merge(_ goal: ConversationGoalProjection, into session: inout ConversationSession,revisionWorkReceipt:ConversationRevisionWorkReceipt?=nil) throws {
        guard !goal.id.isEmpty, goal.revision > 0, goal.revision >= (session.goals[goal.id]?.revision ?? 0) else { throw ConversationSessionError.invalidEvent }
        let previousGoal=session.goals[goal.id]
        let newRevisionAuthority:Bool
        if let receipt=revisionWorkReceipt {
            guard goal.id==receipt.revision.task_id,goal.binding?.run_id.uuidString.lowercased()==receipt.revision.run_id,previousGoal?.revisionRequiresNewWork==true,goal.revisionRequiresNewWork==true,goal.sourceAuthorizationCurrent==true,receipt.revision.permitsCurrentPlan(goal.planReference) else {throw ConversationSessionError.invalidEvent}
            newRevisionAuthority=true
        } else {newRevisionAuthority=false}
        guard previousGoal?.binding == nil || previousGoal?.binding == goal.binding,
              goal.sourceAuthorizationCurrent != false || (goal.artifacts.isEmpty && [.unknown,.cancelled].contains(goal.state)) else {throw ConversationSessionError.invalidEvent}
        if let plan=goal.planReference {try plan.validate()}
        if let priorPlan=previousGoal?.planReference,let incoming=goal.planReference {
            guard priorPlan.revision != incoming.revision || priorPlan.planHash==incoming.planHash else {throw ConversationSessionError.invalidEvent}
            if incoming.revision<priorPlan.revision {session.goals[goal.id]=previousGoal;return}
        }
        var next = goal; if next.revisionRequiresNewWork==nil {next.revisionRequiresNewWork=previousGoal?.revisionRequiresNewWork};var history = previousGoal?.artifactHistory ?? []
        for artifact in (previousGoal?.artifacts ?? [])+goal.artifacts {
            guard artifact.version > 0, textHash(artifact.body) == artifact.contentHash else { throw ConversationSessionError.invalidEvent }
            if let previous = history.first(where: { $0.id == artifact.id && $0.version == artifact.version }) { guard previous.contentHash == artifact.contentHash, previous.body == artifact.body else { throw ConversationSessionError.invalidEvent } }
            else { history.append(artifact) }
        }
        // Source invalidation is irreversible for this frozen binding. A late snapshot,
        // including a previously unseen version, cannot restore its display/completion.
        let legacyHidden=previousGoal?.sourceAuthorizationCurrent == nil && previousGoal?.state == .unknown && previousGoal?.artifacts.isEmpty == true && !(previousGoal?.artifactHistory.isEmpty ?? true)
        if let previousGoal,!newRevisionAuthority && (previousGoal.sourceAuthorizationCurrent == false || legacyHidden) {
            let cancellationConfirmed = previousGoal.state == .cancelled || (goal.sourceAuthorizationCurrent == false && goal.state == .cancelled)
            var hidden=ConversationGoalProjection(id:previousGoal.id,revision:previousGoal.revision,title:previousGoal.title,state:cancellationConfirmed ? .cancelled:.unknown,summary:cancellationConfirmed ? "工作已取消；已发出的操作仍需核对。":previousGoal.summary,updatedAt:previousGoal.updatedAt)
            hidden.binding=previousGoal.binding;hidden.planReference=previousGoal.planReference;hidden.artifactHistory=previousGoal.artifactHistory;hidden.sourceAuthorizationCurrent=false;hidden.revisionRequiresNewWork=previousGoal.revisionRequiresNewWork;hidden.revisionWorkPolicy=previousGoal.revisionWorkPolicy
            session.goals[goal.id]=hidden;return
        }
        // Preserve the whole current projection when an older head arrives, including
        // after a temporary empty working projection. History is never promoted to a head.
        if let previousGoal,goal.artifacts.contains(where:{incoming in history.contains{$0.id==incoming.id && $0.version>incoming.version}}) {
            session.goals[goal.id]=previousGoal;return
        }
        next.artifactHistory = history; session.goals[goal.id] = next
    }
    public func stopObserving(scope: DataScope, conversationID: UUID) async throws {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        let stopToken = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == stopToken { releaseActive(conversationID) } }
        if let turn = try await read(scope: scope, conversationID: conversationID).unresolved { try await markUnknown(turn.request, reason: "已停止本机观察，未取消后台任务。读取原请求后继续。", observationToken:stopToken) }
    }
    /// R2 stop of the current server turn: `POST …/turns/{id}/cancel` (`{}`, idempotent).
    /// Takes over the conversation's observation fence first, so the live pump stops (no SSE reconnect,
    /// no busy auto-retry, no outbox resend). Then reads the authoritative turn back and applies the
    /// remaining events through the normal journal path. turnEvents() receives the stop as ONE
    /// `.failed(message: "cancelled", reconciliationRequired: false)`, whichever of stream/response wins;
    /// a cancel that raced completion yields `.completed` instead. Already-shown text is kept.
    /// The next send is an ordinary new turn; the backend re-reads the conversation's revision and
    /// grant_epoch (GET …/conversations/{c}) before every POST.
    @discardableResult
    public func cancelCurrentTurn(scope: DataScope, conversationID: UUID) async throws -> ConversationTurnCancelOutcome {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        cancelBusyRetry(conversationID: conversationID)
        guard !cancelling.contains(conversationID) else { throw ConversationSessionError.busy }
        guard let target = try await read(scope: scope, conversationID: conversationID).unresolved else { return .noActiveTurn }
        cancelling.insert(conversationID)
        let token = claimObservation(conversationID, source: sourceToken)
        defer {
            cancelling.remove(conversationID); scheduleUIDrain(conversationID)
            if active[conversationID] == token { releaseActive(conversationID) }
        }
        let operationID = target.id
        // Codex p89d-3: a whole-turn stop revokes this turn's device calls synchronously, BEFORE awaiting the cancel POST,
        // its retries and the read-back.
        let stopping = (target.pendingDeviceCalls ?? []).map(\.callID)
        if !stopping.isEmpty { ConversationDeviceCall.lifecycle?(.revoked(callIDs: stopping.sorted())) }
        // A user stop is never resent automatically.
        if busyRetry[conversationID]?.operationID == operationID { busyRetry[conversationID] = nil; await resilience?.clearBusy() }
        autoRetryCounts.removeValue(forKey: operationID); busyRetryCancelled.remove(operationID)
        if let outbox { try? await outbox.remove(operationID); await resilience?.outboxChanged(pending: await outbox.entries().map(\.id)) }
        await resilience?.settled()

        var receipt: ConversationTurnCancelReceipt?
        var attempt = 0
        while receipt == nil {
            try Task.checkCancellation()
            do { receipt = try await backend.cancelTurn(target.request) }
            catch let failure as ConversationTurnCancelFailure {
                // 404 can mean the POST is still in flight; transport errors leave the cancel unknown. Both may resend.
                let retryable = failure == .transport || (failure == .notFound && target.lastSequence == 0)
                guard retryable, attempt < Self.cancelRetryDelays.count else { break }
                try await Task.sleep(nanoseconds: UInt64(Self.cancelRetryDelays[attempt] * 1_000_000_000)); attempt += 1
                guard active[conversationID] == token else { throw CancellationError() }
            }
        }
        guard active[conversationID] == token else { throw CancellationError() }
        // Authoritative read-back (GET …/turns/{id}) also completes a turn that won the race.
        let reconciled = (try? await reconcileAfterCancel(target, token: token)) ?? false
        let current = try await read(scope: scope, conversationID: conversationID).turns.first(where: { $0.id == operationID })
        if reconciled, let current {
            switch current.state {
            case .completed: return .completed(operationID: operationID)
            case .failed where current.error == Self.cancelledCode: return .cancelled(operationID: operationID)
            case .failed: return .alreadyTerminal(operationID: operationID, state: receipt?.state ?? "failed")
            default: break
            }
        }
        // Read-back failed. A confirmed cancel is still reported once, but the journal stays `unknown`
        // (sequence unchanged) so observe/continueFetching later appends the server's events.
        // Codex p89b-3: the stop was requested/confirmed, so this turn's device calls lose execution rights NOW, even though
        // the journal stays `unknown` (markUnknown keeps pendingDeviceCalls for display). Stale cards cannot run.
        let staleCalls = Set((target.pendingDeviceCalls ?? []).map(\.callID)).union((current?.pendingDeviceCalls ?? []).map(\.callID))
        if !staleCalls.isEmpty { ConversationDeviceCall.lifecycle?(.revoked(callIDs: staleCalls.sorted())) }
        try await markUnknown(target.request, reason: "已请求停止，结果待核对；读取原请求后继续。", observationToken: token)
        if let receipt, receipt.cancelled, receipt.state == "failed" {
            emit(ConversationTurnEvent(operationID: operationID, epoch: target.request.epoch, sequence: current?.lastSequence ?? target.lastSequence, payload: .failed(message: Self.cancelledCode, reconciliationRequired: false), conversationID: target.request.conversationID, turnID: operationID))
        }
        return .reconciling(operationID: operationID)
    }
    static let cancelRetryDelays: [Double] = [0.5, 1, 2]
    /// Same read-back as `observe`, under the cancel fence. Returns true once the turn is terminal.
    private func reconcileAfterCancel(_ target: ConversationTurnRecord, token: UUID) async throws -> Bool {
        let scope = target.request.scope, conversationID = target.request.conversationID
        let observation = try await backend.observe(target.request)
        guard active[conversationID] == token else { throw CancellationError() }
        guard try Self.encode(observation.request) == Self.encode(target.request) else { throw ConversationSessionError.invalidEvent }
        guard let turn = try await read(scope: scope, conversationID: conversationID).turns.first(where: { $0.id == target.id }) else { throw CatpawError.missing }
        guard turn.serverRequestHash == nil || observation.requestHash == turn.serverRequestHash, turn.serverGrantEpoch == nil || observation.grantEpoch == turn.serverGrantEpoch else { throw ConversationSessionError.invalidEvent }
        for event in observation.events { try await apply(event, request: target.request, observing: true, observationToken: token) }
        try await restoreApprovals(observation, turnID: target.id, observationToken: token)
        if !observation.goals.isEmpty { var (current, revision) = try await readVersioned(scope: scope, conversationID: conversationID); for goal in observation.goals { try Self.merge(goal, into: &current) }; try await save(current, expectedRevision: revision, fence: target.request, observationToken: token) }
        let state = try await read(scope: scope, conversationID: conversationID).turns.first(where: { $0.id == target.id })?.state
        if state == .completed { await backend.recordCommittedReply(target.request) }
        return state == .completed || state == .failed
    }
    // MARK: catpaw.approval.v1 (services/edge/docs/approval-contract.md)
    /// Single source with the transport (includes catpaw.device.v1 tools). A drifted local copy here rejected
    /// `reminder_create` tool_started as invalidEvent → turn stuck `unknown`, observer looped, queue never drained.
    static var approvalToolNames: Set<String> { NativeChatHTTPBackend.approvalToolNames }
    /// Cold start / observe: the snapshot's `pending_approvals` is authoritative for a turn the server reports `awaiting_approval`.
    private func restoreApprovals(_ observation: ConversationObservation, turnID: UUID, observationToken: UUID) async throws {
        let request = observation.request
        var (session, revision) = try await readVersioned(scope: request.scope, conversationID: request.conversationID)
        guard let i = session.turns.firstIndex(where: { $0.id == turnID }) else { return }
        var turn = session.turns[i]
        // Device calls (catpaw.device.v1) live in the journal (pendingDeviceCalls); the snapshot only confirms the turn is
        // still suspended on them. Revive an `unknown` turn so its confirm card renders instead of an endless re-observe.
        var deviceRevived = false
        // P1-4: merge server interaction_outcomes for this turn's calls (authoritative final card state).
        let logged = Set((turn.deviceCallLog ?? []).map(\.callID))
        let outcomes = observation.interactionOutcomes.filter { logged.contains($0.key) }
        let outcomesChanged = !outcomes.isEmpty && (turn.serverOutcomes ?? [:]).merging(outcomes) { _, new in new } != (turn.serverOutcomes ?? [:])
        if outcomesChanged { turn.serverOutcomes = (turn.serverOutcomes ?? [:]).merging(outcomes) { _, new in new } }
        if observation.serverState == "awaiting_approval", !(turn.pendingDeviceCalls ?? []).isEmpty, [.unknown, .dispatched].contains(turn.state) {
            turn.state = .running; turn.error = nil; deviceRevived = true
        }
        let uiChanged: Bool
        if observation.serverState == "awaiting_approval", !observation.pendingUIApprovals.isEmpty, [.running, .unknown, .dispatched].contains(turn.state) {
            uiChanged = turn.pendingUIApprovals != observation.pendingUIApprovals
            if [.unknown, .dispatched].contains(turn.state) { turn.state = .running; turn.error = nil }
            turn.pendingUIApprovals = observation.pendingUIApprovals
        } else if turn.pendingUIApprovals != nil, observation.serverState != nil {
            uiChanged = true; turn.pendingUIApprovals = nil
        } else { uiChanged = false }
        if observation.serverState == "awaiting_approval", !observation.pendingApprovals.isEmpty {
            guard [.running, .unknown, .dispatched].contains(turn.state) else {
                if outcomesChanged { session.turns[i] = turn; try await save(session, expectedRevision: revision, fence: request, observationToken: observationToken) }
                return
            }
            for approval in observation.pendingApprovals {
                let row = stableID("conversation-call-\(request.operationID)-\(approval.callID)")
                guard session.messages.contains(where: { $0.id == row && $0.toolName == approval.tool }) else { throw ConversationSessionError.invalidEvent }
            }
            turn.state = .running; turn.error = nil; turn.pendingApprovals = observation.pendingApprovals
        } else if turn.pendingApprovals != nil, observation.serverState != nil, observation.serverState != "awaiting_approval" {
            turn.pendingApprovals = nil
        } else if !uiChanged && !deviceRevived && !outcomesChanged { return }
        session.turns[i] = turn
        try await save(session, expectedRevision: revision, fence: request, observationToken: observationToken)
    }
    /// Pending approvals of this conversation's current turn (journal; restored from the snapshot by observe()).
    public func pendingApprovals(scope: DataScope, conversationID: UUID) async throws -> [ConversationApprovalRequest] {
        try await read(scope: scope, conversationID: conversationID).turns.last(where: { $0.awaitingApproval })?.pendingApprovals ?? []
    }
    /// Decide one pending approval and continue the SAME turn: events after the journal's lastSequence
    /// (`approval_resolved`, then `tool_result{status}`, text, `turn_completed` — or another `approval_requested`
    /// + `turn_suspended`) go through the normal apply → journal → turnEvents() path.
    /// `operationID` makes the decision idempotent: after a thrown `.transport`, resend with the SAME id.
    /// `.expired`/`.consumed` refresh the journal from the snapshot before rethrowing.
    @discardableResult
    public func submitApproval(scope: DataScope, conversationID: UUID, interruptID: String, decision: ConversationApprovalDecision, operationID: UUID = UUID()) async throws -> UUID {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        guard active[conversationID] == nil, !cancelling.contains(conversationID) else { throw ConversationSessionError.busy }
        let saved = try await read(scope: scope, conversationID: conversationID)
        guard let turn = saved.turns.last(where: { $0.awaitingApproval }), let approval = turn.pendingApprovals?.first(where: { $0.interruptID == interruptID }) else { throw ConversationApprovalFailure.noPendingApproval }
        guard decision != .approveAlways || approval.rememberAllowed else { throw ConversationApprovalFailure.rejected(status: 422, code: "approval_remember_not_allowed") }
        let token = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == token { releaseActive(conversationID) } }
        let stream: AsyncThrowingStream<ConversationTurnEvent, Error>
        do { stream = try await backend.submitApproval(turn.request, interruptID: interruptID, decision: decision, argsHash: approval.argsHash, operationID: operationID, afterSequence: turn.lastSequence) }
        catch let failure as ConversationApprovalFailure {
            if [.expired, .consumed, .stale, .notFound].contains(failure), active[conversationID] == token {
                if let observation = try? await backend.observe(turn.request), active[conversationID] == token, (try? Self.encode(observation.request)) == (try? Self.encode(turn.request)) {
                    for event in observation.events { try? await apply(event, request: turn.request, observing: true, observationToken: token) }
                    try? await restoreApprovals(observation, turnID: turn.id, observationToken: token)
                }
            }
            throw failure
        }
        do { return try await pump(stream, request: turn.request, observationToken: token) }
        catch {
            if active[conversationID] == token, !(error is CancellationError) { try? await markUnknown(turn.request, reason: "确认已提交，结果待核对；读取原请求后继续。", observationToken: token) }
            throw error
        }
    }
    /// Waiting catpaw.ui.v1 blocks of this conversation's current turn (journal).
    public func pendingUIBlocks(scope: DataScope, conversationID: UUID) async throws -> [ConversationUIEvent] {
        try await read(scope: scope, conversationID: conversationID).turns.last(where: { $0.awaitingApproval })?.pendingUIBlocks ?? []
    }
    private func releaseActive(_ conversationID: UUID) { if let t = active.removeValue(forKey: conversationID) { observationAccounts[t] = nil }; scheduleUIDrain(conversationID) }
    /// Codex p89c-4: the AccountEpoch token of the account that OPENED this observation (stream / read-back / submit).
    /// Device-call lifecycle events carry it from the source, so an event of A's stream that is applied late (after
    /// sign-out / switch to B) can never be granted under B's generation.
    private var observationAccounts: [UUID: AccountToken] = [:]
    /// p89e-1: the source identity of an operation = the service principal's account AND its login generation, captured
    /// synchronously at the operation's entry (before any await). A same-account sign-out → sign-in bumps the generation,
    /// so an operation that started under the old login can never be attached to the new one.
    nonisolated(unsafe) static var beforeClaimHook: (() -> Void)?
    /// p89h-1: services built with a principal (every signed-in production chat) are account-bound: nil / stale source is
    /// refused. Only unbound services (offline trial, fixtures — no principal) may run without a source.
    nonisolated private var bindsAccount: Bool { principal != nil || principalAccount != nil }
    static let missingSource = ConversationApprovalFailure.rejected(status: 401, code: "login_source_invalid")
    nonisolated private func pinnedSource() -> AccountToken? {
        if let principal { return principal }
        guard let current = AccountEpoch.shared.capture(), principalAccount == nil || current.account == principalAccount else { return nil }
        return current
    }
    private func claimObservation(_ conversationID: UUID, source: AccountToken?) -> UUID {
        let token = UUID(); active[conversationID] = token
        Self.beforeClaimHook?()   // test seam: "the operation's first await" (sign-out / re-login lands here)
        if let source, AccountEpoch.shared.isValid(source) { observationAccounts[token] = source }   // stale login → no grants
        return token
    }
    private func scheduleUIDrain(_ conversationID: UUID) {
        guard !(uiQueue[conversationID] ?? []).isEmpty else { return }
        Task { await self.drainUIQueue(conversationID) }
    }
    /// Queued decisions currently waiting (interrupt ids, in submission order).
    public func queuedUIDecisions(conversationID: UUID) -> [String] { (uiQueue[conversationID] ?? []).map(\.interruptID) }
    /// Cancels a queued (not yet sent) decision; its callers get `CancellationError`. Returns false when nothing was queued.
    @discardableResult
    public func cancelQueuedUIDecision(conversationID: UUID, interruptID: String) -> Bool {
        guard let index = uiQueue[conversationID]?.firstIndex(where: { $0.interruptID == interruptID.lowercased() }) else { return false }
        let entry = uiQueue[conversationID]!.remove(at: index)
        entry.finish(.failure(CancellationError()))
        return true
    }
    private func cancelWaiter(_ entryID: UUID, conversationID: UUID) {
        guard let index = uiQueue[conversationID]?.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = uiQueue[conversationID]!.remove(at: index)
        entry.finish(.failure(CancellationError()))
    }
    private static func uiDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
    private func drainUIQueue(_ conversationID: UUID) async {
        guard uiDraining.insert(conversationID).inserted else { return }
        defer { uiDraining.remove(conversationID) }
        while active[conversationID] == nil, !cancelling.contains(conversationID), let entry = uiQueue[conversationID]?.first {
            uiQueue[conversationID]?.removeFirst()
            if uiQueue[conversationID]?.isEmpty == true { uiQueue[conversationID] = nil }
            var result: Result<UUID, Error>
            do {
                // p89g-1: never re-capture at dequeue — a decision queued under an old login dies here, before any backend call.
                if bindsAccount ? !AccountEpoch.shared.isValid(entry.source) : (entry.source.map { !AccountEpoch.shared.isValid($0) } ?? false) { throw CancellationError() }
                let id = try await performUIDecision(scope: entry.scope, conversationID: conversationID, turnID: entry.turnID, interruptID: entry.interruptID, decision: entry.decision, argsHash: entry.argsHash, response: entry.response, operationID: entry.operationID, source: entry.source)
                result = .success(id)
            } catch { result = .failure(error) }
            entry.finish(result)
        }
    }
    /// Waiting ui blocks for cold-start restore: the snapshot's `pending_approvals` kind "ui" when known (observe),
    /// else the journal's unresolved `ui.block`s; de-duplicated by interrupt id. Empty when the turn is not waiting.
    public func pendingUIApprovals(scope: DataScope, conversationID: UUID) async throws -> [ConversationUIApproval] {
        guard let turn = try await read(scope: scope, conversationID: conversationID).turns.last(where: { $0.awaitingApproval }) else { return [] }
        return Self.uiApprovals(turn)
    }
    static func uiApprovals(_ turn: ConversationTurnRecord) -> [ConversationUIApproval] {
        let resolved = Set((turn.uiEvents ?? []).filter { $0.type == .resolve }.map(\.id))
        var out = (turn.pendingUIApprovals ?? []).filter { !resolved.contains($0.blockID) }
        for block in turn.pendingUIBlocks { if let value = ConversationUIApproval(block), !out.contains(where: { $0.interruptID == value.interruptID }) { out.append(value) } }
        return out
    }
    /// catpaw.ui.v1 answer for a waiting block; reuses the approval.v1 decision route and the after_sequence SSE resume.
    /// `response` is the raw `ui.response` (submit) / `ui.error` (report_error) JSON; nil for dismiss.
    /// Idempotent on `operationID`: after `.transport`, resend with the SAME id. Errors are `ConversationApprovalFailure`
    /// (see `friendlyMessage`); `.expired`/`.consumed`/`.stale`/`.notFound` refresh the journal before rethrowing.
    /// While a stream is running (send, approval or another decision) the decision is QUEUED, not refused: it is sent
    /// in submission order once the stream ends (a turn_suspended ends it). Queued decisions can be cancelled
    /// (`cancelQueuedUIDecision` or cancelling the calling Task → `CancellationError`); one past its block's `expiresAt`
    /// fails with `.expired`; a second submit for an interrupt already queued joins it when identical
    /// (same decision, argsHash, response) and is `.rejected(409, "approval_operation_conflict")` otherwise.
    /// Blocks may be answered in any order.
    @discardableResult
    public func submitUIDecision(scope: DataScope, conversationID: UUID, turnID: UUID, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID = UUID()) async throws -> UUID {
        let sourceToken = pinnedSource()   // p89g-1: pinned at the public entry, before the first await, and queued with the decision
        // p89h-1: an account-bound (production) service never queues or submits a decision without a valid login source.
        if bindsAccount, !AccountEpoch.shared.isValid(sourceToken) { throw Self.missingSource }
        let key = interruptID.lowercased()
        let idle = active[conversationID] == nil && !cancelling.contains(conversationID) && (uiQueue[conversationID] ?? []).isEmpty
        if idle { return try await performUIDecision(scope: scope, conversationID: conversationID, turnID: turnID, interruptID: key, decision: decision, argsHash: argsHash, response: response, operationID: operationID, source: sourceToken) }
        let entry: QueuedUIDecision
        if let queued = uiQueue[conversationID]?.first(where: { $0.interruptID == key }) {
            guard queued.source == sourceToken, queued.turnID == turnID, queued.decision == decision, queued.argsHash == argsHash, queued.response == response else { throw ConversationApprovalFailure.rejected(status: 409, code: "approval_operation_conflict") }
            entry = queued
        } else {
            entry = QueuedUIDecision(scope: scope, conversationID: conversationID, turnID: turnID, interruptID: key, decision: decision, argsHash: argsHash, response: response, operationID: operationID, source: sourceToken)
            uiQueue[conversationID, default: []].append(entry)
        }
        let entryID = entry.id
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                entry.waiters.append(continuation)
                scheduleUIDrain(conversationID)
            }
        } onCancel: {
            Task { await self.cancelWaiter(entryID, conversationID: conversationID) }
        }
        return result
    }
    private func performUIDecision(scope: DataScope, conversationID: UUID, turnID: UUID, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, source sourceToken: AccountToken?) async throws -> UUID {
        // p89g-1: the source comes from the caller (public entry or queue entry), never from "current" here.
        guard active[conversationID] == nil, !cancelling.contains(conversationID) else { throw ConversationSessionError.busy }
        let saved = try await read(scope: scope, conversationID: conversationID)
        if bindsAccount ? !AccountEpoch.shared.isValid(sourceToken) : (sourceToken.map { !AccountEpoch.shared.isValid($0) } ?? false) { throw CancellationError() }
        guard let turn = saved.turns.first(where: { $0.id == turnID }), turn.awaitingApproval,
              let block = Self.uiApprovals(turn).first(where: { $0.interruptID == interruptID.lowercased() }) else { throw ConversationApprovalFailure.noPendingApproval }
        guard block.argsHash == argsHash else { throw ConversationApprovalFailure.stale }
        // Past the block's deadline (e.g. it waited in the queue): the server would answer approval_expired.
        if let deadline = Self.uiDate(block.expiresAt), deadline <= uiClock() { throw ConversationApprovalFailure.expired }
        if decision == .dismiss { guard response == nil else { throw ConversationApprovalFailure.rejected(status: 422, code: "ui_response_invalid") } }
        else { guard response != nil else { throw ConversationApprovalFailure.rejected(status: 422, code: "ui_response_invalid") } }
        let token = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == token { releaseActive(conversationID) } }
        let stream: AsyncThrowingStream<ConversationTurnEvent, Error>
        do { stream = try await backend.submitUIDecision(turn.request, interruptID: interruptID.lowercased(), decision: decision, argsHash: argsHash, response: response, operationID: operationID, afterSequence: turn.lastSequence) }
        catch let failure as ConversationApprovalFailure {
            if [.expired, .consumed, .stale, .notFound].contains(failure), active[conversationID] == token {
                if let observation = try? await backend.observe(turn.request), active[conversationID] == token, (try? Self.encode(observation.request)) == (try? Self.encode(turn.request)) {
                    for event in observation.events { try? await apply(event, request: turn.request, observing: true, observationToken: token) }
                }
            }
            throw failure
        }
        do { return try await pump(stream, request: turn.request, observationToken: token) }
        catch {
            if active[conversationID] == token, !(error is CancellationError) { try? await markUnknown(turn.request, reason: "回答已提交，结果待核对；读取原请求后继续。", observationToken: token) }
            throw error
        }
    }
    /// catpaw.device.v1: report the phone's result for a `device_call`. Looks the call up by `callID` (#44 `DeviceCallResult` has only
    /// call_id/status/data); idempotent: the operation id is derived from the call id, so a retry after `.transport` replays.
    /// Errors are `ConversationApprovalFailure` (`.expired` past `ttl_sec`, `.stale`, `.consumed`, `.notFound`) or `.busy` while a stream runs.
    @discardableResult
    public func submitDeviceResult(scope: DataScope, callID: String, status: String, data: Data?) async throws -> UUID {
        let sourceToken = pinnedSource()   // p89e-1: account AND login generation, pinned before the first await
        // P1-4: after a restart / supersede the in-memory index may be gone; the persisted index still knows the turn.
        guard let entry = deviceCallIndex[callID] ?? DeviceCallTurnIndex.load(.standard).turn(for: callID) else { throw ConversationApprovalFailure.noPendingApproval }
        let (conversationID, turnID) = entry
        // A read-only observer may briefly hold the conversation; give it a moment instead of failing the user's tap.
        for _ in 0..<20 where active[conversationID] != nil { try await Task.sleep(nanoseconds: 250_000_000) }
        guard active[conversationID] == nil, !cancelling.contains(conversationID) else { observeLog.error("device result busy"); throw ConversationSessionError.busy }
        let saved = try await read(scope: scope, conversationID: conversationID)
        guard let turn = saved.turns.first(where: { $0.id == turnID }) else { throw ConversationApprovalFailure.noPendingApproval }
        // P1-4: a call that is no longer pending (superseded by the next message, or past its TTL) is still reported —
        // the server records it (200 + X-Catpaw-Device-Late) so the card and the next turn know it really happened.
        let pendingCall = turn.pendingDeviceCalls?.first(where: { $0.callID == callID })
        guard let call = pendingCall ?? turn.deviceCallLog?.first(where: { $0.callID == callID }) else { throw ConversationApprovalFailure.noPendingApproval }
        let operationID = stableID("device-result-\(turnID)-\(callID)")
        let token = claimObservation(conversationID, source: sourceToken)
        defer { if active[conversationID] == token { releaseActive(conversationID) } }
        if pendingCall == nil { return try await submitLateDeviceResult(turn, call: call, status: status, data: data, operationID: operationID, token: token) }
        let stream: AsyncThrowingStream<ConversationTurnEvent, Error>
        do { stream = try await backend.submitDeviceResult(turn.request, call: call, status: status, data: data, operationID: operationID, afterSequence: turn.lastSequence) }
        catch let failure as ConversationApprovalFailure {
            if [.expired, .consumed, .stale, .notFound].contains(failure), active[conversationID] == token {
                if let observation = try? await backend.observe(turn.request), active[conversationID] == token, (try? Self.encode(observation.request)) == (try? Self.encode(turn.request)) {
                    for event in observation.events { try? await apply(event, request: turn.request, observing: true, observationToken: token) }
                }
            }
            throw failure
        }
        do { return try await pump(stream, request: turn.request, observationToken: token) }
        catch {
            if active[conversationID] == token, !(error is CancellationError) { try? await markUnknown(turn.request, reason: "结果已回传，状态待核对；读取原请求后继续。", observationToken: token) }
            throw error
        }
    }
    /// P1-4: late report. The turn stays closed: drain the server's reply without pumping it into the journal, then
    /// refresh the snapshot once so the card picks up `interaction_outcomes` (late / ttl_exceeded).
    private func submitLateDeviceResult(_ turn: ConversationTurnRecord, call: ConversationDeviceCall, status: String, data: Data?, operationID: UUID, token: UUID) async throws -> UUID {
        let stream = try await backend.submitDeviceResult(turn.request, call: call, status: status, data: data, operationID: operationID, afterSequence: turn.lastSequence)
        do { for try await _ in stream {} } catch is CancellationError { throw CancellationError() } catch { observeLog.error("late device result stream ended early") }
        if active[turn.request.conversationID] == token, let observation = try? await backend.observe(turn.request), active[turn.request.conversationID] == token {
            try? await restoreApprovals(observation, turnID: turn.id, observationToken: token)
        }
        return turn.id
    }
    /// Chat-UX #6: tells the turn that created `callID` that the user undid it on the phone (the model hears it with
    /// the next message). Needs the call to have been seen this session; the local delete never waits on this.
    public func submitDeviceUndo(scope: DataScope, callID: String, outcome: DeviceUndoOutcome) async throws {
        guard let (conversationID, turnID) = deviceCallIndex[callID] ?? DeviceCallTurnIndex.load(.standard).turn(for: callID) else { throw ConversationApprovalFailure.noPendingApproval }
        let saved = try await read(scope: scope, conversationID: conversationID)
        guard let turn = saved.turns.first(where: { $0.id == turnID }) else { throw ConversationApprovalFailure.noPendingApproval }
        try await backend.submitDeviceUndo(turn.request, callID: callID, outcome: outcome, operationID: stableID("device-undo-\(turnID)-\(callID)"))
    }
    /// Pending device calls of a conversation (cold start: show their cards again).
    public func pendingDeviceCalls(scope: DataScope, conversationID: UUID) async throws -> [ConversationDeviceCall] {
        let saved = try await read(scope: scope, conversationID: conversationID)
        var out: [ConversationDeviceCall] = []
        for turn in saved.turns { for call in turn.pendingDeviceCalls ?? [] { deviceCallIndex[call.callID] = (conversationID, turn.id); rememberDeviceTurn(call.callID, conversationID, turn.id); out.append(call) } }
        return out
    }
    /// Persisted call_id → turn for device-undo after an app restart (chat-ux #6).
    private func rememberDeviceTurn(_ callID: String, _ conversationID: UUID, _ turnID: UUID) {
        var index = DeviceCallTurnIndex.load(.standard)
        guard index.turn(for: callID) == nil else { return }
        index.set(callID, conversationID: conversationID, turnID: turnID); index.save(.standard)
    }
    private static func journalID(_ id: UUID) -> UUID { stableID("conversation-first-journal-\(id)") }
    private static func encode<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return String(decoding: try encoder.encode(value), as: UTF8.self) }
}

/// Scope-bound adapter for #36's `GenerativeUIDecisionSubmitting` (its signature has no scope).
/// Same method signature as the protocol, with our `ConversationUIDecision` (raw values submit / dismiss / report_error,
/// identical to #36's `GenerativeUIDecision`). Failures are `ConversationApprovalFailure` (show `friendlyMessage`).
/// After #36 lands, conform with (see GenerativeBlock.swift there):
///     extension ConversationUIDecisionSubmitter: GenerativeUIDecisionSubmitting {
///         public func submitUIDecision(conversationID: UUID, turnID: UUID, interruptID: String, decision: GenerativeUIDecision, argsHash: String, response: Data?, operationID: UUID) async throws {
///             guard let mapped = ConversationUIDecision(rawValue: decision.rawValue) else { throw ConversationApprovalFailure.unsupported }
///             try await submitUIDecision(conversationID: conversationID, turnID: turnID, interruptID: interruptID, decision: mapped, argsHash: argsHash, response: response, operationID: operationID)
///         }
///     }
public struct ConversationUIDecisionSubmitter: Sendable {
    public let scope: DataScope
    public let service: ConversationSessionService
    public init(service: ConversationSessionService, scope: DataScope) { self.service = service; self.scope = scope }
    public func submitUIDecision(conversationID: UUID, turnID: UUID, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID) async throws {
        try await service.submitUIDecision(scope: scope, conversationID: conversationID, turnID: turnID, interruptID: interruptID, decision: decision, argsHash: argsHash, response: response, operationID: operationID)
    }
    /// The same entry as a closure taking the raw decision string (for code that cannot name either enum).
    public var closure: @Sendable (_ conversationID: UUID, _ turnID: UUID, _ interruptID: String, _ decision: String, _ argsHash: String, _ response: Data?, _ operationID: UUID) async throws -> Void {
        let bound = self
        return { conversationID, turnID, interruptID, decision, argsHash, response, operationID in
            guard let mapped = ConversationUIDecision(rawValue: decision) else { throw ConversationApprovalFailure.rejected(status: 422, code: "approval_schema_invalid") }
            try await bound.submitUIDecision(conversationID: conversationID, turnID: turnID, interruptID: interruptID, decision: mapped, argsHash: argsHash, response: response, operationID: operationID)
        }
    }
    /// Cold start: waiting ui blocks to put back into the store.
    public func pendingUIApprovals(conversationID: UUID) async throws -> [ConversationUIApproval] {
        try await service.pendingUIApprovals(scope: scope, conversationID: conversationID)
    }
}

/// Scope-bound adapter for #44's `DeviceResultSubmitting` (`submit(_ result: DeviceCallResult)`; that type has no scope / turn).
/// After #44 lands, conform with:
///     extension ConversationDeviceResultSubmitter: DeviceResultSubmitting {
///         public func submit(_ result: DeviceCallResult) async throws {
///             let data = try result.data.map { try JSONEncoder().encode($0) }
///             try await submit(callID: result.call_id, status: result.status.rawValue, data: data)
///         }
///     }
/// and install it with `DeviceCallHub.submitter = ConversationDeviceResultSubmitter(service: service, scope: scope)` (clear at sign-out).
public struct ConversationDeviceResultSubmitter: Sendable {
    public let scope: DataScope
    public let service: ConversationSessionService
    public init(service: ConversationSessionService, scope: DataScope) { self.service = service; self.scope = scope }
    /// `data` is a JSON object (or nil). Failures are `ConversationApprovalFailure` / `ConversationSessionError.busy` (retry later).
    public func submit(callID: String, status: String, data: Data?) async throws {
        try await service.submitDeviceResult(scope: scope, callID: callID, status: status, data: data)
    }
    public func submitUndo(callID: String, outcome: DeviceUndoOutcome) async throws {
        try await service.submitDeviceUndo(scope: scope, callID: callID, outcome: outcome)
    }
    public func pendingDeviceCalls(conversationID: UUID) async throws -> [ConversationDeviceCall] {
        try await service.pendingDeviceCalls(scope: scope, conversationID: conversationID)
    }
}
