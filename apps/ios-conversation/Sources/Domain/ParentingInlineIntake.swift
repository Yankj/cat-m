import Foundation

public enum ParentingIntakePhase: String, Sendable, Equatable {
    case idle, preparing, awaitingConsent, sending, ready, failed, unknown, cancelled
}

/// Local recovery metadata is encrypted separately. Authentication tokens are never persisted here.
public struct ParentingIntakeRecoveryReference: Codable, Sendable, Equatable, Identifiable {
    public static let maximumAge: TimeInterval = 24 * 60 * 60
    public var id: UUID { requestID }
    public let schemaVersion: Int
    public let requestID: UUID
    public let scope: DataScope
    public let subjectID: UUID
    public let conversationID: UUID
    public let sourceText: String
    public let childID: UUID
    public let goalID: UUID?
    public let startedAt: Date
    public let timeZoneID: String
    public let editTarget: ParentingArrangementEditTarget?
    public init(requestID: UUID, scope: DataScope, subjectID: UUID, conversationID: UUID, sourceText: String,
                childID: UUID, goalID: UUID?, startedAt: Date, timeZoneID: String, editTarget: ParentingArrangementEditTarget? = nil) {
        schemaVersion = 1; self.requestID = requestID; self.scope = scope; self.subjectID = subjectID
        self.conversationID = conversationID; self.sourceText = sourceText; self.childID = childID; self.goalID = goalID
        self.startedAt = startedAt; self.timeZoneID = timeZoneID; self.editTarget = editTarget
    }
    public func request(accountToken: AccountToken) throws -> ParentingIntakeRequest {
        guard schemaVersion == 1, requestID != conversationID, let zone = TimeZone(identifier: timeZoneID) else { throw ParentingInlineIntakeError.storage }
        return try ParentingIntakeRequest(id: requestID, scope: scope, subjectID: subjectID, accountToken: accountToken,
            conversationID: conversationID, sourceText: sourceText, childID: childID, goalID: goalID, now: startedAt, timeZone: zone, editTarget: editTarget)
    }
}

protocol ParentingIntakeRecoveryStoring: Sendable {
    var exists: Bool { get }
    func read() throws -> ParentingIntakeRecoveryReference?
    func save(_ reference: ParentingIntakeRecoveryReference) throws
    func delete() throws
}

public protocol ParentingIntakeDataDeleting: Sendable {
    func deleteIntake(scope: DataScope, conversationID: UUID) async throws
}
struct ParentingIntakeCleanupReference: Codable, Sendable, Equatable, Identifiable {
    var id: UUID { conversationID }
    let scope: DataScope
    let subjectID: UUID
    let conversationID: UUID
    var pending: Bool
}
protocol ParentingIntakeCleanupStoring: Sendable {
    var exists: Bool { get }
    func read() throws -> [ParentingIntakeCleanupReference]
    func save(_ references: [ParentingIntakeCleanupReference]) throws
}

public enum ParentingInlineIntakeError: Error, LocalizedError, Sendable {
    case unavailable, changedContext, notSent, unknown, failed, storage, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "AI 整理暂时不可用。原话仍保留，可以继续手动填写。"
        case .changedContext: return "账号、输入或页面状态已变化，本次结果不会填回。原话仍保留。"
        case .notSent: return "本次整理尚未发送。原话已保留，可以重试原请求。"
        case .unknown: return "本次整理结果尚未确认。请读取原请求状态，不要重复发送。"
        case .failed: return "本次整理未能完成。原话仍保留，可以手动填写或重新发起整理。"
        case .storage: return "整理记录无法安全保存，已停止请求。原文件与原话会保留。"
        case .invalidResponse: return "整理回复未通过格式或来源校验。原话仍保留，可以继续手动填写。"
        }
    }
}
