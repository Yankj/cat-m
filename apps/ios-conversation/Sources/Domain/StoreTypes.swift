import Foundation
import CryptoKit

public enum CatpawError: Error, LocalizedError, Sendable {
    case missing, conflict, scopeMismatch, invalid(String), unavailable(String), corrupt(String)
    public var errorDescription: String? {
        switch self {
        case .missing: return "这项内容不存在或已删除。"
        case .conflict: return "内容已更新，请重新打开后再保存。未保存输入仍保留。"
        case .scopeMismatch: return "无法访问其他数据分区的内容。"
        case .invalid(let text), .unavailable(let text), .corrupt(let text): return text
        }
    }
}
public func textHash(_ text: String) -> String { bytesHash(Data(text.utf8)) }
public func bytesHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

public enum Profiles {
    public static let user = DataScope(profileID: UUID(uuidString:"11111111-1111-4111-8111-111111111111")!, workspaceID: UUID(uuidString:"11111111-2222-4222-8222-111111111111")!)
    public static let demo = DataScope(profileID: UUID(uuidString:"22222222-1111-4111-8111-111111111111")!, workspaceID: UUID(uuidString:"22222222-2222-4222-8222-111111111111")!)
    public static func inEnvironment(_ kind: EnvironmentKind, profile: DataScope) -> DataScope {
        let base = profile.profileID == demo.profileID ? demo : profile.profileID == user.profileID ? user : DataScope(profileID: profile.profileID, workspaceID: stableID("local-workspace-\(profile.profileID)"))
        return kind == .local ? base : DataScope(profileID: base.profileID, workspaceID: stableID("workspace-\(base.profileID)-\(kind.rawValue)"))
    }
}
public struct SourceItem: Codable, Sendable {
    public var delegationID: UUID
    public var url: String
    public var revision: Int
    public var allowed: Bool
}
public struct ActionDraft: Codable, Sendable {
    public let document: DocumentReference
    public let destination: String
    public let digest: String
    public var status: ApprovalStatus
    public var receipt: ReceiptStatus
    public let operationID: UUID
    public var queryCount: Int
    public var reality: ExecutionReality = .simulated
    public var history: [ReceiptStatus] = [.notStarted]
    public var expiresAt: Date = Date().addingTimeInterval(600)
    public var purpose: String { "单次模拟外发" }
}
public struct Preference: Codable, Sendable {
    public var key: String
    public var value: String
}
public struct FrozenRequestConfiguration: Codable, Sendable {
    public let conversationID: UUID
    public let userMessageID: UUID
    public let environmentID: UUID
    public let projectID: UUID?
    public let configuration: ConversationConfiguration
    public let expertRevisions: [UUID: Int]
    public let skillRevisions: [UUID: Int]
}
public enum Payload: Codable, Sendable {
    case core(LocalEntityPayload)
    case delegation(Delegation)
    case run(AssistantRun)
    case artifact(Artifact)
    case memory(MemoryItem)
    case suppression(ForgetSuppression)
    case source(SourceItem)
    case action(ActionDraft)
    case preference(Preference)
    case requestConfiguration(FrozenRequestConfiguration)
    case viewReceipt(ViewReceipt)
    case voiceEdit(VoiceEditReceipt)
    case conversationUIState(CGUIStoredLocalState)
    public var kind: String {
        switch self {
        case .core(let p):
            switch p {
            case .conversation: return "conversation"; case .message: return "message"; case .project: return "project"
            case .expert: return "expert"; case .skill: return "skill"; case .task: return "task"; case .schedule: return "schedule"
            case .document: return "document"; case .documentVersion: return "documentVersion"; case .environment: return "environment"; case .permission: return "permission"
            }
        case .delegation: return "delegation"; case .run: return "run"; case .artifact: return "artifact"
        case .memory: return "memory"; case .suppression: return "suppression"; case .source: return "source"
        case .action: return "action"; case .preference: return "preference"
        case .requestConfiguration: return "requestConfiguration"
        case .viewReceipt: return "viewReceipt"
        case .voiceEdit: return "voiceEdit"
        case .conversationUIState: return "conversationUIState"
        }
    }
    public var parentID: UUID? {
        switch self {
        case .core(.message(let p)): return p.conversationID
        case .core(.task(let p)): return p.conversationID
        case .core(.documentVersion(let p)): return p.documentID
        case .run(let p): return p.delegationID
        case .source(let p): return p.delegationID
        case .requestConfiguration(let p): return p.conversationID
        default: return nil
        }
    }
}
public struct StoredRecord: Codable, Sendable, Identifiable {
    public var header: RecordHeader
    public var payload: Payload
    public var id: UUID { header.id }
    public var title: String {
        switch payload {
        case .core(.conversation(let p)): return p.title
        case .core(.project(let p)): return p.name
        case .core(.expert(let p)): return p.name
        case .core(.skill(let p)): return p.name
        case .core(.task(let p)): return p.title
        case .core(.schedule(let p)): return p.title
        case .core(.document(let p)): return p.title
        case .core(.environment(let p)): return p.name
        case .delegation(let p): return p.title
        case .memory(let p): return p.content
        case .artifact(let p): return p.title
        default: return payload.kind
        }
    }
    public var conversation: Conversation? { if case .core(.conversation(let p)) = payload { return p }; return nil }
    public var message: ChatMessage? { if case .core(.message(let p)) = payload { return p }; return nil }
    public var document: Document? { if case .core(.document(let p)) = payload { return p }; return nil }
    public var task: WorkTask? { if case .core(.task(let p)) = payload { return p }; return nil }
    public var delegation: Delegation? { if case .delegation(let p) = payload { return p }; return nil }
}
public enum Mutation: Codable, Sendable {
    case requireRevision(UUID, Int)
    case create(UUID, Payload)
    case update(UUID, Int, Payload)
    case remove(UUID, Int)
    case restore(UUID, Int)
}
public struct JournalEntry: Codable, Sendable {
    public var scope: DataScope
    public var fingerprint: String
    public var sequence: Int64
    public var recordIDs: [UUID]
}
public struct StoreSnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public var fixtureSeedVersion = 1
    public var sequence: Int64 = 0
    public var records: [UUID: StoredRecord] = [:]
    public var journal: [UUID: JournalEntry] = [:]
    public init() {}
    public func list(_ kind: String? = nil, scope: DataScope) -> [StoredRecord] {
        records.values.filter { $0.header.scope == scope && $0.header.deletedAt == nil && (kind == nil || $0.payload.kind == kind) }
            .sorted { $0.header.updatedAt > $1.header.updatedAt }
    }
}
public struct CommitNotice: Sendable {
    public var operationID: UUID
    public var scope: DataScope
    public var sequence: Int64
    public var recordIDs: [UUID]
}
