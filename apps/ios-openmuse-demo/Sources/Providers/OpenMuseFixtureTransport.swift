import Foundation

// Clearly named deterministic test peer, no scheduler, worker, network, tool executor or real model.
// Its own optional disk file is separate from the client Repository, allowing fixture-only App restart checks.
public actor OpenMuseFixtureTransport: OpenMuseTaskTransport {
    public nonisolated let provenance: OpenMuseProvenance = .fixtureTransport
    private struct FixtureRecord: Codable {
        var request: OpenMuseFrozenRequest
        var projection: OpenMuseTaskProjection
        var delegationRevision: Int
        var grantEpoch: Int
        var delegationState: OpenMuseLocalControl
    }
    private let stateURL: URL?
    private var records: [String: FixtureRecord]
    public init(stateURL: URL? = nil) throws {
        self.stateURL = stateURL
        if let url = stateURL, FileManager.default.fileExists(atPath: url.path) {
            records = try JSONDecoder().decode([String: FixtureRecord].self, from: Data(contentsOf: url))
        } else { records = [:] }
    }
    private func commit(_ candidate: [String: FixtureRecord]) throws {
        if let stateURL {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(candidate).write(to: stateURL, options: .atomic)
        }
        records = candidate
    }
    public func create(_ request: OpenMuseFrozenRequest) async throws -> OpenMuseTaskBinding {
        try request.validate()
        guard records[request.requestHash] == nil else { throw CatpawError.invalid("Fixture original task already exists; read it instead of creating again.") }
        let related = records.values.filter { $0.request.input.delegationID == request.input.delegationID }
        guard related.allSatisfy({ $0.delegationState == .active && $0.delegationRevision == request.input.delegationRevision && $0.grantEpoch == request.input.grantRevision }),
              !related.isEmpty || (request.input.delegationRevision == 1 && request.input.grantRevision == 1) else { throw CatpawError.conflict }
        let task = "fixture-task-\(request.input.operationID.uuidString.lowercased())"
        let binding = OpenMuseTaskBinding(request: request, taskID: task)
        let body = "合成资料摘要\nAlpha synthetic record\nBeta synthetic record\n具名fixture，没有运行OpenMuse、Intelligence或真实模型。"
        let reference = OpenMuseArtifactReference(artifactID: "fixture-artifact-\(task)", version: 1, contentHash: textHash(body))
        var projection = OpenMuseTaskProjection(binding: binding, revision: 1, status: request.input.syntheticFixture == .report ? .succeeded : .waitingApproval,
                                                workerRunID: "fixture-worker-\(UUID().uuidString)")
        projection.grantRevision = request.input.grantRevision; projection.contextEpoch = request.input.contextEpoch
        projection.artifacts = [OpenMuseArtifactVersion(taskID: task, reference: reference, title: "合成资料摘要", body: body)]
        if request.input.syntheticFixture != .report {
            let id = "fixture-approval-\(task)"
            projection.approvals = [OpenMuseApprovalSnapshot(proposalID: id, binding: binding, artifact: reference, destination: "本机合成预览",
                grantID: request.input.grantID, grantRevision: request.input.grantRevision, contextEpoch: request.input.contextEpoch,
                serverHash: textHash("fixture-proposal:\(id)"), serverActionDigest: textHash("fixture-action:\(request.requestHash):\(reference.contentHash)"), expiresAt: Date().addingTimeInterval(1800))]
        }
        var candidate = records
        candidate[request.requestHash] = FixtureRecord(request: request, projection: projection, delegationRevision: request.input.delegationRevision,
            grantEpoch: request.input.grantRevision, delegationState: .active)
        try commit(candidate); return binding
    }
    private func record(_ request: OpenMuseFrozenRequest, knownTaskID: String? = nil) throws -> FixtureRecord {
        try request.validate()
        guard let value = records[request.requestHash], knownTaskID == nil || knownTaskID == value.projection.binding.taskID else { throw CatpawError.missing }
        return value
    }
    public func readOriginal(_ request: OpenMuseFrozenRequest, knownTaskID: String?) async throws -> OpenMuseTaskProjection {
        let value = try record(request, knownTaskID: knownTaskID)
        var projection = value.projection
        projection.authorizationCurrent = value.delegationState == .active && value.grantEpoch == request.input.grantRevision && value.delegationRevision == request.input.delegationRevision
        return projection
    }
    public func control(_ request: OpenMuseFrozenRequest, knownTaskID: String?, command: OpenMuseControlCommand, expectedRevision: Int, expectedGrantEpoch: Int) async throws -> OpenMuseControlReceipt {
        let value = try record(request, knownTaskID: knownTaskID)
        guard value.delegationRevision == expectedRevision, value.grantEpoch == expectedGrantEpoch, value.delegationState != .revoked,
              command == .resume || value.delegationState == .active,
              command != .resume || value.delegationState == .paused else { throw CatpawError.conflict }
        let control: OpenMuseLocalControl = command == .pause ? .paused : command == .resume ? .active : .revoked
        var candidate = records
        for (key, stored) in records where stored.request.input.delegationID == request.input.delegationID {
            var updated = stored; updated.delegationRevision = expectedRevision + 1; updated.grantEpoch = expectedGrantEpoch + 1; updated.delegationState = control
            updated.projection.revision += 1; updated.projection.status = command == .revoke ? .cancelled : .paused
            updated.projection.authorizationCurrent = false; candidate[key] = updated
        }
        try commit(candidate)
        return OpenMuseControlReceipt(binding: value.projection.binding, control: control, grantRevision: expectedGrantEpoch + 1,
            contextEpoch: expectedGrantEpoch + 1, delegationRevision: expectedRevision + 1, requiresNewRun: command == .resume)
    }
    public func readApproval(_ request: OpenMuseFrozenRequest, taskID: String, proposalID: String) async throws -> OpenMuseApprovalSnapshot {
        let value = try record(request, knownTaskID: taskID)
        guard value.delegationState == .active, let snapshot = value.projection.approvals.first(where: { $0.proposalID == proposalID }),
              value.grantEpoch == snapshot.grantRevision, value.delegationRevision == request.input.delegationRevision,
              !value.projection.approvalReceipts.contains(where: { $0.proposalID == proposalID }) else { throw CatpawError.invalid("Fixture proposal is no longer pending.") }
        return snapshot
    }
    public func decide(_ preview: OpenMuseApprovalPreview, decision: OpenMuseDecision) async throws -> OpenMuseDecisionReceipt {
        let key = preview.snapshot.binding.requestHash
        guard var value = records[key], value.delegationState == .active, value.grantEpoch == preview.snapshot.grantRevision,
              let snapshot = value.projection.approvals.first(where: { $0.proposalID == preview.snapshot.proposalID }),
              try openMuseDigest(snapshot) == preview.snapshotDigest,
              !value.projection.approvalReceipts.contains(where: { $0.proposalID == snapshot.proposalID }) else { throw CatpawError.conflict }
        let state: OpenMuseDecisionState = decision == .deny ? .denied : value.request.input.syntheticFixture == .previewUnknown ? .unknown : .accepted
        let receipt = OpenMuseDecisionReceipt(binding: snapshot.binding, proposalID: snapshot.proposalID, serverActionDigest: snapshot.serverActionDigest,
            status: state, providerStatus: state == .unknown ? "synthetic_outcome_unknown" : state == .denied ? "synthetic_denied" : "synthetic_succeeded")
        value.projection.approvalReceipts.append(receipt); value.projection.revision += 1
        value.projection.status = state == .unknown ? .outcomeUnknown : .succeeded
        var candidate = records; candidate[key] = value; try commit(candidate); return receipt
    }
    public func readReceipt(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt {
        let value = try record(request, knownTaskID: approval.binding.taskID)
        guard let receipt = value.projection.approvalReceipts.first(where: { $0.proposalID == approval.proposalID }) else { throw CatpawError.missing }
        return receipt
    }
    public func checkReceiptEvidence(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt {
        let original = try await readReceipt(request, approval: approval)
        return OpenMuseDecisionReceipt(binding: original.binding, proposalID: original.proposalID, serverActionDigest: original.serverActionDigest,
            status: original.status, providerStatus: original.providerStatus, verificationEvidence: ["pure-fixture-local-marker; no independent verification"])
    }
}
