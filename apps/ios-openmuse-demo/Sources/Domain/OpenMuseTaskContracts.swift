import Foundation

public struct OpenMuseSnapshotReadChanged: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "Task references changed during the multi-GET read. Read the original task again; no write is repeated." }
}
public struct OpenMuseReadBudgetExhausted: Error, LocalizedError, Sendable {
    public let attemptedReads: Int
    public init(attemptedReads: Int) { self.attemptedReads = attemptedReads }
    public var errorDescription: String? { "Original task read did not stabilize after \(attemptedReads) attempts. The last checked record is retained. Use Read original task again; no admission or approval was resent." }
}

// Semantic client types. These are NOT an invented OpenMuse/facade HTTP schema.
public enum OpenMuseProvenance: String, Codable, Sendable {
    case fixtureTransport = "pure_fixture_transport"
    case localSyntheticFacade = "local_synthetic_facade"
    case cloudIntelligence = "cloud_intelligence_model_unverified"
}
public enum OpenMuseSyntheticFixture: String, Codable, Sendable { case report, preview, previewUnknown = "preview_unknown" }
public struct OpenMuseTaskInput: Codable, Sendable {
    public let scope: DataScope
    public let operationID: UUID
    public let businessRunID: UUID
    public let delegationID: UUID
    public let delegationRevision: Int
    public let environmentID: UUID
    public let grantID: String
    public let grantRevision: Int
    public let contextEpoch: Int
    public let title: String
    public let goal: String
    public let requirements: String
    public let stopConditions: [String]
    public let syntheticDataOnly: Bool
    public let syntheticFixture: OpenMuseSyntheticFixture
    public init(scope: DataScope, operationID: UUID = UUID(), businessRunID: UUID = UUID(), delegationID: UUID = UUID(),
                delegationRevision: Int = 1, environmentID: UUID, grantID: String = "synthetic-demo-only", grantRevision: Int = 1,
                contextEpoch: Int = 1, title: String, goal: String, requirements: String = "仅合成数据", stopConditions: [String] = ["产出合成摘要后停止"], syntheticDataOnly: Bool = true, syntheticFixture: OpenMuseSyntheticFixture = .previewUnknown) {
        self.scope = scope; self.operationID = operationID; self.businessRunID = businessRunID; self.delegationID = delegationID
        self.delegationRevision = delegationRevision; self.environmentID = environmentID; self.grantID = grantID
        self.grantRevision = grantRevision; self.contextEpoch = contextEpoch; self.title = title; self.goal = goal
        self.requirements = requirements; self.stopConditions = stopConditions; self.syntheticDataOnly = syntheticDataOnly
        self.syntheticFixture = syntheticFixture
    }
}
public struct OpenMuseFrozenRequest: Codable, Sendable {
    public let input: OpenMuseTaskInput
    public let requestHash: String
    public init(_ input: OpenMuseTaskInput) throws {
        guard input.syntheticDataOnly, input.scope == Profiles.demo, input.delegationRevision > 0,
              input.grantRevision > 0, input.contextEpoch > 0, !input.grantID.isEmpty,
              !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.title.utf16.count <= 160, input.goal.utf16.count <= 4000, input.requirements.utf16.count <= 4000,
              !input.stopConditions.isEmpty, input.stopConditions.count <= 10, input.stopConditions.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 300 }),
              Set([input.operationID, input.businessRunID, input.delegationID]).count == 3 else {
            throw CatpawError.invalid("OpenMuse demo requires distinct identities, a frozen grant and synthetic demo scope.")
        }
        self.input = input; requestHash = try openMuseDigest(input)
    }
    public func validate() throws {
        guard requestHash == (try openMuseDigest(input)) else { throw CatpawError.corrupt("OpenMuse frozen request changed.") }
        _ = try OpenMuseFrozenRequest(input)
    }
}
public func openMuseDigest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return bytesHash(try encoder.encode(value))
}
public enum OpenMuseAdmissionState: String, Codable, Sendable { case notSent, dispatchCommitted, accepted, unknown }
public enum OpenMuseLocalControl: String, Codable, Sendable { case active, paused, revoked }
public enum OpenMuseControlCommand: String, Codable, Sendable { case pause, resume, revoke }
public struct OpenMuseControlReceipt: Sendable {
    public let binding: OpenMuseTaskBinding
    public let control: OpenMuseLocalControl
    public let grantRevision: Int
    public let contextEpoch: Int
    public let delegationRevision: Int
    public let requiresNewRun: Bool
    public init(binding: OpenMuseTaskBinding, control: OpenMuseLocalControl, grantRevision: Int, contextEpoch: Int, delegationRevision: Int = 1, requiresNewRun: Bool = false) {
        self.binding = binding; self.control = control; self.grantRevision = grantRevision; self.contextEpoch = contextEpoch
        self.delegationRevision = delegationRevision; self.requiresNewRun = requiresNewRun
    }
}
public struct OpenMuseTaskBinding: Codable, Hashable, Sendable {
    public let scope: DataScope
    public let operationID: UUID
    public let businessRunID: UUID
    public let requestHash: String
    public let taskID: String
    public let serverRequestHash: String?
    public let remoteScope: DataScope?
    public init(request: OpenMuseFrozenRequest, taskID: String, serverRequestHash: String? = nil, remoteScope: DataScope? = nil) {
        scope = request.input.scope; operationID = request.input.operationID; businessRunID = request.input.businessRunID
        requestHash = request.requestHash; self.taskID = taskID
        self.serverRequestHash = serverRequestHash; self.remoteScope = remoteScope
    }
    public func validate(_ request: OpenMuseFrozenRequest) throws {
        guard scope == request.input.scope, operationID == request.input.operationID, businessRunID == request.input.businessRunID,
              requestHash == request.requestHash, !taskID.isEmpty, taskID.utf8.count <= 512 else { throw CatpawError.scopeMismatch }
    }
}
public enum OpenMuseTaskStatus: String, Codable, Sendable {
    case queued, running, waitingApproval = "waiting_approval", waitingInput = "waiting_input", outcomeUnknown = "outcome_unknown", scheduled, paused, succeeded, failed, cancelled
    public var terminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }
}
public struct OpenMuseWorkerAttempt: Codable, Equatable, Sendable {
    public let upstreamRunID: String
    public let startedAt: String
    public let finishedAt: String?
    public let status: String
    public init(upstreamRunID: String, startedAt: String, finishedAt: String?, status: String) {
        self.upstreamRunID = upstreamRunID; self.startedAt = startedAt; self.finishedAt = finishedAt; self.status = status
    }
}
public struct OpenMuseTaskProjection: Codable, Sendable {
    public var binding: OpenMuseTaskBinding
    public var revision: Int
    public var status: OpenMuseTaskStatus
    public var attempts: Int
    public var workerRunID: String?
    public var grantRevision: Int = 1
    public var contextEpoch: Int = 1
    public var artifacts: [OpenMuseArtifactVersion] = []
    public var approvals: [OpenMuseApprovalSnapshot] = []
    public var hasAuthoritativeRevision = true // false for the frozen facade, which supplies no snapshot revision
    public var workerAttempts: [OpenMuseWorkerAttempt] = []
    public var executionLayer: String?
    public var authorizationCurrent = true
    public var approvalReceipts: [OpenMuseDecisionReceipt] = []
    public init(binding: OpenMuseTaskBinding, revision: Int, status: OpenMuseTaskStatus, attempts: Int = 1, workerRunID: String? = nil) {
        self.binding = binding; self.revision = revision; self.status = status; self.attempts = attempts; self.workerRunID = workerRunID
    }
}
public struct OpenMuseArtifactReference: Codable, Hashable, Sendable {
    public let artifactID: String
    public let version: Int
    public let contentHash: String
    public init(artifactID: String, version: Int, contentHash: String) { self.artifactID = artifactID; self.version = version; self.contentHash = contentHash }
}
public struct OpenMuseArtifactVersion: Codable, Equatable, Sendable {
    public let taskID: String
    public let reference: OpenMuseArtifactReference
    public let title: String
    public let body: String
    public init(taskID: String, reference: OpenMuseArtifactReference, title: String, body: String) {
        self.taskID = taskID; self.reference = reference; self.title = title; self.body = body
    }
    public func validate(taskID: String) throws {
        guard self.taskID == taskID, !reference.artifactID.isEmpty, reference.version > 0,
              reference.contentHash == textHash(body), body.utf8.count <= 1024 * 1024 else { throw CatpawError.corrupt("Artifact version/body/hash mismatch.") }
    }
}
public struct OpenMuseApprovalSnapshot: Codable, Sendable {
    public let proposalID: String
    public let binding: OpenMuseTaskBinding
    public let artifact: OpenMuseArtifactReference
    public let destination: String
    public let toolID: String
    public let toolVersion: String
    public let effectClass: String
    public let argumentsJSON: String
    public let argumentsHash: String
    public let grantID: String
    public let grantRevision: Int
    public let contextEpoch: Int
    public let policyVersion: String
    public let serverHash: String
    public let serverActionDigest: String
    public let expiresAt: Date
    public let wireActionBindingJSON: String?
    public init(proposalID: String, binding: OpenMuseTaskBinding, artifact: OpenMuseArtifactReference, destination: String,
                toolID: String = "synthetic.noop", toolVersion: String = "1", argumentsJSON: String = "{}",
                grantID: String, grantRevision: Int, contextEpoch: Int, serverHash: String, serverActionDigest: String, expiresAt: Date,
                effectClass: String = "synthetic_noop", policyVersion: String = "synthetic-only-v1", wireActionBindingJSON: String? = nil) {
        self.proposalID = proposalID; self.binding = binding; self.artifact = artifact; self.destination = destination
        self.toolID = toolID; self.toolVersion = toolVersion; self.effectClass = effectClass; self.argumentsJSON = argumentsJSON
        argumentsHash = textHash(argumentsJSON); self.grantID = grantID; self.grantRevision = grantRevision; self.contextEpoch = contextEpoch
        self.policyVersion = policyVersion; self.serverHash = serverHash; self.serverActionDigest = serverActionDigest; self.expiresAt = expiresAt
        self.wireActionBindingJSON = wireActionBindingJSON
    }
}
public enum OpenMuseDecisionState: String, Codable, Sendable { case pending, dispatchCommitted, accepted, unknown, denied, invalidated }
public enum OpenMuseDecision: String, Codable, Sendable { case approve, deny }
public struct OpenMuseApprovalJournal: Codable, Sendable {
    public let snapshot: OpenMuseApprovalSnapshot
    public var state: OpenMuseDecisionState = .pending
    public var receipt: OpenMuseDecisionReceipt?
    public var decision: OpenMuseDecision?
    public init(snapshot: OpenMuseApprovalSnapshot) { self.snapshot = snapshot }
}
public struct OpenMuseApprovalPreview: Codable, Sendable {
    public let snapshot: OpenMuseApprovalSnapshot
    public let artifact: OpenMuseArtifactVersion
    public let observationEpoch: Int
    public let snapshotDigest: String
    public init(snapshot: OpenMuseApprovalSnapshot, artifact: OpenMuseArtifactVersion, observationEpoch: Int) throws {
        self.snapshot = snapshot; self.artifact = artifact; self.observationEpoch = observationEpoch; snapshotDigest = try openMuseDigest(snapshot)
    }
}
public struct OpenMuseDecisionReceipt: Codable, Sendable {
    public let binding: OpenMuseTaskBinding
    public let proposalID: String
    public let serverActionDigest: String
    public let status: OpenMuseDecisionState
    public let providerStatus: String
    public let verificationEvidence: [String]
    public init(binding: OpenMuseTaskBinding, proposalID: String, serverActionDigest: String, status: OpenMuseDecisionState, providerStatus: String, verificationEvidence: [String] = []) {
        self.binding = binding; self.proposalID = proposalID; self.serverActionDigest = serverActionDigest; self.status = status; self.providerStatus = providerStatus; self.verificationEvidence = verificationEvidence
    }
}
public struct OpenMuseEphemeralEvent: Sendable {
    public let type: String
    public let threadID: String?
    public let aguiRunID: String?
    public let delta: String?
    public init(type: String, threadID: String? = nil, aguiRunID: String? = nil, delta: String? = nil) {
        self.type = type; self.threadID = threadID; self.aguiRunID = aguiRunID; self.delta = delta
    }
}
public struct OpenMuseEphemeralObservation: Codable, Sendable {
    public let threadID: String
    public let aguiRunID: String
    public var advisoryText = ""
    public var terminal = false
    public var sawToolProposal = false
    public var unsupportedEventTypes: [String] = []
    public init(threadID: String, aguiRunID: String) { self.threadID = threadID; self.aguiRunID = aguiRunID }
}
public struct OpenMuseTaskSession: Codable, Sendable {
    public let request: OpenMuseFrozenRequest
    public let provenance: OpenMuseProvenance
    public var admission: OpenMuseAdmissionState = .notSent
    public var serverTaskID: String?
    public var observationEpoch = 1
    public var control: OpenMuseLocalControl = .active
    public var needsRead = false
    public var note: String?
    public var readGeneration = 0
    public var projection: OpenMuseTaskProjection?
    public var projectionHash: String?
    public var observedWorkerRunID: String?
    public var grantRevision: Int
    public var contextEpoch: Int
    public var serverControlConfirmed = false
    public var artifactHistory: [OpenMuseArtifactVersion] = []
    public var approvals: [String: OpenMuseApprovalJournal] = [:]
    public var ephemeral: OpenMuseEphemeralObservation?
    public var delegationRevision: Int
    public var resumeRequiresNewRun = false
    public var nextRunOperationID: UUID?
    public init(request: OpenMuseFrozenRequest, provenance: OpenMuseProvenance) {
        self.request = request; self.provenance = provenance; grantRevision = request.input.grantRevision; contextEpoch = request.input.contextEpoch
        delegationRevision = request.input.delegationRevision
    }
}
