import Foundation

public actor ConversationSessionService {
    private let repository: Repository
    private let backend: any ConversationBackend
    // A business epoch stays stable across recovery; each local observer needs its own fence.
    private var active: [UUID: UUID] = [:]
    private static let selectionKey = "conversation_first_selected"
    public nonisolated var supportsArtifactContinuations:Bool {backend.supportsArtifactContinuations}
    public nonisolated var artifactContinuationSubjectID:UUID? {backend.artifactContinuationSubjectID}
    public init(repository: Repository, backend: any ConversationBackend = UnconfiguredConversationBackend(), resilience: (any ConversationStreamResilience)? = nil, reconnectPolicy: ConversationReconnectPolicy = .init(), outbox: ConversationOutbox? = nil) { self.repository = repository; self.backend = backend; self.resilience = resilience; self.reconnectPolicy = reconnectPolicy; self.outbox = outbox }
    private let outbox: ConversationOutbox?
    private struct BusyRetry: Sendable { var due: Date; var operationID: UUID; var autoRetried: Bool }
    private var busyRetry: [UUID: BusyRetry] = [:]
    private var autoRetryTurns: Set<UUID> = []
    private var turnObservers: [UUID: AsyncStream<ConversationTurnEvent>.Continuation] = [:]
    private var emittedCancellations: Set<UUID> = []
    private var cancelling: Set<UUID> = []
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
    /// Wire history for a turn: the local transcript minus user messages of other turns that never reached the
    /// server (notSent / cancelledBeforeSend). Those stay visible locally but would make the server history a
    /// strict prefix of ours, which prepare() correctly rejects as a conflict and which used to deadlock the queue.
    static func dispatchHistory(_ session: ConversationSession, current: UUID) -> [ConversationTranscriptMessage] {
        let unsent = Set(session.turns.filter { $0.id != current && [.notSent, .cancelledBeforeSend].contains($0.state) }.map { stableID("conversation-user-\($0.id)") })
        return session.messages.filter { !unsent.contains($0.id) }
    }
    public func send(scope: DataScope, conversationID: UUID, text: String, operationID: UUID, context: [ConversationExplicitContext] = [], preserveDraft:Bool = false,image:ConversationVisionPayload?=nil,continuation:ConversationArtifactContinuationIntent?=nil,acceptedWork:ConversationAcceptedWorkSelection?=nil,revisionWork:ConversationRevisionWorkSelection?=nil) async throws -> UUID {
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
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
        var (session, journalRevision) = try await readVersioned(scope: scope, conversationID: conversationID)
        let request: ConversationTurnRequest
        let epoch: Int
        if let index = session.turns.firstIndex(where: { $0.id == operationID }) {
            let prior = session.turns[index]
            guard prior.request.image == image?.reference,prior.request.continuation==continuation,prior.request.acceptedWork?.selection==acceptedWork,prior.request.revisionWork?.selection==revisionWork else {throw CatpawError.conflict}
            guard prior.request.history.last?.content == text, try Self.encode(prior.request.context) == Self.encode(context) else { throw CatpawError.conflict }
            guard prior.state != .cancelledBeforeSend else { throw CatpawError.conflict }
            guard prior.state == .notSent else { return operationID }
            guard session.unresolved == nil else { throw ConversationSessionError.unresolvedOperation }
            if prior.request.acceptedWork == nil, prior.request.revisionWork == nil {
                // Resend of a held message: rebuild history from what the server can have seen, with this
                // message last. Other unsent messages never enter the wire history.
                guard let own = prior.request.history.last, own.role == .user else { throw CatpawError.conflict }
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
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let observationToken = UUID(); active[conversationID] = observationToken
        defer { if active[conversationID] == observationToken { active.removeValue(forKey: conversationID) } }
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
            // R7 busy: countdown, then one automatic retry (see foregroundTick); never for an auto-retried turn.
            let wait = max(1, last.retryAfterSeconds ?? 20)
            busyRetry[conversationID] = BusyRetry(due: Date().addingTimeInterval(TimeInterval(wait)), operationID: operationID, autoRetried: autoRetryTurns.contains(operationID))
            await resilience?.busy(retryIn: wait)
        }
        if saved.turns.last?.state == .completed { try? await outbox?.remove(operationID); await backend.recordCommittedReply(request);return operationID }
        // catpaw.approval.v1: a suspended turn is admitted and waiting for submitApproval (not an error).
        if let last = saved.turns.last, last.id == operationID, last.awaitingApproval { try? await outbox?.remove(operationID); return operationID }
        if saved.turns.last?.state == .failed { throw CatpawError.unavailable(saved.turns.last?.error ?? "服务请求失败。") }
        throw ConversationSessionError.unresolvedOperation
    }
    private func save(_ value: ConversationSession, expectedRevision: Int, fence: ConversationTurnRequest? = nil, observationToken: UUID? = nil, additional: [Mutation] = []) async throws {
        let r = try await repository.record(Self.journalID(value.conversationID), scope: value.scope)
        guard r.header.revision == expectedRevision else { throw CatpawError.conflict }
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
        switch event.payload {
        case .thread(let id):
            guard !id.isEmpty, session.threadID == nil || session.threadID == id else { throw ConversationSessionError.invalidEvent }; session.threadID = id
        case .started(let hash, let revision, let grant,let receipts):
            if let image=request.image {guard receipts == [image.receipt] else {throw ConversationSessionError.invalidEvent}} else {guard receipts == nil || receipts?.isEmpty == true else {throw ConversationSessionError.invalidEvent}}
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
            turn.state = .completed; turn.error = nil; turn.pendingApprovals = nil
        case .reasoningSummary(_, let text, let ms):
            guard turn.assistantMessageID == nil else { throw ConversationSessionError.invalidEvent }
            turn.reasoningSummary = text; turn.thinkingMs = ms
        case .approvalRequested(let approval):
            let callRow = stableID("conversation-call-\(request.operationID)-\(approval.callID)")
            guard Self.isPlain(request), session.messages.contains(where: { $0.id == callRow && $0.toolName == approval.tool && !$0.complete }),
                  !(turn.pendingApprovals ?? []).contains(where: { $0.interruptID == approval.interruptID || $0.callID == approval.callID }) else { throw ConversationSessionError.invalidEvent }
            turn.pendingApprovals = (turn.pendingApprovals ?? []) + [approval]
        case .suspended(let ids, _):
            let pending = Set((turn.pendingApprovals ?? []).map(\.interruptID))
            guard !ids.isEmpty, Set(ids).isSubset(of: pending) else { throw ConversationSessionError.invalidEvent }
        case .approvalResolved(let id, let call, _, _):
            // A replay/observe may resolve an interrupt this journal never saw pending (e.g. expired while offline).
            if let i = turn.pendingApprovals?.firstIndex(where: { $0.interruptID == id }) { guard turn.pendingApprovals?[i].callID == call else { throw ConversationSessionError.invalidEvent }; turn.pendingApprovals?.remove(at: i) }
            if turn.pendingApprovals?.isEmpty == true { turn.pendingApprovals = nil }
        case .failed(let reason, let reconciliation):
            turn.state = reconciliation ? .unknown : .failed; turn.error = reason
            if !reconciliation { turn.pendingApprovals = nil }
            if reason == Self.rateLimitedCode { turn.retryAfterSeconds = event.retryAfterSeconds }
            if !reconciliation {
                for i in session.messages.indices where Self.isToolAttempt(session.messages[i], for: request) && !session.messages[i].complete {
                    session.messages[i].complete = true; session.messages[i].failure = reason
                }
            }
        }
        session.turns[index] = turn; try await save(session, expectedRevision: journalRevision, fence: request, observationToken: observationToken)
        emit(event)
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
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let saved = try await read(scope: scope, conversationID: conversationID)
        guard let turn = saved.unresolved ?? saved.turns.last(where: { ![.notSent, .cancelledBeforeSend].contains($0.state) }) else { return }
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let observationToken = UUID(); active[conversationID] = observationToken
        defer { if active[conversationID] == observationToken { active.removeValue(forKey: conversationID) } }
        // R7 §5.3 rebuild: a still-running plain turn first reattaches by GET-after-lastSequence
        // (append only); the authoritative snapshot below then reconciles goals and terminal state.
        if Self.isPlain(turn.request), [.dispatched, .running, .unknown].contains(turn.state) {
            await resilience?.syncing()
            do {
                let stream = try await backend.resumeEvents(turn.request, afterSequence: turn.lastSequence)
                for try await event in stream {
                    guard active[conversationID] == observationToken else { throw CancellationError() }
                    try await apply(event, request: turn.request, observing: true, observationToken: observationToken)
                    if let current = try await read(scope: scope, conversationID: conversationID).turns.first(where: { $0.id == turn.id }), [.completed, .failed].contains(current.state) { break }
                }
            } catch is CancellationError { await resilience?.settled(); throw CancellationError() }
            catch { /* fall back to the snapshot read below */ }
            await resilience?.settled()
        }
        let observation = try await backend.observe(turn.request)
        try Task.checkCancellation()
        guard active[conversationID] == observationToken else { throw CancellationError() }
        guard try Self.encode(observation.request) == Self.encode(turn.request) else { throw ConversationSessionError.invalidEvent }
        guard turn.serverRequestHash == nil || observation.requestHash == turn.serverRequestHash, turn.serverGrantEpoch == nil || observation.grantEpoch == turn.serverGrantEpoch else { throw ConversationSessionError.invalidEvent }
        for event in observation.events { guard active[conversationID] == observationToken else { throw CancellationError() }; try await apply(event, request: turn.request, observing: true, observationToken: observationToken) }
        try await restoreApprovals(observation, turnID: turn.id, observationToken: observationToken)
        if try await read(scope:scope,conversationID:conversationID).turns.first(where:{$0.id==turn.id})?.state == .completed {await backend.recordCommittedReply(turn.request)}
        if !observation.goals.isEmpty { var (current, revision) = try await readVersioned(scope: scope, conversationID: conversationID); for goal in observation.goals { try Self.merge(goal, into: &current) }; try await save(current, expectedRevision: revision, fence: turn.request, observationToken: observationToken) }
    }
    static let rateLimitedCode = "rate_limited"
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
    /// "现在重试" / "换一个免费模型": only for a turn the server reported as `failed{rate_limited}`
    /// before any assistant output. That original turn is terminal, so this is a new turn with the
    /// same text, never a resend of an accepted POST. `route` sets the DEBUG developer route first.
    @discardableResult
    public func retryBusy(scope: DataScope, conversationID: UUID, route: ConversationModelRoute? = nil, automatic: Bool = false) async throws -> UUID? {
        guard let entry = busyRetry[conversationID] else { return nil }
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        busyRetry[conversationID] = nil
        let saved = try await read(scope: scope, conversationID: conversationID)
        // Same operationID, same user message: no new transcript row; the server restarts the failed turn.
        guard let original = saved.turns.first(where: { $0.id == entry.operationID }), saved.turns.last?.id == original.id,
              original.state == .failed, original.error == Self.rateLimitedCode,
              original.assistantMessageID == nil, Self.isPlain(original.request) else { return nil }
        if let route { route.select() }
        if automatic { autoRetryTurns.insert(original.id) }
        await resilience?.clearBusy()
        let observationToken = UUID(); active[conversationID] = observationToken
        defer { if active[conversationID] == observationToken { active.removeValue(forKey: conversationID) } }
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
        let stopToken = UUID();active[conversationID] = stopToken
        defer { if active[conversationID] == stopToken { active.removeValue(forKey:conversationID) } }
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
        guard !cancelling.contains(conversationID) else { throw ConversationSessionError.busy }
        guard let target = try await read(scope: scope, conversationID: conversationID).unresolved else { return .noActiveTurn }
        cancelling.insert(conversationID)
        let token = UUID(); active[conversationID] = token
        defer {
            cancelling.remove(conversationID)
            if active[conversationID] == token { active.removeValue(forKey: conversationID) }
        }
        let operationID = target.id
        // A user stop is never resent automatically.
        if busyRetry[conversationID]?.operationID == operationID { busyRetry[conversationID] = nil; await resilience?.clearBusy() }
        autoRetryTurns.remove(operationID)
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
        try await markUnknown(target.request, reason: "已请求停止，结果待核对；读取原请求后继续。", observationToken: token)
        if let receipt, receipt.cancelled, receipt.state == "failed" {
            emit(ConversationTurnEvent(operationID: operationID, epoch: target.request.epoch, sequence: current?.lastSequence ?? target.lastSequence, payload: .failed(message: Self.cancelledCode, reconciliationRequired: false)))
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
    static let approvalToolNames: Set<String> = ["list_tasks", "create_task", "update_task", "create_calendar_event", "update_calendar_event", "create_reminder", "update_reminder", "external_write"]
    /// Cold start / observe: the snapshot's `pending_approvals` is authoritative for a turn the server reports `awaiting_approval`.
    private func restoreApprovals(_ observation: ConversationObservation, turnID: UUID, observationToken: UUID) async throws {
        let request = observation.request
        var (session, revision) = try await readVersioned(scope: request.scope, conversationID: request.conversationID)
        guard let i = session.turns.firstIndex(where: { $0.id == turnID }) else { return }
        var turn = session.turns[i]
        if observation.serverState == "awaiting_approval", !observation.pendingApprovals.isEmpty {
            guard [.running, .unknown, .dispatched].contains(turn.state) else { return }
            for approval in observation.pendingApprovals {
                let row = stableID("conversation-call-\(request.operationID)-\(approval.callID)")
                guard session.messages.contains(where: { $0.id == row && $0.toolName == approval.tool }) else { throw ConversationSessionError.invalidEvent }
            }
            turn.state = .running; turn.error = nil; turn.pendingApprovals = observation.pendingApprovals
        } else if turn.pendingApprovals != nil, observation.serverState != nil, observation.serverState != "awaiting_approval" {
            turn.pendingApprovals = nil
        } else { return }
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
        guard active[conversationID] == nil, !cancelling.contains(conversationID) else { throw ConversationSessionError.busy }
        let saved = try await read(scope: scope, conversationID: conversationID)
        guard let turn = saved.turns.last(where: { $0.awaitingApproval }), let approval = turn.pendingApprovals?.first(where: { $0.interruptID == interruptID }) else { throw ConversationApprovalFailure.noPendingApproval }
        guard decision != .approveAlways || approval.rememberAllowed else { throw ConversationApprovalFailure.rejected(status: 422, code: "approval_remember_not_allowed") }
        let token = UUID(); active[conversationID] = token
        defer { if active[conversationID] == token { active.removeValue(forKey: conversationID) } }
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
    private static func journalID(_ id: UUID) -> UUID { stableID("conversation-first-journal-\(id)") }
    private static func encode<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return String(decoding: try encoder.encode(value), as: UTF8.self) }
}
