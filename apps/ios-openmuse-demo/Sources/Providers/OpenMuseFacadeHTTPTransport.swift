import Foundation

// Frozen contract SHA256 08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9.
// This mode is loopback-only, public synthetic auth; never a credential/Intelligence client.
public struct OpenMuseFacadeConfiguration: Sendable {
    public let baseURL: URL
    public let localScope = Profiles.demo
    public let remoteScope = Profiles.user // explicit synthetic-principal mapping, NOT real user authorization
    public init(baseURL: URL = URL(string: "http://127.0.0.1:8796")!) throws {
        guard baseURL.scheme == "http", baseURL.host == "127.0.0.1", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, ["", "/"].contains(baseURL.path),
              let port = baseURL.port, (1...65535).contains(port) else { throw CatpawError.invalid("Facade demo requires an explicit loopback-only origin.") }
        self.baseURL = baseURL
    }
}
public struct OpenMuseFacadeHTTPError: Error, LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let reconciliationRequired: Bool
    public var errorDescription: String? { "Facade HTTP \(status): \(code). Do not blindly resend the original write." }
}
private struct FacadeScope: Decodable { let scope_id: String; let profile_id: UUID; let workspace_id: UUID }
private struct FacadeSupports: Decodable { let task_status_read: Bool; let stable_run_read: Bool; let artifact_versions: Bool; let approval_projection: Bool; let grant_revoke: Bool; let sse_replay: Bool; let external_writes: Bool }
private struct FacadeCapabilities: Decodable { let schema_version: Int; let execution_layer: String; let contract: String; let upstream_commit: String; let allowed_scopes: [FacadeScope]; let supports: FacadeSupports }
private struct FacadeDelegation: Decodable {
    let id: UUID; let revision: Int; let grant_epoch: Int; let state: String; let request_hash: String
    let title: String; let goal: String; let requirements: String; let stop_conditions: [String]; let synthetic_fixture_id: String
}
private struct FacadeDelegationEnvelope: Decodable { let schema_version: Int; let execution_layer: String; let delegation: FacadeDelegation }
private struct FacadeReference: Codable, Equatable { let artifact_id: String; let version: Int; let content_hash: String }
private struct FacadeAttempt: Decodable { let upstream_run_id: String; let started_at: String; let finished_at: String?; let status: String }
private struct FacadeRun: Decodable {
    let id: UUID; let operation_id: UUID; let delegation_id: UUID; let delegation_revision: Int; let grant_epoch: Int
    let task_id: String; let request_hash: String; let state: OpenMuseTaskStatus; let authorization_state: String
    let attempts: [FacadeAttempt]; let artifact_references: [FacadeReference]; let approval_ids: [String]
}
private struct FacadeTask: Decodable { let id: String; let status: OpenMuseTaskStatus; let attempts: Int }
private struct FacadeRunEnvelope: Decodable { let schema_version: Int; let execution_layer: String; let run: FacadeRun; let task: FacadeTask }
private struct FacadeArtifact: Decodable { let artifact_id: String; let version: Int; let content_hash: String; let mime_type: String; let body: String; let run_id: UUID; let task_id: String; let created_at: String }
private struct FacadeArtifactEnvelope: Decodable { let schema_version: Int; let execution_layer: String; let artifact: FacadeArtifact }
private struct FacadeReconciliation: Decodable { let state: String; let can_retry: Bool }
private struct FacadeApproval: Decodable {
    let id: String; let run_id: UUID; let operation_id: UUID; let task_id: String; let delegation_id: UUID
    let delegation_revision: Int; let grant_epoch: Int; let artifact_reference: FacadeReference
    let arguments_hash: String; let upstream_hash: String; let policy: String; let expires_at: String; let action_digest: String
    let status: String; let receipt_status: String; let reconciliation: FacadeReconciliation
}
private struct FacadeApprovalEnvelope: Decodable { let schema_version: Int; let execution_layer: String; let approval: FacadeApproval }
private struct FacadeErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let reconciliation_required: Bool }
    let schema_version: Int; let error: Detail
}

public actor OpenMuseFacadeHTTPTransport: OpenMuseTaskTransport {
    public nonisolated let provenance: OpenMuseProvenance = .localSyntheticFacade
    private let configuration: OpenMuseFacadeConfiguration
    private let http: any GatewayTransport
    private var didCheckCapabilities = false
    private var requests: [String] = []
    public init(configuration: OpenMuseFacadeConfiguration, http: any GatewayTransport = URLSessionGatewayTransport()) { self.configuration = configuration; self.http = http }
    public func requestTrace() -> [String] { requests }
    private func call<T: Decodable>(_ method: String, _ segments: [String], body: [String: Any]? = nil, as: T.Type = T.self) async throws -> T {
        var url = configuration.baseURL
        for segment in segments {
            guard !segment.isEmpty, !segment.contains(where: { "/\\?#\r\n ".contains($0) }), segment.utf8.count <= 512 else { throw CatpawError.invalid("Invalid facade route identity.") }
            url.appendPathComponent(segment)
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("Bearer synthetic-only", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            guard request.httpBody!.count <= 32768 else { throw CatpawError.invalid("Facade request exceeds frozen limit.") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        requests.append("\(method) \(url.path)")
        let response = try await http.open(request); var data = Data()
        for try await chunk in response.chunks {
            data.append(chunk); guard data.count <= 4 * 1024 * 1024 else { throw CatpawError.corrupt("Facade response exceeds client limit.") }
        }
        guard (200...201).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(FacadeErrorEnvelope.self, from: data)
            throw OpenMuseFacadeHTTPError(status: response.statusCode, code: envelope?.error.code ?? "invalid_error_envelope", reconciliationRequired: envelope?.error.reconciliation_required ?? true)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private var scopePath: [String] { ["catpaw", "v1", "scopes", configuration.remoteScope.workspaceID.uuidString.lowercased()] }
    private func checkLayer(_ schema: Int, _ layer: String) throws {
        guard schema == 1, ["facade_inprocess_test_double", "actual_upstream_taskworker_inprocess"].contains(layer) else { throw CatpawError.corrupt("Unrecognized synthetic facade layer/schema; cannot upgrade model reality.") }
    }
    public func inspectCapabilities() async throws {
        let c: FacadeCapabilities = try await call("GET", ["catpaw", "v1", "capabilities"])
        try checkLayer(c.schema_version, c.execution_layer)
        guard c.contract == "catpaw.facade.v1", c.upstream_commit == "1ac68f3909f2478ab6280883f1ab5ea65eb5719d",
              c.allowed_scopes.contains(where: { $0.scope_id == configuration.remoteScope.workspaceID.uuidString.lowercased() && $0.profile_id == configuration.remoteScope.profileID && $0.workspace_id == configuration.remoteScope.workspaceID }),
              c.supports.task_status_read, c.supports.stable_run_read, c.supports.artifact_versions, c.supports.approval_projection,
              c.supports.grant_revoke, !c.supports.sse_replay, !c.supports.external_writes else { throw CatpawError.scopeMismatch }
        didCheckCapabilities = true
    }
    private func checkRequest(_ request: OpenMuseFrozenRequest) async throws {
        try request.validate(); guard request.input.scope == configuration.localScope else { throw CatpawError.scopeMismatch }
        if !didCheckCapabilities { try await inspectCapabilities() }
    }
    private func delegation(_ request: OpenMuseFrozenRequest) async throws -> FacadeDelegation {
        let e: FacadeDelegationEnvelope = try await call("GET", scopePath + ["delegations", request.input.delegationID.uuidString.lowercased()])
        try validateDelegation(e, request); return e.delegation
    }
    private func validateDelegation(_ e: FacadeDelegationEnvelope, _ request: OpenMuseFrozenRequest) throws {
        try checkLayer(e.schema_version, e.execution_layer); let d = e.delegation, r = request.input
        guard d.id == r.delegationID, d.title == r.title, d.goal == r.goal, d.requirements == r.requirements,
              d.stop_conditions == r.stopConditions, d.synthetic_fixture_id == r.syntheticFixture.rawValue,
              d.revision > 0, d.grant_epoch > 0, d.request_hash.count == 64 else { throw CatpawError.corrupt("Frozen delegation content changed.") }
    }
    public func create(_ request: OpenMuseFrozenRequest) async throws -> OpenMuseTaskBinding {
        try await checkRequest(request); let r = request.input
        if r.delegationRevision == 1 && r.grantRevision == 1 {
            let d: FacadeDelegationEnvelope = try await call("POST", scopePath + ["delegations"], body: ["delegation_id": r.delegationID.uuidString.lowercased(), "title": r.title, "goal": r.goal, "requirements": r.requirements, "stop_conditions": r.stopConditions, "synthetic_fixture_id": r.syntheticFixture.rawValue])
            try validateDelegation(d, request)
            guard d.delegation.state == "active", d.delegation.revision == r.delegationRevision, d.delegation.grant_epoch == r.grantRevision else { throw CatpawError.conflict }
        } else {
            let d = try await delegation(request)
            guard d.state == "active", d.revision == r.delegationRevision, d.grant_epoch == r.grantRevision else { throw CatpawError.conflict }
        }
        let e: FacadeRunEnvelope = try await call("POST", scopePath + ["delegations", r.delegationID.uuidString.lowercased(), "runs"], body: ["operation_id": r.operationID.uuidString.lowercased(), "run_id": r.businessRunID.uuidString.lowercased(), "expected_revision": r.delegationRevision, "expected_grant_epoch": r.grantRevision])
        return try binding(e, request)
    }
    private func binding(_ e: FacadeRunEnvelope, _ request: OpenMuseFrozenRequest) throws -> OpenMuseTaskBinding {
        try checkLayer(e.schema_version, e.execution_layer); let v = e.run, r = request.input
        guard v.id == r.businessRunID, v.operation_id == r.operationID, v.delegation_id == r.delegationID,
              v.delegation_revision == r.delegationRevision, v.grant_epoch == r.grantRevision,
              v.task_id == e.task.id, v.request_hash.count == 64,
              ![r.operationID.uuidString.lowercased(), r.businessRunID.uuidString.lowercased()].contains(v.task_id.lowercased()) else { throw CatpawError.scopeMismatch }
        return OpenMuseTaskBinding(request: request, taskID: v.task_id, serverRequestHash: v.request_hash, remoteScope: configuration.remoteScope)
    }
    public func readOriginal(_ request: OpenMuseFrozenRequest, knownTaskID: String?) async throws -> OpenMuseTaskProjection {
        try await checkRequest(request); _ = try await delegation(request)
        let operation: FacadeRunEnvelope = try await call("GET", scopePath + ["operations", request.input.operationID.uuidString.lowercased()])
        let original = try binding(operation, request)
        guard knownTaskID == nil || knownTaskID == original.taskID else { throw CatpawError.scopeMismatch }
        let e: FacadeRunEnvelope = try await call("GET", scopePath + ["runs", request.input.businessRunID.uuidString.lowercased()])
        let b = try binding(e, request); guard b == original else { throw CatpawError.conflict }
        var projection = OpenMuseTaskProjection(binding: b, revision: 0, status: e.run.state, attempts: e.task.attempts)
        projection.hasAuthoritativeRevision = false; projection.executionLayer = e.execution_layer
        projection.authorizationCurrent = e.run.authorization_state == "current"
        projection.grantRevision = e.run.grant_epoch; projection.contextEpoch = request.input.contextEpoch
        projection.workerAttempts = e.run.attempts.map { OpenMuseWorkerAttempt(upstreamRunID: $0.upstream_run_id, startedAt: $0.started_at, finishedAt: $0.finished_at, status: $0.status) }
        projection.workerRunID = e.run.attempts.last?.upstream_run_id
        guard projection.authorizationCurrent else { return projection }
        guard e.run.artifact_references.count <= 32, e.run.approval_ids.count <= 32 else { throw CatpawError.corrupt("Run references exceed read budget.") }
        for ref in e.run.artifact_references {
            guard (1...128).contains(ref.version) else { throw CatpawError.corrupt("Artifact history requires a paginated contract.") }
            for version in 1...ref.version {
                let a: FacadeArtifactEnvelope = try await call("GET", scopePath + ["artifacts", ref.artifact_id, "versions", String(version)])
                try checkLayer(a.schema_version, a.execution_layer)
                guard a.artifact.artifact_id == ref.artifact_id, a.artifact.version == version, a.artifact.run_id == request.input.businessRunID,
                      a.artifact.task_id == b.taskID, a.artifact.mime_type == "application/json",
                      version != ref.version || a.artifact.content_hash == ref.content_hash else { throw CatpawError.corrupt("Artifact reference changed.") }
                let reference = OpenMuseArtifactReference(artifactID: ref.artifact_id, version: version, contentHash: a.artifact.content_hash)
                let object = try JSONSerialization.jsonObject(with: Data(a.artifact.body.utf8)) as? [String: Any]
                let title = object?["title"] as? String ?? "合成成果"
                let value = OpenMuseArtifactVersion(taskID: b.taskID, reference: reference, title: title, body: a.artifact.body)
                try value.validate(taskID: b.taskID); projection.artifacts.append(value)
            }
        }
        for id in e.run.approval_ids {
            let approval = try await approvalEnvelope(request, id)
            let frozen = try snapshot(approval.approval, request: request, binding: b)
            projection.approvals.append(frozen)
            if approval.approval.receipt_status != "not_started" { projection.approvalReceipts.append(try receipt(approval.approval, expected: frozen)) }
        }
        let final: FacadeRunEnvelope = try await call("GET", scopePath + ["runs", request.input.businessRunID.uuidString.lowercased()])
        guard try binding(final, request) == b, final.run.authorization_state == "current" else { throw CatpawError.scopeMismatch }
        guard final.run.artifact_references == e.run.artifact_references,
              final.run.approval_ids == e.run.approval_ids else { throw OpenMuseSnapshotReadChanged() }
        projection.status = final.run.state; projection.attempts = final.task.attempts
        projection.workerAttempts = final.run.attempts.map { OpenMuseWorkerAttempt(upstreamRunID: $0.upstream_run_id, startedAt: $0.started_at, finishedAt: $0.finished_at, status: $0.status) }
        projection.workerRunID = final.run.attempts.last?.upstream_run_id; return projection
    }
    public func control(_ request: OpenMuseFrozenRequest, knownTaskID: String?, command: OpenMuseControlCommand, expectedRevision: Int, expectedGrantEpoch: Int) async throws -> OpenMuseControlReceipt {
        try await checkRequest(request)
        let d = try await delegation(request)
        guard d.revision == expectedRevision, d.grant_epoch == expectedGrantEpoch, let taskID = knownTaskID else { throw CatpawError.conflict }
        let e: FacadeDelegationEnvelope = try await call("POST", scopePath + ["delegations", request.input.delegationID.uuidString.lowercased(), "control"], body: ["action": command.rawValue, "expected_revision": expectedRevision, "expected_grant_epoch": expectedGrantEpoch])
        try validateDelegation(e, request)
        guard let state = OpenMuseLocalControl(rawValue: e.delegation.state) else { throw CatpawError.corrupt("Invalid delegation state.") }
        return OpenMuseControlReceipt(binding: OpenMuseTaskBinding(request: request, taskID: taskID), control: state,
                                     grantRevision: e.delegation.grant_epoch, contextEpoch: e.delegation.grant_epoch,
                                     delegationRevision: e.delegation.revision, requiresNewRun: command == .resume)
    }
    private func approvalEnvelope(_ request: OpenMuseFrozenRequest, _ id: String) async throws -> FacadeApprovalEnvelope {
        let e: FacadeApprovalEnvelope = try await call("GET", scopePath + ["approvals", id]); try checkLayer(e.schema_version, e.execution_layer)
        guard e.approval.id == id, !e.approval.reconciliation.can_retry else { throw CatpawError.corrupt("Unexpected approval replay permission.") }
        return e
    }
    private func snapshot(_ a: FacadeApproval, request: OpenMuseFrozenRequest, binding: OpenMuseTaskBinding) throws -> OpenMuseApprovalSnapshot {
        guard a.run_id == request.input.businessRunID, a.operation_id == request.input.operationID, a.task_id == binding.taskID,
              a.delegation_id == request.input.delegationID, a.delegation_revision == request.input.delegationRevision,
              a.grant_epoch == request.input.grantRevision, a.policy == "synthetic-only-v1" else { throw CatpawError.scopeMismatch }
        let arguments: [String: Any] = ["artifactId": a.artifact_reference.artifact_id, "version": a.artifact_reference.version, "contentHash": a.artifact_reference.content_hash, "title": "Synthetic preview only"]
        let args = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytesHash(args) == a.arguments_hash else { throw CatpawError.corrupt("Synthetic preview arguments hash mismatch.") }
        let core: [String: Any] = ["id": a.id, "run_id": a.run_id.uuidString.lowercased(), "operation_id": a.operation_id.uuidString.lowercased(), "task_id": a.task_id,
                                  "delegation_id": a.delegation_id.uuidString.lowercased(), "delegation_revision": a.delegation_revision, "grant_epoch": a.grant_epoch,
                                  "artifact_reference": ["artifact_id": a.artifact_reference.artifact_id, "version": a.artifact_reference.version, "content_hash": a.artifact_reference.content_hash],
                                  "arguments_hash": a.arguments_hash, "upstream_hash": a.upstream_hash, "policy": a.policy, "expires_at": a.expires_at]
        let coreBytes = try JSONSerialization.data(withJSONObject: core, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytesHash(coreBytes) == a.action_digest, let expiry = Self.date(a.expires_at) else { throw CatpawError.corrupt("Facade action digest/date mismatch.") }
        return OpenMuseApprovalSnapshot(proposalID: a.id, binding: binding,
            artifact: OpenMuseArtifactReference(artifactID: a.artifact_reference.artifact_id, version: a.artifact_reference.version, contentHash: a.artifact_reference.content_hash),
            destination: "本机合成预览", toolID: "catpaw.preview", argumentsJSON: String(decoding: args, as: UTF8.self),
            grantID: request.input.grantID, grantRevision: a.grant_epoch, contextEpoch: request.input.contextEpoch,
            serverHash: a.upstream_hash, serverActionDigest: a.action_digest, expiresAt: expiry, effectClass: "synthetic_preview",
            wireActionBindingJSON: String(decoding: coreBytes, as: UTF8.self))
    }
    private static func date(_ string: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: string) { return date }; f.formatOptions = [.withInternetDateTime]; return f.date(from: string)
    }
    public func readApproval(_ request: OpenMuseFrozenRequest, taskID: String, proposalID: String) async throws -> OpenMuseApprovalSnapshot {
        try await checkRequest(request); let e = try await approvalEnvelope(request, proposalID)
        guard e.approval.status == "awaiting_review", e.approval.receipt_status == "not_started" else { throw CatpawError.invalid("Original approval is consumed or unknown; only receipt reads are allowed.") }
        let original: FacadeRunEnvelope = try await call("GET", scopePath + ["operations", request.input.operationID.uuidString.lowercased()])
        let originalBinding = try binding(original, request)
        guard originalBinding.taskID == taskID, original.run.authorization_state == "current" else { throw CatpawError.scopeMismatch }
        return try snapshot(e.approval, request: request, binding: originalBinding)
    }
    public func decide(_ preview: OpenMuseApprovalPreview, decision: OpenMuseDecision) async throws -> OpenMuseDecisionReceipt {
        let a = preview.snapshot
        guard a.binding.scope == configuration.localScope, a.toolID == "catpaw.preview", a.effectClass == "synthetic_preview",
              let core = a.wireActionBindingJSON, textHash(core) == a.serverActionDigest else { throw CatpawError.invalid("Only frozen local synthetic preview is permitted.") }
        let e: FacadeApprovalEnvelope = try await call("POST", scopePath + ["approvals", a.proposalID, "decisions"], body: ["decision": decision.rawValue, "upstream_hash": a.serverHash, "action_digest": a.serverActionDigest, "expected_grant_epoch": a.grantRevision])
        try checkLayer(e.schema_version, e.execution_layer)
        return try receipt(e.approval, expected: a)
    }
    public func readReceipt(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt {
        try await checkRequest(request); let e = try await approvalEnvelope(request, approval.proposalID)
        return try receipt(e.approval, expected: approval)
    }
    public func checkReceiptEvidence(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt {
        try await checkRequest(request)
        let e: FacadeApprovalEnvelope = try await call("POST", scopePath + ["approvals", approval.proposalID, "reconciliation-checks"], body: [:])
        try checkLayer(e.schema_version, e.execution_layer); return try receipt(e.approval, expected: approval)
    }
    private func receipt(_ a: FacadeApproval, expected: OpenMuseApprovalSnapshot) throws -> OpenMuseDecisionReceipt {
        guard a.id == expected.proposalID, a.action_digest == expected.serverActionDigest, a.upstream_hash == expected.serverHash,
              a.run_id == expected.binding.businessRunID, a.operation_id == expected.binding.operationID,
              a.task_id == expected.binding.taskID, a.grant_epoch == expected.grantRevision, !a.reconciliation.can_retry else { throw CatpawError.scopeMismatch }
        let state: OpenMuseDecisionState
        switch a.receipt_status { case "accepted": state = .accepted; case "unknown": state = .unknown; case "cancelled_before_dispatch": state = .denied; default: throw CatpawError.invalid("Original receipt has not been dispatched; do not infer permission to retry.") }
        return OpenMuseDecisionReceipt(binding: expected.binding, proposalID: a.id, serverActionDigest: a.action_digest,
                                       status: state, providerStatus: a.status, verificationEvidence: ["synthetic-local-projection:\(a.reconciliation.state)"])
    }
}
