import Foundation

/// R7 §5.1 connection state machine (design/ios26-swift-mapping-r7 §4).
/// Presentation-free: the status capsule / cards (Grok Bot UI lane) observe this.
public enum ConversationConnectionState: Equatable, Sendable {
    case online
    case offline
    case reconnecting(attempt: Int, retryIn: Int)
    case resumed
    case unreachable
    case busy(retryIn: Int)
    case syncing

    /// Copy from docs/design/conversation-states-r7.json `connectionStates`.
    public var label: String? {
        switch self {
        case .online: return nil
        case .offline: return "离线 · 草稿和待发消息都会保留"
        case .reconnecting(let attempt, let retryIn): return "正在重新连接 · 第 \(attempt) 次 · \(retryIn) 秒后"
        case .resumed: return "已接上 · 从断点继续"
        case .unreachable: return "这条回复暂时没接上"
        case .busy(let retryIn): return "免费模型正忙 · \(retryIn) 秒后自动重试"
        case .syncing: return "正在同步工作状态…"
        }
    }
}

/// R7 §5.3 backoff: 1→2→4→8→16 s, cap 30 s, ±20 % jitter; offline never counts an attempt.
public struct ConversationReconnectPolicy: Sendable {
    public static let schedule: [Double] = [1, 2, 4, 8, 16]
    public static let cap: Double = 30
    /// No frame (data or `: keepalive`) for this long means the stream dropped.
    public static let idleTimeout: TimeInterval = 15
    public var jitter: @Sendable () -> Double
    public init(jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }) { self.jitter = jitter }
    /// Seconds to wait before attempt `attempt` (0-based), or nil when attempts are exhausted.
    public func delay(forAttempt attempt: Int) -> Double? {
        guard attempt >= 0, attempt < Self.schedule.count else { return nil }
        return min(Self.cap, Self.schedule[attempt] * jitter())
    }
}

/// Thrown by a backend when an already-POSTed turn stream broke in transport.
/// The turn may be running server-side; recovery is GET-after-sequence only, never a resend.
public struct ConversationStreamInterrupted: Error, LocalizedError, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// R7 decision: at most 10 attachments per message, 20 MB each.
public enum ConversationAttachmentLimits {
    public static let maxPerMessage = 10
    public static let maxBytesPerFile = 20 * 1024 * 1024
    public static let oversizeMessage = "文件超过本地导入上限 20 MB。"
    public static let tooManyMessage = "每条消息最多添加 10 个附件。"
}

/// Developer-only free model route override (free-model review §13.3). Sent as `X-Catpaw-Route`;
/// the Edge accepts only its allow-list and only among consented free routes. Never a paid route.
public enum ConversationModelRoute: String, CaseIterable, Identifiable, Sendable {
    case automatic, gemini, groq, openrouter
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "自动（Gemini 免费层优先）"
        case .gemini: return "Gemini 免费层"
        case .groq: return "Groq 免费"
        case .openrouter: return "OpenRouter 免费"
        }
    }
    public static let defaultsKey = "catpaw.developer.modelRoute"
    public static var current: ConversationModelRoute {
        #if DEBUG
        return ConversationModelRoute(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
        #else
        return .automatic
        #endif
    }
    /// Header value, nil for automatic.
    public var headerValue: String? { self == .automatic ? nil : rawValue }
}
