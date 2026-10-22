// cat assistant-domain contract v0.1. Compile alongside catpaw-ios-contracts.swift.
// Design reference only; no runtime or backend implementation is included.
import Foundation

public enum DelegationState: String, Codable, Sendable {
    case draft, active, paused, completed, cancelled, expired
}
public enum ArtifactState: String, Codable, Sendable {
    case draft, ready, stale, superseded, withdrawn
}
public enum MemoryScopeKind: String, Codable, Sendable {
    case run, delegation, project, user
}
public enum MemoryStatus: String, Codable, Sendable {
    case candidate, active, superseded, disputed, expired, deleted
}
public enum ApprovalStatus: String, Codable, Sendable {
    case pending, approved, rejected, expired, invalidated, consumed, revoked
}
public enum ReceiptStatus: String, Codable, Sendable {
    case notStarted = "not_started"
    case reserved
    case dispatchCommitted = "dispatch_committed"
    case accepted, verified
    case failedDefinite = "failed_definite"
    case unknown
    case cancelledBeforeDispatch = "cancelled_before_dispatch"
    case cancelledBeforeTransport = "cancelled_before_transport"
}
public struct ScopedContextEpoch: Codable, Sendable {
    public var scopeKind: MemoryScopeKind
    public var scopeID: EntityID
    public var epoch: Int

    public init(
        scopeKind: MemoryScopeKind,
        scopeID: EntityID,
        epoch: Int
    ) {
        self.scopeKind = scopeKind
        self.scopeID = scopeID
        self.epoch = epoch
    }
}
public struct Delegation: Codable, Sendable {
    public var title: String
    public var goal: String
    public var sourceIDs: [EntityID]
    public var scopeJSON: Data
    public var stopConditions: [String]
    public var schedule: ScheduleSpec?
    public var state: DelegationState
    public var health: String
    public var nextCheckAt: Date?
    public var archivedAt: Date?
    public var reality: ExecutionReality

    public init(
        title: String,
        goal: String,
        sourceIDs: [EntityID],
        scopeJSON: Data,
        stopConditions: [String],
        schedule: ScheduleSpec?,
        state: DelegationState,
        health: String,
        nextCheckAt: Date?,
        archivedAt: Date?,
        reality: ExecutionReality
    ) {
        self.title = title
        self.goal = goal
        self.sourceIDs = sourceIDs
        self.scopeJSON = scopeJSON
        self.stopConditions = stopConditions
        self.schedule = schedule
        self.state = state
        self.health = health
        self.nextCheckAt = nextCheckAt
        self.archivedAt = archivedAt
        self.reality = reality
    }
}
public struct AssistantRun: Codable, Sendable {
    public var delegationID: EntityID
    public var delegationRevision: Revision
    public var taskID: EntityID
    public var triggerEventIDs: [EntityID]
    public var state: WorkState
    public var contextEpochs: [ScopedContextEpoch]
    public var artifactIDs: [EntityID]
    public var reality: ExecutionReality

    public init(
        delegationID: EntityID,
        delegationRevision: Revision,
        taskID: EntityID,
        triggerEventIDs: [EntityID],
        state: WorkState,
        contextEpochs: [ScopedContextEpoch],
        artifactIDs: [EntityID],
        reality: ExecutionReality
    ) {
        self.delegationID = delegationID
        self.delegationRevision = delegationRevision
        self.taskID = taskID
        self.triggerEventIDs = triggerEventIDs
        self.state = state
        self.contextEpochs = contextEpochs
        self.artifactIDs = artifactIDs
        self.reality = reality
    }
}
public struct ArtifactReference: Codable, Hashable, Sendable {
    public var artifactID: EntityID
    public var version: Revision
    public var contentHash: String

    public init(
        artifactID: EntityID,
        version: Revision,
        contentHash: String
    ) {
        self.artifactID = artifactID
        self.version = version
        self.contentHash = contentHash
    }
}
public struct Artifact: Codable, Sendable {
    public var title: String
    public var kind: String
    public var currentReference: ArtifactReference
    public var documentReference: DocumentReference
    public var state: ArtifactState
    public var evidenceIDs: [EntityID]
    public var generatedFromRunID: EntityID

    public init(
        title: String,
        kind: String,
        currentReference: ArtifactReference,
        documentReference: DocumentReference,
        state: ArtifactState,
        evidenceIDs: [EntityID],
        generatedFromRunID: EntityID
    ) {
        self.title = title
        self.kind = kind
        self.currentReference = currentReference
        self.documentReference = documentReference
        self.state = state
        self.evidenceIDs = evidenceIDs
        self.generatedFromRunID = generatedFromRunID
    }
}
public struct ArtifactView: Codable, Sendable {
    public var viewerID: EntityID
    public var artifact: ArtifactReference
    public var firstViewedAt: Date
    public var lastViewedAt: Date

    public init(
        viewerID: EntityID,
        artifact: ArtifactReference,
        firstViewedAt: Date,
        lastViewedAt: Date
    ) {
        self.viewerID = viewerID
        self.artifact = artifact
        self.firstViewedAt = firstViewedAt
        self.lastViewedAt = lastViewedAt
    }
}
public struct MemoryItem: Codable, Sendable {
    public var kind: String
    public var scopeKind: MemoryScopeKind
    public var scopeID: EntityID
    public var content: String
    public var sourceReferences: [String]
    public var sourceUserMessageID: EntityID?
    public var status: MemoryStatus
    public var validUntil: Date?
    public var supersedes: EntityID?
    public var deletionEpoch: Int

    public init(
        kind: String,
        scopeKind: MemoryScopeKind,
        scopeID: EntityID,
        content: String,
        sourceReferences: [String],
        sourceUserMessageID: EntityID?,
        status: MemoryStatus,
        validUntil: Date?,
        supersedes: EntityID?,
        deletionEpoch: Int
    ) {
        self.kind = kind
        self.scopeKind = scopeKind
        self.scopeID = scopeID
        self.content = content
        self.sourceReferences = sourceReferences
        self.sourceUserMessageID = sourceUserMessageID
        self.status = status
        self.validUntil = validUntil
        self.supersedes = supersedes
        self.deletionEpoch = deletionEpoch
    }
}
public struct ForgetSuppression: Codable, Sendable {
    public var deletedMemoryID: EntityID
    public var scopeKind: MemoryScopeKind
    public var scopeID: EntityID
    public var sourceMessageIDs: [EntityID]
    public var sourceSpanIDs: [String]
    public var lineageIDs: [EntityID]
    public var subjectPredicateHMAC: String?
    public var deletionEpoch: Int
    public var clearedByNewUserMessageID: EntityID?

    public init(
        deletedMemoryID: EntityID,
        scopeKind: MemoryScopeKind,
        scopeID: EntityID,
        sourceMessageIDs: [EntityID],
        sourceSpanIDs: [String],
        lineageIDs: [EntityID],
        subjectPredicateHMAC: String?,
        deletionEpoch: Int,
        clearedByNewUserMessageID: EntityID?
    ) {
        self.deletedMemoryID = deletedMemoryID
        self.scopeKind = scopeKind
        self.scopeID = scopeID
        self.sourceMessageIDs = sourceMessageIDs
        self.sourceSpanIDs = sourceSpanIDs
        self.lineageIDs = lineageIDs
        self.subjectPredicateHMAC = subjectPredicateHMAC
        self.deletionEpoch = deletionEpoch
        self.clearedByNewUserMessageID = clearedByNewUserMessageID
    }
}
public struct ActionTarget: Codable, Sendable {
    public let providerID: String
    public let accountID: String
    public let targetID: String
    public let display: String

    public init(
        providerID: String,
        accountID: String,
        targetID: String,
        display: String
    ) {
        self.providerID = providerID
        self.accountID = accountID
        self.targetID = targetID
        self.display = display
    }
}
public struct FrozenActionEnvelope: Codable, Sendable {
    public let operationID: EntityID
    public let delegationID: EntityID
    public let delegationRevision: Revision
    public let toolID: String
    public let toolVersion: String
    public let actorAccountID: String
    public let effectClass: String
    public let targets: [ActionTarget]
    public let argumentsReference: String
    public let argumentsHash: String
    public let artifacts: [ArtifactReference]
    public let grantID: String
    public let grantRevision: Revision
    public let policyVersion: String
    public let expiresAt: Date
    public let idempotencyKey: String
    public let actionDigest: String

    public init(
        operationID: EntityID,
        delegationID: EntityID,
        delegationRevision: Revision,
        toolID: String,
        toolVersion: String,
        actorAccountID: String,
        effectClass: String,
        targets: [ActionTarget],
        argumentsReference: String,
        argumentsHash: String,
        artifacts: [ArtifactReference],
        grantID: String,
        grantRevision: Revision,
        policyVersion: String,
        expiresAt: Date,
        idempotencyKey: String,
        actionDigest: String
    ) {
        self.operationID = operationID
        self.delegationID = delegationID
        self.delegationRevision = delegationRevision
        self.toolID = toolID
        self.toolVersion = toolVersion
        self.actorAccountID = actorAccountID
        self.effectClass = effectClass
        self.targets = targets
        self.argumentsReference = argumentsReference
        self.argumentsHash = argumentsHash
        self.artifacts = artifacts
        self.grantID = grantID
        self.grantRevision = grantRevision
        self.policyVersion = policyVersion
        self.expiresAt = expiresAt
        self.idempotencyKey = idempotencyKey
        self.actionDigest = actionDigest
    }
}
public struct ActionApproval: Codable, Sendable {
    public var actionID: EntityID
    public var operationID: EntityID
    public var actionDigest: String
    public var grantRevision: Revision
    public var status: ApprovalStatus
    public var expiresAt: Date
    public var decidedAt: Date?
    public var dispatchCommitSequence: Int64?

    public init(
        actionID: EntityID,
        operationID: EntityID,
        actionDigest: String,
        grantRevision: Revision,
        status: ApprovalStatus,
        expiresAt: Date,
        decidedAt: Date?,
        dispatchCommitSequence: Int64?
    ) {
        self.actionID = actionID
        self.operationID = operationID
        self.actionDigest = actionDigest
        self.grantRevision = grantRevision
        self.status = status
        self.expiresAt = expiresAt
        self.decidedAt = decidedAt
        self.dispatchCommitSequence = dispatchCommitSequence
    }
}
public struct ExecutionReceipt: Codable, Sendable {
    public var operationID: EntityID
    public var attemptID: EntityID
    public var status: ReceiptStatus
    public var actionDigest: String
    public var providerOperationID: String?
    public var dispatchCommitSequence: Int64?
    public var verificationEvidenceReferences: [String]
    public var verifiedAt: Date?
    public var reality: ExecutionReality

    public init(
        operationID: EntityID,
        attemptID: EntityID,
        status: ReceiptStatus,
        actionDigest: String,
        providerOperationID: String?,
        dispatchCommitSequence: Int64?,
        verificationEvidenceReferences: [String],
        verifiedAt: Date?,
        reality: ExecutionReality
    ) {
        self.operationID = operationID
        self.attemptID = attemptID
        self.status = status
        self.actionDigest = actionDigest
        self.providerOperationID = providerOperationID
        self.dispatchCommitSequence = dispatchCommitSequence
        self.verificationEvidenceReferences = verificationEvidenceReferences
        self.verifiedAt = verifiedAt
        self.reality = reality
    }
}
