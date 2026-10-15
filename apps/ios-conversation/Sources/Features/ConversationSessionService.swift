import Foundation

public actor ConversationSessionService {
    private let repository: Repository
    private let backend: any ConversationBackend
    // A business epoch stays stable across recovery; each local observer needs its own fence.
    private var active: [UUID: UUID] = [:]
    private static let selectionKey = "conversation_first_selected"
    public nonisolated var supportsArtifactContinuations:Bool {backend.supportsArtifactContinuations}
    public nonisolated var artifactContinuationSubjectID:UUID? {backend.artifactContinuationSubjectID}
    public init(repository: Repository, backend: any ConversationBackend = UnconfiguredConversationBackend(), resilience: (any ConversationStreamResilience)? = nil, reconnectPolicy: ConversationReconnectPolicy = .init()) { self.repository = repository; self.backend = backend; self.resilience = resilience; self.reconnectPolicy = reconnectPolicy }
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
    public func send(scope: DataScope, conversationID: UUID, text: String, operationID: UUID, context: [ConversationExplicitContext] = [], preserveDraft:Bool = false,image:ConversationVisionPayload?=nil,continuation:ConversationArtifactContinuationIntent?=nil,acceptedWork:ConversationAcceptedWorkSelection?=nil,revisionWork:ConversationRevisionWorkSelection?=nil) async throws -> UUID {
        guard active[conversationID] == nil else { throw ConversationSessionError.busy }
        let connection = await backend.connection(scope: scope)
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
            guard session.unresolved == nil, try Self.encode(prior.request.history) == Self.encode(session.messages) else { throw ConversationSessionError.unresolvedOperation }
            request = prior.request.withImageBytes(image?.bytes); epoch = request.epoch
            session.turns[index].state = .dispatched; session.turns[index].error = nil
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
            var provisional = ConversationTurnRequest(scope: scope, conversationID: conversationID, threadID: session.threadID, operationID: operationID, epoch: epoch, history: session.messages, context: context,image:image?.reference,imageBytes:image?.bytes,continuation:continuation,continuationOriginalBinding:originalBinding,continuationSubjectID:continuationSubject)
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
            var stream = try await backend.reply(request)
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
                    catch let again as ConversationStreamInterrupted { stream = AsyncThrowingStream { $0.finish(throwing: again) } }
                }
            }
            await resilience?.settled()
            let saved = try await read(scope: scope, conversationID: conversationID)
            if saved.turns.last?.state == .completed { await backend.recordCommittedReply(request);return operationID }
            if saved.turns.last?.state == .failed { throw CatpawError.unavailable(saved.turns.last?.error ?? "服务请求失败。") }
            throw ConversationSessionError.unresolvedOperation
        } catch {
            if active[conversationID] == observationToken {
                if error is ConversationDispatchFailure { try await markNotSent(request, reason: error.localizedDescription, observationToken: observationToken) }
                else { try await markUnknown(request, reason: error.localizedDescription, observationToken: observationToken) }
            }
            throw error
        }
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
        guard event.sequence == turn.lastSequence + 1, ![.completed, .failed].contains(turn.state), observing || turn.state != .unknown else { throw ConversationSessionError.invalidEvent }
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
            guard (["delegate_task", "delegate_plan_v1", "delegate_sources_v1", "agent_status", "present_cgui_v1", "propose_memory_v1"].contains(name) && request.continuation == nil) || (name == (request.revisionWork==nil ? "revise_current_report_v1":ConversationRevisionWorkCodec.toolName) && request.continuation?.intent == .reviseReport), !call.isEmpty else { throw ConversationSessionError.invalidEvent }
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
            turn.state = .completed; turn.error = nil
        case .reasoningSummary(_, let text, let ms):
            guard turn.assistantMessageID == nil else { throw ConversationSessionError.invalidEvent }
            turn.reasoningSummary = text; turn.thinkingMs = ms
        case .failed(let reason, let reconciliation):
            turn.state = reconciliation ? .unknown : .failed; turn.error = reason
            if !reconciliation {
                for i in session.messages.indices where Self.isToolAttempt(session.messages[i], for: request) && !session.messages[i].complete {
                    session.messages[i].complete = true; session.messages[i].failure = reason
                }
            }
        }
        session.turns[index] = turn; try await save(session, expectedRevision: journalRevision, fence: request, observationToken: observationToken)
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
        let observation = try await backend.observe(turn.request)
        try Task.checkCancellation()
        guard active[conversationID] == observationToken else { throw CancellationError() }
        guard try Self.encode(observation.request) == Self.encode(turn.request) else { throw ConversationSessionError.invalidEvent }
        guard turn.serverRequestHash == nil || observation.requestHash == turn.serverRequestHash, turn.serverGrantEpoch == nil || observation.grantEpoch == turn.serverGrantEpoch else { throw ConversationSessionError.invalidEvent }
        for event in observation.events { guard active[conversationID] == observationToken else { throw CancellationError() }; try await apply(event, request: turn.request, observing: true, observationToken: observationToken) }
        if try await read(scope:scope,conversationID:conversationID).turns.first(where:{$0.id==turn.id})?.state == .completed {await backend.recordCommittedReply(turn.request)}
        if !observation.goals.isEmpty { var (current, revision) = try await readVersioned(scope: scope, conversationID: conversationID); for goal in observation.goals { try Self.merge(goal, into: &current) }; try await save(current, expectedRevision: revision, fence: turn.request, observationToken: observationToken) }
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
    private static func journalID(_ id: UUID) -> UUID { stableID("conversation-first-journal-\(id)") }
    private static func encode<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return String(decoding: try encoder.encode(value), as: UTF8.self) }
}
