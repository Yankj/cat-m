// Catpaw-m iOS implementation contract v0.1, 2026-10-10.
// Design reference only: no repository/provider/recording implementation is included.
// Wire codecs must explicitly map snake_case, RFC3339 dates and schema enums.
// A successful type check does not establish an iOS build, runtime or backend result.
import Foundation

public typealias EntityID = UUID
public typealias Revision = Int

public struct DataScope: Codable, Hashable, Sendable {
    public var profileID: EntityID
    public var workspaceID: EntityID

    public init(
        profileID: EntityID,
        workspaceID: EntityID
    ) {
        self.profileID = profileID
        self.workspaceID = workspaceID
    }
}

public enum DataOrigin: String, Codable, Sendable {
    case userLocal = "user_local"
    case fixtureSeed = "fixture_seed"
    case providerCache = "provider_cache"
}

public enum ExecutionReality: String, Codable, Sendable {
    case localEffect = "local_effect"
    case simulated
    case remoteAccepted = "remote_accepted"
    case remoteVerified = "remote_verified"
    case unknown
}

public struct RecordHeader: Codable, Sendable {
    public var id: EntityID
    public var scope: DataScope
    public var revision: Revision
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var origin: DataOrigin
    public var providerID: String?
    public var providerObjectID: String?
    public var evidenceIDs: [String]

    public init(
        id: EntityID,
        scope: DataScope,
        revision: Revision,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?,
        origin: DataOrigin,
        providerID: String?,
        providerObjectID: String?,
        evidenceIDs: [String]
    ) {
        self.id = id
        self.scope = scope
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.origin = origin
        self.providerID = providerID
        self.providerObjectID = providerObjectID
        self.evidenceIDs = evidenceIDs
    }
}

public struct Entity<Value: Codable & Sendable>: Codable, Sendable, Identifiable {
    public var header: RecordHeader
    public var value: Value
    public var id: EntityID { header.id }

    public init(
        header: RecordHeader,
        value: Value
    ) {
        self.header = header
        self.value = value
    }
}

public struct DocumentReference: Codable, Hashable, Sendable {
    public var documentID: EntityID
    public var version: Revision
    public var contentHash: String

    public init(
        documentID: EntityID,
        version: Revision,
        contentHash: String
    ) {
        self.documentID = documentID
        self.version = version
        self.contentHash = contentHash
    }
}

public struct Conversation: Codable, Sendable {
    public var title: String
    public var projectID: EntityID?
    public var expertID: EntityID?
    public var skillIDs: [EntityID]
    public var environmentID: EntityID
    public var archivedAt: Date?
    public var draftText: String

    public init(
        title: String,
        projectID: EntityID?,
        expertID: EntityID?,
        skillIDs: [EntityID],
        environmentID: EntityID,
        archivedAt: Date?,
        draftText: String
    ) {
        self.title = title
        self.projectID = projectID
        self.expertID = expertID
        self.skillIDs = skillIDs
        self.environmentID = environmentID
        self.archivedAt = archivedAt
        self.draftText = draftText
    }
}

// A stored role is presentation metadata, not permission to inject system instructions.
public enum MessageRole: String, Codable, Sendable { case user, assistant, system }
public enum MessageState: String, Codable, Sendable {
    case draft
    case localSaved = "local_saved"
    case waitingProvider = "waiting_provider"
    case streaming, completed, failed, cancelled
}
public struct ProgressSnapshot: Codable, Sendable {
    public var label: String
    public var completedUnits: Int?
    public var totalUnits: Int?

    public init(
        label: String,
        completedUnits: Int?,
        totalUnits: Int?
    ) {
        self.label = label
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }
}
public enum MessageBlock: Codable, Sendable {
    case text(String)
    case document(DocumentReference)
    case task(EntityID)
    case progress(ProgressSnapshot)
}
public struct ChatMessage: Codable, Sendable {
    public var conversationID: EntityID
    public var clientMessageID: EntityID
    public var role: MessageRole
    public var blocks: [MessageBlock]
    public var replyToID: EntityID?
    public var state: MessageState
    public var reality: ExecutionReality
    public var sequence: Int

    public init(
        conversationID: EntityID,
        clientMessageID: EntityID,
        role: MessageRole,
        blocks: [MessageBlock],
        replyToID: EntityID?,
        state: MessageState,
        reality: ExecutionReality,
        sequence: Int
    ) {
        self.conversationID = conversationID
        self.clientMessageID = clientMessageID
        self.role = role
        self.blocks = blocks
        self.replyToID = replyToID
        self.state = state
        self.reality = reality
        self.sequence = sequence
    }
}

public struct Project: Codable, Sendable {
    public var name: String
    public var summary: String?
    public var documentIDs: [EntityID]
    public var defaultExpertID: EntityID?
    public var skillIDs: [EntityID]

    public init(
        name: String,
        summary: String?,
        documentIDs: [EntityID],
        defaultExpertID: EntityID?,
        skillIDs: [EntityID]
    ) {
        self.name = name
        self.summary = summary
        self.documentIDs = documentIDs
        self.defaultExpertID = defaultExpertID
        self.skillIDs = skillIDs
    }
}
public struct Expert: Codable, Sendable {
    public var name: String
    public var summary: String
    public var configurationJSON: Data
    public var preset: Bool
    public var configurationRevision: Revision

    public init(
        name: String,
        summary: String,
        configurationJSON: Data,
        preset: Bool,
        configurationRevision: Revision
    ) {
        self.name = name
        self.summary = summary
        self.configurationJSON = configurationJSON
        self.preset = preset
        self.configurationRevision = configurationRevision
    }
}
public struct Skill: Codable, Sendable {
    public var name: String
    public var summary: String
    public var definitionJSON: Data
    public var version: String
    public var enabledScopeIDs: [EntityID]

    public init(
        name: String,
        summary: String,
        definitionJSON: Data,
        version: String,
        enabledScopeIDs: [EntityID]
    ) {
        self.name = name
        self.summary = summary
        self.definitionJSON = definitionJSON
        self.version = version
        self.enabledScopeIDs = enabledScopeIDs
    }
}

public enum WorkState: String, Codable, Sendable {
    case queued, preparing, running, verifying, succeeded
    case waitingApproval = "waiting_approval"
    case waitingDependency = "waiting_dependency"
    case retryScheduled = "retry_scheduled"
    case cancelRequested = "cancel_requested"
    case cancelled, failed
    case outcomeUnknown = "outcome_unknown"
}
public struct WorkStep: Codable, Sendable {
    public var id: EntityID
    public var title: String
    public var state: WorkState
    public var evidenceReference: String?

    public init(
        id: EntityID,
        title: String,
        state: WorkState,
        evidenceReference: String?
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.evidenceReference = evidenceReference
    }
}
public struct WorkTask: Codable, Sendable {
    public var title: String
    public var conversationID: EntityID
    public var environmentID: EntityID
    public var operationID: EntityID
    public var state: WorkState
    public var steps: [WorkStep]
    public var results: [DocumentReference]
    public var reality: ExecutionReality

    public init(
        title: String,
        conversationID: EntityID,
        environmentID: EntityID,
        operationID: EntityID,
        state: WorkState,
        steps: [WorkStep],
        results: [DocumentReference],
        reality: ExecutionReality
    ) {
        self.title = title
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.operationID = operationID
        self.state = state
        self.steps = steps
        self.results = results
        self.reality = reality
    }
}
public enum ScheduleExecutionMode: String, Codable, Sendable {
    case localSessionOnly = "local_session_only"
    case fixture
    case providerVerified = "provider_verified"
}
public struct ScheduleSpec: Codable, Sendable {
    public var timezoneID: String
    public var cadence: String // validated supported enum in the implementation
    public var localHour: Int
    public var localMinute: Int
    public var weekdays: [Int]
    public var missedRunPolicy: String

    public init(
        timezoneID: String,
        cadence: String,
        localHour: Int,
        localMinute: Int,
        weekdays: [Int],
        missedRunPolicy: String
    ) {
        self.timezoneID = timezoneID
        self.cadence = cadence
        self.localHour = localHour
        self.localMinute = localMinute
        self.weekdays = weekdays
        self.missedRunPolicy = missedRunPolicy
    }
}
public struct ScheduledTask: Codable, Sendable {
    public var title: String
    public var schedule: ScheduleSpec
    public var enabled: Bool
    public var nextDueAt: Date?
    public var lastLocalAttemptAt: Date?
    public var executionMode: ScheduleExecutionMode
    public var taskTemplateJSON: Data

    public init(
        title: String,
        schedule: ScheduleSpec,
        enabled: Bool,
        nextDueAt: Date?,
        lastLocalAttemptAt: Date?,
        executionMode: ScheduleExecutionMode,
        taskTemplateJSON: Data
    ) {
        self.title = title
        self.schedule = schedule
        self.enabled = enabled
        self.nextDueAt = nextDueAt
        self.lastLocalAttemptAt = lastLocalAttemptAt
        self.executionMode = executionMode
        self.taskTemplateJSON = taskTemplateJSON
    }
}
public struct Document: Codable, Sendable {
    public var title: String
    public var mimeType: String
    public var currentVersion: Revision
    public var ownerIDs: [EntityID]
    public var sourceKind: String

    public init(
        title: String,
        mimeType: String,
        currentVersion: Revision,
        ownerIDs: [EntityID],
        sourceKind: String
    ) {
        self.title = title
        self.mimeType = mimeType
        self.currentVersion = currentVersion
        self.ownerIDs = ownerIDs
        self.sourceKind = sourceKind
    }
}
public struct DocumentVersion: Codable, Sendable {
    public var documentID: EntityID
    public var version: Revision
    public var parentVersion: Revision?
    public var privateBlobReference: String
    public var contentHash: String

    public init(
        documentID: EntityID,
        version: Revision,
        parentVersion: Revision?,
        privateBlobReference: String,
        contentHash: String
    ) {
        self.documentID = documentID
        self.version = version
        self.parentVersion = parentVersion
        self.privateBlobReference = privateBlobReference
        self.contentHash = contentHash
    }
}
public enum EnvironmentKind: String, Codable, Sendable { case cloud, computer, local }
public enum ConnectionState: String, Codable, Sendable {
    case unverified, disconnected, connecting, connected, unavailable
}
public struct ExecutionEnvironment: Codable, Sendable {
    public var name: String
    public var kind: EnvironmentKind
    public var connection: ConnectionState
    public var capabilityIDs: [String]
    public var verifiedAt: Date?

    public init(
        name: String,
        kind: EnvironmentKind,
        connection: ConnectionState,
        capabilityIDs: [String],
        verifiedAt: Date?
    ) {
        self.name = name
        self.kind = kind
        self.connection = connection
        self.capabilityIDs = capabilityIDs
        self.verifiedAt = verifiedAt
    }
}
public enum LocalPermissionAuthority: String, Codable, Sendable {
    case localPreference = "local_preference"
    case fixture
    // Real provider grants are separate server-authoritative records.
}
public struct PermissionPreference: Codable, Sendable {
    public var resourceScope: String
    public var actionScope: String
    public var decision: String
    public var authority: LocalPermissionAuthority
    public var expiresAt: Date?

    public init(
        resourceScope: String,
        actionScope: String,
        decision: String,
        authority: LocalPermissionAuthority,
        expiresAt: Date?
    ) {
        self.resourceScope = resourceScope
        self.actionScope = actionScope
        self.decision = decision
        self.authority = authority
        self.expiresAt = expiresAt
    }
}

public enum LocalEntityPayload: Codable, Sendable {
    case conversation(Conversation)
    case message(ChatMessage)
    case project(Project)
    case expert(Expert)
    case skill(Skill)
    case task(WorkTask)
    case schedule(ScheduledTask)
    case document(Document)
    case documentVersion(DocumentVersion)
    case environment(ExecutionEnvironment)
    case permission(PermissionPreference)
}
public enum LocalEntityKind: String, Codable, Sendable {
    case conversation, message, project, expert, skill, task, schedule
    case document, documentVersion, environment, permission
}
public struct LocalQuery: Sendable {
    public var kind: LocalEntityKind
    public var scope: DataScope
    public var parentID: EntityID?
    public var searchText: String?
    public var cursor: String?

    public init(
        kind: LocalEntityKind,
        scope: DataScope,
        parentID: EntityID?,
        searchText: String?,
        cursor: String?
    ) {
        self.kind = kind
        self.scope = scope
        self.parentID = parentID
        self.searchText = searchText
        self.cursor = cursor
    }
}
public struct LocalPage: Sendable {
    public var records: [Entity<LocalEntityPayload>]
    public var nextCursor: String?

    public init(
        records: [Entity<LocalEntityPayload>],
        nextCursor: String?
    ) {
        self.records = records
        self.nextCursor = nextCursor
    }
}
public enum LocalMutation: Sendable {
    case create(id: EntityID, payload: LocalEntityPayload)
    case update(id: EntityID, expectedRevision: Revision, payload: LocalEntityPayload)
    case archiveConversation(id: EntityID, expectedRevision: Revision)
    case removeRecoverably(id: EntityID, expectedRevision: Revision)
    case restore(id: EntityID, expectedRevision: Revision)
}
public struct LocalCommand: Sendable {
    public var operationID: EntityID
    public var scope: DataScope
    public var mutations: [LocalMutation]

    public init(
        operationID: EntityID,
        scope: DataScope,
        mutations: [LocalMutation]
    ) {
        self.operationID = operationID
        self.scope = scope
        self.mutations = mutations
    }
}
public struct LocalCommit: Sendable {
    public var operationID: EntityID
    public var changeSequence: Int64
    public var affectedRecords: [Entity<LocalEntityPayload>]

    public init(
        operationID: EntityID,
        changeSequence: Int64,
        affectedRecords: [Entity<LocalEntityPayload>]
    ) {
        self.operationID = operationID
        self.changeSequence = changeSequence
        self.affectedRecords = affectedRecords
    }
}
public protocol LocalRepository: Sendable {
    func query(_ query: LocalQuery) async throws -> LocalPage
    func record(id: EntityID, scope: DataScope) async throws -> Entity<LocalEntityPayload>?
    func commit(_ command: LocalCommand) async throws -> LocalCommit
    func changes(scope: DataScope, after sequence: Int64) async -> AsyncStream<LocalCommit>
}

public enum CapabilityAvailability: String, Codable, Sendable {
    case localAvailable = "local_available"
    case fixtureAvailable = "fixture_available"
    case remoteVerified = "remote_verified"
    case unavailable, unverified
}
public struct ProviderCapability: Codable, Sendable {
    public var capabilityID: String
    public var availability: CapabilityAvailability
    public var requiredAuthorizationKinds: [String]

    public init(
        capabilityID: String,
        availability: CapabilityAvailability,
        requiredAuthorizationKinds: [String]
    ) {
        self.capabilityID = capabilityID
        self.availability = availability
        self.requiredAuthorizationKinds = requiredAuthorizationKinds
    }
}
public struct ProviderDescriptor: Codable, Sendable {
    public var id: String
    public var version: String
    public var capabilities: [ProviderCapability]

    public init(
        id: String,
        version: String,
        capabilities: [ProviderCapability]
    ) {
        self.id = id
        self.version = version
        self.capabilities = capabilities
    }
}
public struct ProviderContext: Codable, Sendable {
    public var scope: DataScope
    public var operationID: EntityID
    public var environmentID: EntityID
    public var providerID: String
    public var runtimeEpoch: Int
    public var authorizationReferences: [String] // references only; never token values

    public init(
        scope: DataScope,
        operationID: EntityID,
        environmentID: EntityID,
        providerID: String,
        runtimeEpoch: Int,
        authorizationReferences: [String]
    ) {
        self.scope = scope
        self.operationID = operationID
        self.environmentID = environmentID
        self.providerID = providerID
        self.runtimeEpoch = runtimeEpoch
        self.authorizationReferences = authorizationReferences
    }
}
public struct ChatRequest: Codable, Sendable {
    public var context: ProviderContext
    public var conversationID: EntityID
    public var userMessageID: EntityID
    public var frozenText: String
    public var frozenTextHash: String
    public var conversationRevision: Revision

    public init(
        context: ProviderContext,
        conversationID: EntityID,
        userMessageID: EntityID,
        frozenText: String,
        frozenTextHash: String,
        conversationRevision: Revision
    ) {
        self.context = context
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.frozenText = frozenText
        self.frozenTextHash = frozenTextHash
        self.conversationRevision = conversationRevision
    }
}
public struct TaskRequest: Codable, Sendable {
    public var context: ProviderContext
    public var taskID: EntityID
    public var taskRevision: Revision

    public init(
        context: ProviderContext,
        taskID: EntityID,
        taskRevision: Revision
    ) {
        self.context = context
        self.taskID = taskID
        self.taskRevision = taskRevision
    }
}
public struct ProviderFailure: Codable, Sendable {
    public var code: String
    public var displayMessage: String
    public var retryable: Bool
    public var retryAfterSeconds: Int?

    public init(
        code: String,
        displayMessage: String,
        retryable: Bool,
        retryAfterSeconds: Int?
    ) {
        self.code = code
        self.displayMessage = displayMessage
        self.retryable = retryable
        self.retryAfterSeconds = retryAfterSeconds
    }
}
public enum MessageFinishReason: String, Codable, Sendable {
    case stop, length
    case needsUserInput = "needs_user_input"
    case toolWorkContinues = "tool_work_continues"
}
public enum ProviderEventPayload: Codable, Sendable {
    case textDelta(String)
    case progress(ProgressSnapshot)
    case result(DocumentReference)
    case accepted(providerOperationID: String)
    case verified(receiptReference: String) // observation, not an implicit stream terminator
    case messageCompleted(finalTextHash: String, finishReason: MessageFinishReason)
    case taskCompleted(receiptReference: String)
    case cancelled
    case outcomeUnknown
    case failed(ProviderFailure)
}
public struct ProviderEvent: Codable, Sendable {
    public var operationID: EntityID
    public var sequence: Int
    public var runtimeEpoch: Int
    public var reality: ExecutionReality
    public var payload: ProviderEventPayload

    public init(
        operationID: EntityID,
        sequence: Int,
        runtimeEpoch: Int,
        reality: ExecutionReality,
        payload: ProviderEventPayload
    ) {
        self.operationID = operationID
        self.sequence = sequence
        self.runtimeEpoch = runtimeEpoch
        self.reality = reality
        self.payload = payload
    }
}
public protocol AgentProvider: Sendable {
    func descriptor() async -> ProviderDescriptor
    func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error>
    func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error>
    func observe(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent
    func cancel(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent
}

public enum Route: Hashable, Codable, Sendable {
    case brief
    case conversations
    case conversation(EntityID)
    case project(EntityID)
    case expert(EntityID)
    case skill(EntityID)
    case task(EntityID)
    case schedule(EntityID)
    case document(EntityID, version: Revision)
    case environments
    case permissions
}

public enum PermissionStatus: String, Codable, Sendable {
    case notDetermined, granted, denied, restricted, unavailable
}
public struct VoicePermissionSnapshot: Sendable {
    public var microphone: PermissionStatus
    public var speechRecognition: PermissionStatus
    public var onDeviceRecognitionSupported: Bool
    public var localeID: String

    public init(
        microphone: PermissionStatus,
        speechRecognition: PermissionStatus,
        onDeviceRecognitionSupported: Bool,
        localeID: String
    ) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.onDeviceRecognitionSupported = onDeviceRecognitionSupported
        self.localeID = localeID
    }
}
public struct ExplicitUserGesture: Sendable {
    public var actionID: EntityID
    public var createdAt: Date
    public var purpose: String

    public init(
        actionID: EntityID,
        createdAt: Date,
        purpose: String
    ) {
        self.actionID = actionID
        self.createdAt = createdAt
        self.purpose = purpose
    }
}
@MainActor public protocol VoicePermissionBroker: AnyObject {
    // Must not show prompts or download language resources.
    func inspect(localeID: String) -> VoicePermissionSnapshot
    // Only the user-facing control path may call this, never app launch/inspection/TTS.
    func requestFromUserAction(_ gesture: ExplicitUserGesture) async -> VoicePermissionSnapshot
}
public struct VoiceEpochs: Codable, Sendable {
    public var session: Int
    public var capture: Int
    public var generation: Int
    public var playback: Int
    public var consent: Int

    public init(
        session: Int,
        capture: Int,
        generation: Int,
        playback: Int,
        consent: Int
    ) {
        self.session = session
        self.capture = capture
        self.generation = generation
        self.playback = playback
        self.consent = consent
    }
}
public struct ReadoutRequest: Sendable {
    public var requestID: EntityID
    public var turnID: EntityID
    public var document: DocumentReference
    public var frozenSegments: [String]
    public var voiceID: String?
    public var localeID: String
    public var epochs: VoiceEpochs

    public init(
        requestID: EntityID,
        turnID: EntityID,
        document: DocumentReference,
        frozenSegments: [String],
        voiceID: String?,
        localeID: String,
        epochs: VoiceEpochs
    ) {
        self.requestID = requestID
        self.turnID = turnID
        self.document = document
        self.frozenSegments = frozenSegments
        self.voiceID = voiceID
        self.localeID = localeID
        self.epochs = epochs
    }
}
public enum TTSPlaybackEvent: Sendable {
    case started(requestID: EntityID, segment: Int, epochs: VoiceEpochs)
    case finished(requestID: EntityID, segment: Int, epochs: VoiceEpochs)
    case cancelled(requestID: EntityID, epochs: VoiceEpochs)
    case failed(requestID: EntityID, code: String, epochs: VoiceEpochs)
}
@MainActor public protocol NativeTTSProvider: AnyObject {
    func availableVoiceIDs(localeID: String) -> [String]
    func speak(_ request: ReadoutRequest) -> AsyncStream<TTSPlaybackEvent>
    func pausePlayback()
    func resumePlayback()
    func stopPlayback(newPlaybackEpoch: Int)
}
public struct CaptureRequest: Sendable {
    public var captureID: EntityID
    public var utteranceID: EntityID
    public var localeID: String
    public var epochs: VoiceEpochs
    public var maximumSeconds: Int

    public init(
        captureID: EntityID,
        utteranceID: EntityID,
        localeID: String,
        epochs: VoiceEpochs,
        maximumSeconds: Int
    ) {
        self.captureID = captureID
        self.utteranceID = utteranceID
        self.localeID = localeID
        self.epochs = epochs
        self.maximumSeconds = maximumSeconds
    }
}
public enum ASREvent: Sendable {
    case partial(text: String, revision: Int, captureID: EntityID, epochs: VoiceEpochs)
    case final(text: String, revision: Int, captureID: EntityID, epochs: VoiceEpochs)
    case noSpeech(captureID: EntityID, epochs: VoiceEpochs)
    case failed(code: String, captureID: EntityID, epochs: VoiceEpochs)
}
@MainActor public protocol OnDeviceASRProvider: AnyObject {
    // Precondition: granted permissions and supported locale; must not prompt or use cloud fallback.
    func start(_ request: CaptureRequest) throws -> AsyncStream<ASREvent>
    func finishInput(captureID: EntityID)
    func abortCapture(captureID: EntityID, newCaptureEpoch: Int)
}
public struct FrozenTranscriptSubmission: Codable, Sendable {
    public var sessionID: EntityID
    public var utteranceID: EntityID
    public var clientMessageID: EntityID
    public var captureEpoch: Int
    public var transcriptRevision: Int
    public var editRevision: Int
    public var submittedText: String
    public var submittedTextHash: String

    public init(
        sessionID: EntityID,
        utteranceID: EntityID,
        clientMessageID: EntityID,
        captureEpoch: Int,
        transcriptRevision: Int,
        editRevision: Int,
        submittedText: String,
        submittedTextHash: String
    ) {
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.clientMessageID = clientMessageID
        self.captureEpoch = captureEpoch
        self.transcriptRevision = transcriptRevision
        self.editRevision = editRevision
        self.submittedText = submittedText
        self.submittedTextHash = submittedTextHash
    }
}
