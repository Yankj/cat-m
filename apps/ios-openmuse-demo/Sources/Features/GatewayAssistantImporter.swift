import Foundation

public struct GatewayAssistantProjection: Decodable, Sendable {
    public struct DelegationDTO: Decodable, Sendable {
        let id: UUID, title: String, goal: String, requirements: String, stop_conditions: [String], source_ids: [UUID]
        let state: DelegationState, health: String, next_check_at: Double?
    }
    public struct EpochDTO: Decodable, Sendable { let scope_kind: MemoryScopeKind, scope_id: UUID, epoch: Int }
    public struct RunDTO: Decodable, Sendable {
        let id: UUID, delegation_id: UUID, delegation_revision: Int, task_id: UUID, conversation_id: UUID, operation_id: UUID
        let trigger_event_ids: [String], state: WorkState, reality: ExecutionReality, artifact_ids: [UUID], context_epochs: [EpochDTO]
        let result_reference: ReferenceDTO?
    }
    public struct ReferenceDTO: Decodable, Sendable { let artifact_id: UUID, version: Int, content_hash: String }
    public struct VersionDTO: Decodable, Sendable { let version: Int, content_hash: String, body: String, generated_from_run_id: UUID }
    public struct ArtifactDTO: Decodable, Sendable {
        let id: UUID, delegation_id: UUID, title: String, kind: String, document_id: UUID, versions: [VersionDTO]
        let current_reference: ReferenceDTO, state: ArtifactState, generated_from_run_id: UUID, evidence_ids: [UUID]
    }
    public struct SourceDTO: Decodable, Sendable { let id: UUID, delegation_id: UUID, url: String, allowed: Bool, revision: Int }
    public struct MemoryDTO: Decodable, Sendable {
        let id: UUID, delegation_id: UUID, content: String, source_message_id: String, status: MemoryStatus, deletion_epoch: Int
    }
    public let schema_version: Int
    public let mode: String
    public let sync_cursor: Int64
    public let scope: GatewayScope
    let delegations: [DelegationDTO], runs: [RunDTO], artifacts: [ArtifactDTO], sources: [SourceDTO], memories: [MemoryDTO]
}

// Mirrors the authoritative service into existing Delegation/AssistantRun/WorkTask/Document/Artifact records.
// One Repository commit advances the cursor and all relationships. No second native history/store is created.
public struct GatewayAssistantImporter: Sendable {
    private struct Checkpoint: Codable { let cursor: Int64, fingerprint: String, payloadHashes: [String: String] }
    public let repository: Repository
    public let blobs: BlobStore
    public let serverID: String
    public static func owns(_ id: UUID, snapshot: StoreSnapshot, scope: DataScope) -> Bool {
        snapshot.list("preference", scope: scope).contains { record in
            guard case .preference(let value) = record.payload, value.key.hasPrefix("gateway_sync_cursor:"),
                  let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: Data(value.value.utf8)) else { return false }
            return checkpoint.payloadHashes[id.uuidString] != nil
        }
    }
    public init(repository: Repository, blobs: BlobStore, serverID: String = "catpaw.local.gateway.v1") {
        self.repository = repository; self.blobs = blobs; self.serverID = serverID
    }
    @discardableResult public func apply(_ data: Data, expectedScope: DataScope, environmentID: UUID) async throws -> Bool {
        let projection = try JSONDecoder().decode(GatewayAssistantProjection.self, from: data)
        guard projection.schema_version == 1, projection.mode == "local_synthetic", projection.scope.native == expectedScope,
              expectedScope == Profiles.demo, projection.runs.allSatisfy({ $0.reality == .simulated }) else { throw CatpawError.scopeMismatch }
        let snapshot = await repository.read(scope: expectedScope)
        let environment = try await repository.record(environmentID, scope: expectedScope)
        guard case .core(.environment) = environment.payload else { throw CatpawError.missing }
        let cursorID = stableID("gateway-cursor-\(serverID)-\(expectedScope.workspaceID)")
        let fingerprint = bytesHash(data)
        var previousHashes: [String: String] = [:]
        if let record = snapshot.records[cursorID], case .preference(let previous) = record.payload {
            let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(previous.value.utf8))
            previousHashes = checkpoint.payloadHashes
            guard checkpoint.cursor <= projection.sync_cursor else { throw CatpawError.conflict }
            if checkpoint.cursor == projection.sync_cursor {
                guard checkpoint.fingerprint == fingerprint else { throw CatpawError.corrupt("Gateway cursor reused for different bytes.") }
                return false
            }
        }
        var desired: [UUID: Payload] = [:]
        func stage(_ id: UUID, _ payload: Payload) throws {
            guard desired[id] == nil else { throw CatpawError.corrupt("Duplicate gateway entity ID.") }; desired[id] = payload
        }
        for d in projection.delegations {
            let scopeJSON = try JSONEncoder().encode(DelegationRequirements(requirements: d.requirements))
            try stage(d.id, .delegation(Delegation(title: d.title, goal: d.goal, sourceIDs: d.source_ids, scopeJSON: scopeJSON,
                stopConditions: d.stop_conditions, schedule: nil, state: d.state, health: d.health,
                nextCheckAt: d.next_check_at.map { Date(timeIntervalSince1970: $0 / 1000) }, archivedAt: nil, reality: .simulated)))
        }
        for source in projection.sources { try stage(source.id, .source(SourceItem(delegationID: source.delegation_id, url: source.url, revision: source.revision, allowed: source.allowed))) }
        for memory in projection.memories {
            try stage(memory.id, .memory(MemoryItem(kind: "explicit", scopeKind: .delegation, scopeID: memory.delegation_id,
                content: memory.content, sourceReferences: ["gateway-source-message:\(memory.source_message_id)"], sourceUserMessageID: nil,
                status: memory.status, validUntil: nil, supersedes: nil, deletionEpoch: memory.deletion_epoch)))
            if memory.status == .deleted {
                try stage(stableID("gateway-suppression-\(memory.id)"), .suppression(ForgetSuppression(deletedMemoryID: memory.id,
                    scopeKind: .delegation, scopeID: memory.delegation_id, sourceMessageIDs: [], sourceSpanIDs: [memory.source_message_id], lineageIDs: [memory.id],
                    subjectPredicateHMAC: nil, deletionEpoch: memory.deletion_epoch, clearedByNewUserMessageID: nil)))
            }
        }
        for artifact in projection.artifacts {
            let reference = artifact.current_reference
            guard reference.artifact_id == artifact.id, reference.version > 0,
                  artifact.versions.count == reference.version, artifact.versions.enumerated().allSatisfy({ $0.element.version == $0.offset + 1 }),
                  artifact.versions.last?.content_hash == reference.content_hash else { throw CatpawError.corrupt("Invalid artifact version chain.") }
            if let old = snapshot.records[artifact.document_id]?.document {
                guard old.currentVersion <= reference.version else { throw CatpawError.conflict }
            }
            for version in artifact.versions {
                guard textHash(version.body) == version.content_hash else { throw CatpawError.corrupt("Artifact body hash mismatch.") }
                let versionID = stableID("\(artifact.document_id)-v\(version.version)")
                if let old = snapshot.records[versionID] {
                    guard case .core(.documentVersion(let oldVersion)) = old.payload, oldVersion.contentHash == version.content_hash else { throw CatpawError.conflict }
                }
                let blob = try blobs.stage(Data(version.body.utf8))
                try stage(versionID, .core(.documentVersion(DocumentVersion(documentID: artifact.document_id, version: version.version,
                    parentVersion: version.version > 1 ? version.version - 1 : nil, privateBlobReference: blob, contentHash: version.content_hash))))
            }
            try stage(artifact.document_id, .core(.document(Document(title: "\(artifact.title).md", mimeType: "text/markdown", currentVersion: reference.version, ownerIDs: [artifact.delegation_id], sourceKind: "gateway_synthetic"))))
            try stage(artifact.id, .artifact(Artifact(title: artifact.title, kind: artifact.kind,
                currentReference: ArtifactReference(artifactID: artifact.id, version: reference.version, contentHash: reference.content_hash),
                documentReference: DocumentReference(documentID: artifact.document_id, version: reference.version, contentHash: reference.content_hash),
                state: artifact.state, evidenceIDs: artifact.evidence_ids, generatedFromRunID: artifact.generated_from_run_id)))
        }
        let artifactsByID = Dictionary(uniqueKeysWithValues: projection.artifacts.map { ($0.id, $0) })
        for run in projection.runs {
            let refs = try run.artifact_ids.map { id -> DocumentReference in
                guard let a = artifactsByID[id] else { throw CatpawError.corrupt("Missing run artifact.") }
                // The run keeps its exact original reference even after later runs or user edits.
                guard let reference = run.result_reference, reference.artifact_id == id,
                      let v = a.versions.first(where: { $0.version == reference.version && $0.content_hash == reference.content_hash }) else { throw CatpawError.corrupt("Missing frozen run result version.") }
                return DocumentReference(documentID: a.document_id, version: v.version, contentHash: v.content_hash)
            }
            try stage(run.conversation_id, .core(.conversation(Conversation(title: "Gateway 模拟准备", projectID: nil, expertID: nil, skillIDs: [], environmentID: environmentID, archivedAt: nil, draftText: ""))))
            try stage(run.task_id, .core(.task(WorkTask(title: "Gateway 模拟运行", conversationID: run.conversation_id, environmentID: environmentID, operationID: run.operation_id,
                state: run.state, steps: [], results: refs, reality: .simulated))))
            try stage(run.id, .run(AssistantRun(delegationID: run.delegation_id, delegationRevision: run.delegation_revision, taskID: run.task_id,
                triggerEventIDs: run.trigger_event_ids.map { stableID("gateway-trigger-\($0)") }, state: run.state,
                contextEpochs: run.context_epochs.map { ScopedContextEpoch(scopeKind: $0.scope_kind, scopeID: $0.scope_id, epoch: $0.epoch) }, artifactIDs: run.artifact_ids, reality: .simulated)))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let currentHashes = try Dictionary(uniqueKeysWithValues: desired.map { ($0.key.uuidString, bytesHash(try encoder.encode($0.value))) })
        let checkpoint = Checkpoint(cursor: projection.sync_cursor, fingerprint: fingerprint, payloadHashes: currentHashes)
        try stage(cursorID, .preference(Preference(key: "gateway_sync_cursor:\(serverID)", value: String(decoding: try encoder.encode(checkpoint), as: UTF8.self))))
        var mutations: [Mutation] = []
        for id in desired.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let payload = desired[id]!
            if let previous = snapshot.records[id] {
                guard previous.header.deletedAt == nil, previous.payload.kind == payload.kind else { throw CatpawError.conflict }
                if id != cursorID {
                    guard previousHashes[id.uuidString] == bytesHash(try encoder.encode(previous.payload)) else { throw CatpawError.conflict }
                }
                if try encoder.encode(previous.payload) != encoder.encode(payload) { mutations.append(.update(id, previous.header.revision, payload)) }
                else { mutations.append(.requireRevision(id, previous.header.revision)) }
            } else { mutations.append(.create(id, payload)) }
        }
        try await repository.commit(scope: expectedScope, mutations: mutations)
        return true
    }
}
