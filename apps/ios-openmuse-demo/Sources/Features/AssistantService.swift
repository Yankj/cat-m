import Foundation

extension WorkspaceService {
    public func createDelegation(scope: DataScope, goal: String, stop: String, requirements: String = "") async throws -> UUID {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatpawError.invalid("请写明目标与停止条件。") }
        let id = UUID()
        let d = Delegation(title: String(goal.prefix(28)), goal: goal, sourceIDs: [], scopeJSON: try JSONEncoder().encode(DelegationRequirements(requirements: requirements)), stopConditions: [stop], schedule: nil, state: .active, health: "仅在你主动操作或应用活跃时模拟准备；云端持续执行尚未接入", nextCheckAt: nil, archivedAt: nil, reality: .simulated)
        try await repository.commit(scope: scope, mutations: [.create(id, .delegation(d))]); return id
    }
    public func editDelegation(scope: DataScope, id: UUID, expectedRevision: Int, goal: String, requirements: String, stop: String) async throws {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatpawError.invalid("目标与停止条件必填。") }
        let record = try await repository.record(id, scope: scope)
        guard var delegation = record.delegation, [.active, .paused].contains(delegation.state) else { throw CatpawError.invalid("只能编辑进行中或已暂停的委托。") }
        delegation.goal = goal; delegation.title = String(goal.prefix(28)); delegation.stopConditions = [stop]
        delegation.scopeJSON = try DelegationRequirements.replacing(delegation.scopeJSON, requirements: requirements)
        try await repository.commit(scope: scope, mutations: [.update(id, expectedRevision, .delegation(delegation))])
    }
    public func changeDelegation(scope: DataScope, id: UUID, state: DelegationState, expectedRevision: Int) async throws {
        let r = try await repository.record(id, scope: scope); guard var d = r.delegation else { throw CatpawError.missing }
        let allowed = (d.state == .active && [.paused, .cancelled, .completed].contains(state)) || (d.state == .paused && [.active, .cancelled, .completed].contains(state))
        guard allowed else { throw CatpawError.invalid("委托状态不能这样改变。") }
        d.state = state
        try await repository.commit(scope: scope, mutations: [.update(id, expectedRevision, .delegation(d))])
    }
    public func addSource(scope: DataScope, delegationID: UUID, url: String) async throws {
        guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil else { throw CatpawError.invalid("请输入不含凭据的有效 http(s) 来源地址。") }
        let r = try await repository.record(delegationID, scope: scope); guard var d = r.delegation else { throw CatpawError.missing }
        let id = UUID(); d.sourceIDs.append(id)
        try await repository.commit(scope: scope, mutations: [.create(id, .source(SourceItem(delegationID: delegationID, url: url, revision: 1, allowed: true))), .update(r.id, r.header.revision, .delegation(d))])
    }
    public func sourcePermission(scope: DataScope, id: UUID, allowed: Bool) async throws {
        let r = try await repository.record(id, scope: scope); guard case .source(var source) = r.payload else { throw CatpawError.missing }
        source.allowed = allowed; source.revision += 1
        try await repository.commit(scope: scope, mutations: [.update(r.id, r.header.revision, .source(source))])
    }
    public func replaceSource(scope: DataScope, id: UUID, url: String) async throws {
        guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil else { throw CatpawError.invalid("来源 URL 无效。") }
        let r = try await repository.record(id, scope: scope); guard case .source(var source) = r.payload else { throw CatpawError.missing }
        source.url = url; source.revision += 1 // Permission deliberately stays unchanged.
        try await repository.commit(scope: scope, mutations: [.update(id, r.header.revision, .source(source))])
    }
    public func addMemory(scope: DataScope, content: String, scopeID: UUID, sourceMessageID: UUID? = nil) async throws -> UUID {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatpawError.invalid("记忆内容不能为空。") }
        let current = await repository.read(scope: scope)
        if let sourceMessageID, current.list("suppression", scope: scope).contains(where: { if case .suppression(let p) = $0.payload { return p.sourceMessageIDs.contains(sourceMessageID) }; return false }) { throw CatpawError.invalid("该来源已被遗忘屏蔽，不会自动重建记忆。") }
        let id = UUID()
        let memory = MemoryItem(kind: "explicit", scopeKind: .delegation, scopeID: scopeID, content: content, sourceReferences: ["user_explicit"], sourceUserMessageID: sourceMessageID, status: .active, validUntil: nil, supersedes: nil, deletionEpoch: 0)
        try await repository.commit(scope: scope, mutations: [.create(id, .memory(memory))]); return id
    }
    public func editMemory(scope: DataScope, id: UUID, text: String, expectedRevision: Int) async throws {
        guard !text.isEmpty else { throw CatpawError.invalid("记忆内容不能为空。") }
        let r = try await repository.record(id, scope: scope); guard case .memory(var m) = r.payload else { throw CatpawError.missing }
        m.content = text
        try await repository.commit(scope: scope, mutations: [.update(id, expectedRevision, .memory(m))])
    }
    public func forgetMemory(scope: DataScope, id: UUID) async throws {
        let r = try await repository.record(id, scope: scope); guard case .memory(var m) = r.payload else { throw CatpawError.missing }
        m.status = .deleted; m.deletionEpoch += 1; m.content = ""
        let suppression = ForgetSuppression(deletedMemoryID: id, scopeKind: m.scopeKind, scopeID: m.scopeID, sourceMessageIDs: [m.sourceUserMessageID].compactMap { $0 }, sourceSpanIDs: [], lineageIDs: [id], subjectPredicateHMAC: nil, deletionEpoch: m.deletionEpoch, clearedByNewUserMessageID: nil)
        var mutations: [Mutation] = [.update(id, r.header.revision, .memory(m)), .create(UUID(), .suppression(suppression))]
        let snapshot = await repository.read(scope: scope)
        for record in snapshot.list("preference", scope: scope) {
            if case .preference(var p) = record.payload, p.key.hasPrefix("run_context:"), let data = p.value.data(using: .utf8), let context = try? JSONDecoder().decode([StoredRecord].self, from: data), context.contains(where: { $0.id == id }) {
                p.value = String(data: try JSONEncoder().encode(context.filter { $0.id != id }), encoding: .utf8)!
                mutations.append(.update(record.id, record.header.revision, .preference(p)))
            }
        }
        try await repository.commit(scope: scope, mutations: mutations)
    }
    public func runDelegation(scope: DataScope, id: UUID) async throws -> UUID {
        let r = try await repository.record(id, scope: scope); guard let d = r.delegation, d.state == .active else { throw CatpawError.invalid("委托需处于进行中。暂停或结束不会自动恢复授权。") }
        let snapshot = await repository.read(scope: scope)
        let memories = snapshot.list("memory", scope: scope).filter { if case .memory(let m) = $0.payload { return m.scopeID == id && m.status == .active }; return false }
        let sources = snapshot.list("source", scope: scope).filter { if case .source(let s) = $0.payload { return s.delegationID == id && s.allowed }; return false }
        let runID = UUID(), taskID = UUID(), docID = UUID(), artifactID = UUID(), conversationID = UUID()
        let env = environmentID(Profiles.inEnvironment(.cloud, profile: scope) == scope ? .cloud : Profiles.inEnvironment(.computer, profile: scope) == scope ? .computer : .local, scope)
        let c = Conversation(title: d.title, projectID: nil, expertID: nil, skillIDs: [], environmentID: env, archivedAt: nil, draftText: "")
        let body = "# \(d.title)\n\n【模拟准备 · cat Fixture v1】\n\n本次目标：\(d.goal)\n\n这是供改稿和流程验证的本地短稿。真实资料读取、研究与云调度尚未接通。\n\n工作边界：持续执行交给云 worker；受理、完成和未知分开记录；修改后重新确认具体版本与目的地。\n\n本次记忆快照：\n\(memories.map { $0.title }.joined(separator: "\n"))\n\n允许的来源配置（未读取）：\n\(sources.compactMap { if case .source(let s) = $0.payload { return s.url }; return nil }.joined(separator: "\n"))"
        let frozenBody = body + "\n\n本次要求：\n\(DelegationRequirements.decode(d.scopeJSON).requirements)\n\n本次停止条件：\n\(d.stopConditions.joined(separator: "\n"))"
        let hash = try blobs.stage(Data(frozenBody.utf8))
        let reference = DocumentReference(documentID: docID, version: 1, contentHash: hash)
        let task = WorkTask(title: "模拟准备：\(d.title)", conversationID: conversationID, environmentID: env, operationID: UUID(), state: .succeeded, steps: [WorkStep(id: UUID(), title: "冻结上下文", state: .succeeded, evidenceReference: "fixture:v1"), WorkStep(id: UUID(), title: "本地模拟短稿", state: .succeeded, evidenceReference: hash)], results: [reference], reality: .simulated)
        let run = AssistantRun(delegationID: id, delegationRevision: r.header.revision, taskID: taskID, triggerEventIDs: [], state: .succeeded, contextEpochs: memories.compactMap { if case .memory(let m) = $0.payload { return ScopedContextEpoch(scopeKind: m.scopeKind, scopeID: m.scopeID, epoch: m.deletionEpoch) }; return nil }, artifactIDs: [artifactID], reality: .simulated)
        let artifact = Artifact(title: d.title, kind: "research_brief", currentReference: ArtifactReference(artifactID: artifactID, version: 1, contentHash: hash), documentReference: reference, state: .ready, evidenceIDs: sources.map(\.id), generatedFromRunID: runID)
        let version = DocumentVersion(documentID: docID, version: 1, parentVersion: nil, privateBlobReference: hash, contentHash: hash)
        let contextJSON = String(data: try JSONEncoder().encode(memories), encoding: .utf8)!
        let guards = ([r] + memories + sources).map { Mutation.requireRevision($0.id, $0.header.revision) }
        if let beforeRunPublication { await beforeRunPublication() }
        try await repository.commit(scope: scope, mutations: guards + [.create(conversationID, .core(.conversation(c))), .create(taskID, .core(.task(task))), .create(runID, .run(run)), .create(docID, .core(.document(Document(title: "\(d.title).md", mimeType: "text/markdown", currentVersion: 1, ownerIDs: [id, conversationID], sourceKind: "fixture")))), .create(stableID("\(docID)-v1"), .core(.documentVersion(version))), .create(artifactID, .artifact(artifact)), .create(UUID(), .preference(Preference(key: "run_context:\(runID)", value: contextJSON)))])
        return artifactID
    }
    public func prepareAction(scope: DataScope, document: DocumentReference, destination: String) async throws -> UUID {
        guard !destination.trimmingCharacters(in: .whitespaces).isEmpty else { throw CatpawError.invalid("请输入明确的模拟目的地。") }
        let snapshot = await repository.read(scope: scope)
        guard snapshot.records[document.documentID]?.document?.currentVersion == document.version else { throw CatpawError.conflict }
        let verified = try await readDocument(scope: scope, id: document.documentID, version: document.version)
        guard verified.0.contentHash == document.contentHash else { throw CatpawError.conflict }
        guard !snapshot.list("action", scope: scope).contains(where: { if case .action(let a) = $0.payload { return a.document.documentID == document.documentID && [.accepted, .unknown, .dispatchCommitted].contains(a.receipt) }; return false }) else { throw CatpawError.invalid("已有受理或未知记录。请先查询原操作状态，不能新发。") }
        let id = UUID()
        let action = ActionDraft(document: document, destination: destination, digest: textHash("\(document.documentID):\(document.version):\(document.contentHash):\(destination):single_fixture_send"), status: .pending, receipt: .notStarted, operationID: UUID(), queryCount: 0)
        try await repository.commit(scope: scope, mutations: [.create(id, .action(action))]); return id
    }
    public func approveAction(scope: DataScope, id: UUID, expectedRevision: Int) async throws {
        let r = try await repository.record(id, scope: scope); guard case .action(var a) = r.payload, a.status == .pending, a.receipt == .notStarted, a.expiresAt > Date() else { throw CatpawError.invalid("本次确认已失效。") }
        let d = try await repository.record(a.document.documentID, scope: scope)
        guard d.document?.currentVersion == a.document.version else { throw CatpawError.conflict }
        let fixed = try await readDocument(scope: scope, id: a.document.documentID, version: a.document.version)
        guard fixed.0.contentHash == a.document.contentHash else { throw CatpawError.conflict }
        a.status = .consumed; a.receipt = .accepted; a.history.append(.accepted)
        try await repository.commit(scope: scope, mutations: [.update(id, expectedRevision, .action(a))])
    }
    public func queryAction(scope: DataScope, id: UUID, unknown: Bool = false) async throws {
        let r = try await repository.record(id, scope: scope); guard case .action(var a) = r.payload, [.accepted, .unknown].contains(a.receipt) else { throw CatpawError.invalid("当前记录无需核验。") }
        a.queryCount += 1; a.receipt = unknown ? .unknown : .verified; a.history.append(a.receipt)
        try await repository.commit(scope: scope, mutations: [.update(id, r.header.revision, .action(a))])
    }
}
