import Foundation

public struct ConversationConfiguration: Codable, Sendable {
    public var model: String
    public var safety: Bool
    public var subagents: Bool
    public var providerID: String? = nil
}
public struct ScheduleTemplate: Codable, Sendable {
    public var prompt: String
    public var projectID: UUID
    public var environmentID: UUID
    public var configuration: ConversationConfiguration
}
public func stableID(_ text: String) -> UUID {
    let hex = textHash(text)
    let chars = Array(hex.prefix(32))
    return UUID(uuidString: String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-4" + String(chars[13..<16]) + "-8" + String(chars[17..<20]) + "-" + String(chars[20..<32]))!
}

public actor WorkspaceService {
    public let repository: Repository
    public let blobs: BlobStore
    let beforeRunPublication: (@Sendable () async -> Void)?
    public init(repository: Repository, blobs: BlobStore, beforeRunPublication: (@Sendable () async -> Void)? = nil) { self.repository = repository; self.blobs = blobs; self.beforeRunPublication = beforeRunPublication }
    public func bootstrap(scope: DataScope) async throws {
        let current = await repository.read(scope: scope)
        guard current.list("environment", scope: scope).isEmpty else { return }
        var mutations: [Mutation] = []
        for kind in [EnvironmentKind.local, .cloud, .computer] {
            let id = environmentID(kind, scope)
            mutations.append(.create(id, .core(.environment(ExecutionEnvironment(name: kind == .local ? "本机" : kind == .cloud ? "云端" : "电脑", kind: kind, connection: kind == .local ? .connected : .unverified, capabilityIDs: kind == .local ? ["local_documents"] : [], verifiedAt: nil)))))
            guard Profiles.inEnvironment(kind, profile: scope) == scope else { continue }
            let projectID = stableID("\(scope.profileID)-\(kind.rawValue)-default-project")
            mutations.append(.create(projectID, .core(.project(Project(name: "默认项目 · \(kind == .local ? "本机" : kind == .cloud ? "云端" : "电脑")", summary: "独立 App 的本地项目，未同步远端。", documentIDs: [], defaultExpertID: nil, skillIDs: [])))))
            mutations.append(.create(stableID("project-env-\(projectID)"), .preference(Preference(key: "project_environment:\(projectID)", value: id.uuidString))))
        }
        let expert = stableID("\(scope.workspaceID)-expert-document")
        mutations.append(.create(expert, .core(.expert(Expert(name: "文档处理专家", summary: "整理、审阅和改写文档。当前为本地配置目录；执行来自具名 Fixture。", configurationJSON: Data("{\"version\":\"2.0.3\",\"category\":\"文档\",\"example\":\"帮我整理这份文档的要点\"}".utf8), preset: true, configurationRevision: 1)))))
        mutations.append(.create(stableID("\(scope.workspaceID)-skill-excel"), .core(.skill(Skill(name: "Excel", summary: "电子表格整理与分析。安装只记录本地模拟状态，无软件下载或执行。", definitionJSON: Data("{\"category\":\"办公\"}".utf8), version: "1.0", enabledScopeIDs: [])))))
        try await repository.commit(scope: scope, mutations: mutations)
        let sampleProject = stableID("\(scope.profileID)-\(Profiles.inEnvironment(.cloud, profile: scope) == scope ? "cloud" : Profiles.inEnvironment(.computer, profile: scope) == scope ? "computer" : "local")-default-project")
        _ = try await createDocument(scope: scope, title: "公开朗读示例.txt", mime: "text/plain", data: Data(PublicReadoutSample.text.utf8), owners: [sampleProject], source: PublicReadoutSample.sourceKind)
        if scope == Profiles.demo {
            let project = stableID("\(scope.profileID)-local-default-project")
            _ = try await createDocument(scope: scope, title: "虚构工作量.csv", mime: "text/csv", data: Data("Product,Planned Days,Actual Days,Difference\nA,3,4,1\nB,2,2,0\nC,5,6,1\nTotal,10,12,2".utf8), owners: [project], source: "fixture")
            _ = try await createDocument(scope: scope, title: "阅读器示例.md", mime: "text/markdown", data: Data("# 本地阅读器示例\n\n这些数值来自原图的虚构样例，未连接业务数据。\n\n|项目|计划|实际|差异|\n|---|---|---|---|\n|A|3|4|1|\n|B|2|2|0|\n|C|5|6|1|\n|合计|10|12|2|\n\n```swift\nlet reality = \"simulated\"\n```".utf8), owners: [project], source: "fixture")
        }
    }
    public nonisolated func environmentID(_ kind: EnvironmentKind, _ scope: DataScope) -> UUID { stableID("\(scope.workspaceID)-environment-\(kind.rawValue)") }
    public func createConversation(scope: DataScope, environment: UUID, project: UUID?, expert: UUID? = nil, skills: [UUID] = [], configuration: ConversationConfiguration) async throws -> UUID {
        let id = UUID()
        let c = Conversation(title: "新任务", projectID: project, expertID: expert, skillIDs: skills, environmentID: environment, archivedAt: nil, draftText: "")
        let config = String(data: try JSONEncoder().encode(configuration), encoding: .utf8)!
        try await repository.commit(scope: scope, mutations: [.create(id, .core(.conversation(c))), .create(stableID("config-\(id)"), .preference(Preference(key: "conversation_config:\(id)", value: config)))])
        return id
    }
    public func saveDraft(scope: DataScope, conversationID: UUID, text: String, expectedRevision: Int? = nil) async throws {
        let r = try await repository.record(conversationID, scope: scope)
        guard var c = r.conversation else { throw catError.missing }
        c.draftText = text
        try await repository.commit(scope: scope, mutations: [.update(r.id, expectedRevision ?? r.header.revision, .core(.conversation(c)))])
    }
    public func rename(scope: DataScope, id: UUID, name: String, expectedRevision: Int) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw catError.invalid("名称不能为空。") }
        let r = try await repository.record(id, scope: scope)
        var payload = r.payload
        switch payload {
        case .core(.conversation(var c)): c.title = name; payload = .core(.conversation(c))
        case .core(.project(var p)): p.name = name; payload = .core(.project(p))
        default: throw catError.invalid("这项内容不支持重命名。")
        }
        try await repository.commit(scope: scope, mutations: [.update(id, expectedRevision, payload)])
    }
    public func preference(scope: DataScope, key: String, value: String) async throws {
        try await repository.setPreference(scope: scope, key: key, value: value)
    }
    public func reconcileBlobsAtLaunch() async throws {
        try blobs.reconcile(referenced: await repository.referencedBlobs())
    }
    public func createProject(scope: DataScope, name: String, environment: UUID) async throws -> UUID {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw catError.invalid("项目名不能为空。") }
        let id = UUID()
        try await repository.commit(scope: scope, mutations: [.create(id, .core(.project(Project(name: name, summary: "新增本地管理流程", documentIDs: [], defaultExpertID: nil, skillIDs: [])))), .create(stableID("project-env-\(id)"), .preference(Preference(key: "project_environment:\(id)", value: environment.uuidString)))])
        return id
    }
    public func configureConversation(scope: DataScope, id: UUID, project: UUID?, expert: UUID?, skills: [UUID], expectedRevision: Int) async throws {
        let r = try await repository.record(id, scope: scope); guard var c = r.conversation else { throw catError.missing }
        if let project {
            let mapping = try await repository.record(stableID("project-env-\(project)"), scope: scope)
            guard case .preference(let p) = mapping.payload, p.value == c.environmentID.uuidString else { throw catError.invalid("项目与当前会话环境不一致。") }
        }
        guard project == c.projectID else { throw catError.invalid("切换项目必须打开独立会话，不能迁移已有历史。") }
        c.expertID = expert; c.skillIDs = skills
        try await repository.commit(scope: scope, mutations: [.update(id, expectedRevision, .core(.conversation(c)))])
    }
    /// Draft persistence and target creation are one transaction. The original conversation never moves.
    public func selectProjectConversation(scope: DataScope, sourceID: UUID, project: UUID?, draft: String) async throws -> UUID {
        let source = try await repository.record(sourceID, scope: scope)
        guard var conversation = source.conversation else { throw catError.missing }
        if let project {
            let mapping = try await repository.record(stableID("project-env-\(project)"), scope: scope)
            guard case .preference(let p) = mapping.payload, p.value == conversation.environmentID.uuidString else { throw catError.invalid("项目与当前环境不一致。") }
        }
        let snapshot = await repository.read(scope: scope)
        conversation.draftText = draft
        var mutations: [Mutation] = [.update(sourceID, source.header.revision, .core(.conversation(conversation)))]
        let target: UUID
        if project == conversation.projectID { target = sourceID }
        else if let existing = snapshot.list("conversation", scope: scope).filter({ $0.conversation?.projectID == project && $0.conversation?.environmentID == conversation.environmentID }).sorted(by: { $0.header.updatedAt > $1.header.updatedAt }).first { target = existing.id }
        else {
            target = UUID()
            let next = Conversation(title: "新任务", projectID: project, expertID: conversation.expertID, skillIDs: conversation.skillIDs, environmentID: conversation.environmentID, archivedAt: nil, draftText: "")
            mutations.append(.create(target, .core(.conversation(next))))
            if case .preference(let p) = snapshot.records[stableID("config-\(sourceID)")]?.payload {
                mutations.append(.create(stableID("config-\(target)"), .preference(Preference(key: "conversation_config:\(target)", value: p.value))))
            }
        }
        try await repository.commit(scope: scope, mutations: mutations)
        return target
    }
    public func installSkill(scope: DataScope, id: UUID, environment: UUID, enabled: Bool) async throws {
        let r = try await repository.record(id, scope: scope)
        guard case .core(.skill(var skill)) = r.payload else { throw catError.missing }
        skill.enabledScopeIDs.removeAll { $0 == environment }; if enabled { skill.enabledScopeIDs.append(environment) }
        try await repository.commit(scope: scope, mutations: [.update(id, r.header.revision, .core(.skill(skill)))])
    }
    @discardableResult public func createDocument(scope: DataScope, title: String, mime: String, data: Data, owners: [UUID], source: String) async throws -> DocumentReference {
        let id = UUID(); let hash = try blobs.stage(data)
        let doc = Document(title: title, mimeType: mime, currentVersion: 1, ownerIDs: owners, sourceKind: source)
        let version = DocumentVersion(documentID: id, version: 1, parentVersion: nil, privateBlobReference: hash, contentHash: hash)
        var mutations: [Mutation] = [.create(id, .core(.document(doc))), .create(stableID("\(id)-v1"), .core(.documentVersion(version)))]
        for owner in owners {
            let r = try await repository.record(owner, scope: scope)
            if case .core(.project(var p)) = r.payload { p.documentIDs.append(id); mutations.append(.update(owner, r.header.revision, .core(.project(p)))) }
        }
        try await repository.commit(scope: scope, mutations: mutations)
        return DocumentReference(documentID: id, version: 1, contentHash: hash)
    }
    public func readDocument(scope: DataScope, id: UUID, version: Int) async throws -> (DocumentReference, Data) {
        _ = try await repository.record(id, scope: scope)
        let r = try await repository.record(stableID("\(id)-v\(version)"), scope: scope)
        guard case .core(.documentVersion(let v)) = r.payload else { throw catError.missing }
        let data = try blobs.read(v.privateBlobReference)
        guard bytesHash(data) == v.contentHash else { throw catError.corrupt("正文校验失败。") }
        return (DocumentReference(documentID: id, version: version, contentHash: v.contentHash), data)
    }
    public func editDocument(scope: DataScope, id: UUID, expectedVersion: Int, text: String, voiceTurn: FrozenVoiceTurn? = nil, adapterID: String = "user_text_edit") async throws -> DocumentReference {
        if let voiceTurn {
            guard voiceTurn.scope == scope, case .document(let target) = voiceTurn.target, target.documentID == id, target.version == expectedVersion,
                  textHash(voiceTurn.transcript.submittedText) == voiceTurn.transcript.submittedTextHash else { throw catError.scopeMismatch }
            let receiptID = stableID("voice-edit-\(scope.profileID)-\(voiceTurn.transcript.clientMessageID)")
            let snapshot = await repository.read(scope: scope)
            if case .voiceEdit(let receipt) = snapshot.records[receiptID]?.payload {
                guard receipt.draftHash == textHash(text), receipt.turn.target == voiceTurn.target,
                      receipt.turn.transcript.submittedTextHash == voiceTurn.transcript.submittedTextHash else { throw catError.conflict }
                return receipt.result
            }
            let verified = try await readDocument(scope: scope, id: id, version: expectedVersion)
            guard verified.0 == target else { throw catError.conflict }
        }
        let r = try await repository.record(id, scope: scope); guard var d = r.document, d.currentVersion == expectedVersion else { throw catError.conflict }
        guard d.sourceKind != "gateway_synthetic" else { throw catError.invalid("Gateway-owned results are read-only in the native mirror.") }
        guard d.mimeType.hasPrefix("text/") else { throw catError.invalid("当前格式只支持阅读。") }
        let next = expectedVersion + 1; let hash = try blobs.stage(Data(text.utf8)); d.currentVersion = next
        let v = DocumentVersion(documentID: id, version: next, parentVersion: expectedVersion, privateBlobReference: hash, contentHash: hash)
        var mutations: [Mutation] = [.update(id, r.header.revision, .core(.document(d))), .create(stableID("\(id)-v\(next)"), .core(.documentVersion(v)))]
        let result = DocumentReference(documentID: id, version: next, contentHash: hash)
        if let voiceTurn { mutations.append(.create(stableID("voice-edit-\(scope.profileID)-\(voiceTurn.transcript.clientMessageID)"), .voiceEdit(VoiceEditReceipt(turn: voiceTurn, result: result, draftHash: hash, adapterID: adapterID)))) }
        let s = await repository.read(scope: scope)
        for a in s.list("action", scope: scope) {
            if case .action(var action) = a.payload, action.document.documentID == id, action.receipt == .notStarted {
                action.status = .invalidated; mutations.append(.update(a.id, a.header.revision, .action(action)))
            }
        }
        for a in s.list("artifact", scope: scope) {
            if case .artifact(var artifact) = a.payload, artifact.documentReference.documentID == id {
                artifact.documentReference = DocumentReference(documentID: id, version: next, contentHash: hash)
                artifact.currentReference = ArtifactReference(artifactID: a.id, version: next, contentHash: hash)
                mutations.append(.update(a.id, a.header.revision, .artifact(artifact)))
            }
        }
        try await repository.commit(operationID: voiceTurn.map { stableID("voice-commit-\(scope.profileID)-\($0.transcript.clientMessageID)") } ?? UUID(), scope: scope, mutations: mutations)
        return result
    }
    public func saveSchedule(scope: DataScope, id: UUID? = nil, revision: Int? = nil, title: String, spec: ScheduleSpec, template: ScheduleTemplate) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !template.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw catError.invalid("名称、工作空间与提示词必填。") }
        let project = try await repository.record(stableID("project-env-\(template.projectID)"), scope: scope)
        guard case .preference(let mapping) = project.payload, mapping.value == template.environmentID.uuidString else { throw catError.invalid("工作空间不属于选定环境。") }
        let p = ScheduledTask(title: title, schedule: spec, enabled: true, nextDueAt: try ScheduleCalculator.next(spec, after: Date()), lastLocalAttemptAt: nil, executionMode: .localSessionOnly, taskTemplateJSON: try JSONEncoder().encode(template))
        if let id, let revision { try await repository.commit(scope: scope, mutations: [.update(id, revision, .core(.schedule(p)))]) }
        else { try await repository.commit(scope: scope, mutations: [.create(UUID(), .core(.schedule(p)))]) }
    }
    public func toggleSchedule(scope: DataScope, id: UUID) async throws {
        let r = try await repository.record(id, scope: scope); guard case .core(.schedule(var p)) = r.payload else { throw catError.missing }
        p.enabled.toggle(); p.nextDueAt = p.enabled ? try ScheduleCalculator.next(p.schedule, after: Date()) : nil
        try await repository.commit(scope: scope, mutations: [.update(id, r.header.revision, .core(.schedule(p)))])
    }
    public func claimDueSchedules(scope: DataScope, now: Date, resumed: Bool) async throws -> [ScheduleTemplate] {
        let s = await repository.read(scope: scope); var templates: [ScheduleTemplate] = []; var edits: [Mutation] = []
        for r in s.list("schedule", scope: scope) {
            guard case .core(.schedule(var p)) = r.payload, p.enabled, let due = p.nextDueAt, due <= now else { continue }
            p.nextDueAt = try ScheduleCalculator.next(p.schedule, after: now)
            if !resumed { p.lastLocalAttemptAt = now; templates.append(try JSONDecoder().decode(ScheduleTemplate.self, from: p.taskTemplateJSON)) }
            edits.append(.update(r.id, r.header.revision, .core(.schedule(p))))
        }
        if !edits.isEmpty { try await repository.commit(scope: scope, mutations: edits, now: now) }; return templates
    }
}
