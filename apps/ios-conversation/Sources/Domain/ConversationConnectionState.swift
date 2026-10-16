import Foundation

/// R7 §5.1 connection state machine (design/ios26-swift-mapping-r7 §4).
/// Presentation-free: the status capsule / cards (Grok Bot UI lane) observe this.

/// Shared status semantics for Settings + chat header dots (presentation-free).
public enum PathNoticeKind: Equatable, Sendable { case offline, online }

public enum ConnectionStatusKind: String, Equatable, Sendable {
    case online, offline, error
    public var labelKey: String {
        switch self {
        case .online: return "在线"
        case .offline: return "离线"
        case .error: return "异常"
        }
    }
    public static func from(_ state: ConversationConnectionState) -> ConnectionStatusKind {
        switch state {
        case .online, .resumed, .syncing: return .online
        case .offline: return .offline
        case .unreachable, .busy, .reconnecting: return .error
        }
    }
}

public enum ConversationConnectionState: Equatable, Sendable {
    case online
    case offline
    case reconnecting(attempt: Int, retryIn: Int)
    case resumed
    case unreachable
    case busy(retryIn: Int)
    case syncing

    /// Catalog key + arguments for `ui(_:arguments:)` (UIStrings.json uses {0} placeholders).
    public var labelKey: (key: String, arguments: [String])? {
        switch self {
        case .online: return nil
        case .offline: return ("离线 · 草稿和待发消息都会保留", [])
        case .reconnecting(let attempt, let retryIn): return ("正在重新连接 · 第 {0} 次 · {1} 秒后", [String(attempt), String(retryIn)])
        case .resumed: return ("已接上 · 从断点继续", [])
        case .unreachable: return ("这条回复暂时没接上", [])
        case .busy(let retryIn): return ("免费模型正忙 · {0} 秒后自动重试", [String(retryIn)])
        case .syncing: return ("正在同步工作状态…", [])
        }
    }
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

/// `catpaw.model-routes.v1` (services/edge/docs/model-routes-contract.md). Server-driven; no keys/URLs on the client.
public struct ModelRoutesContract: Codable, Equatable, Sendable {
    public let contract: String
    public let default_route: String
    public let chain: [String]
    public let auto_failover: Bool
    public let routes: [ModelRouteInfo]
    public static let contractID = "catpaw.model-routes.v1"
}
public struct ModelRouteModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let `default`: Bool?
}
public struct ModelRouteError: Codable, Equatable, Sendable { public let code: String; public let at: String? }
public struct ModelRouteInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let display_name: String
    public let models: [ModelRouteModel]
    public let status: String
    public let last_error: ModelRouteError?
    public let cooling_seconds: Int?
    public let free: Bool?
    public let billing: String?
    public let policy_url: String?
    public let data_note: String?
    public var statusKind: ConnectionStatusKind { status == "online" ? .online : status == "offline" ? .offline : .error }
    public var defaultModel: String? { models.first(where: { $0.default == true })?.id ?? models.first?.id }
}
/// SSE `model_route` data.
public struct ModelRouteEvent: Codable, Equatable, Sendable {
    public struct Switch: Codable, Equatable, Sendable { public let from: String; public let to: String; public let code: String? }
    public let route: String
    public let model: String?
    public let requested_route: String?
    public let failover: Bool?
    public let from: [String]?
    public let switches: [Switch]?
    public let attempt: Int?
}
/// The user's route/model choice + the last fetched route list (header validation). Thread-safe.
public enum ModelRouteSelection {
    public static let autoID = "auto"
    public static let routeKey = "catpaw.modelRoute.v1"
    public static let modelKey = "catpaw.modelRoute.model.v1"
    public static let rejectionCodes: Set<String> = ["model_route_unknown", "model_route_unavailable", "model_not_allowed"]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [ModelRouteInfo] = []
    public static var route: String { UserDefaults.standard.string(forKey: routeKey).flatMap { $0.isEmpty ? nil : $0 } ?? autoID }
    public static var model: String? { UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } }
    public static func select(route: String, model: String? = nil) {
        UserDefaults.standard.set(route, forKey: routeKey)
        if route == autoID || model == nil { UserDefaults.standard.removeObject(forKey: modelKey) } else { UserDefaults.standard.set(model, forKey: modelKey) }
    }
    public static func resetToAuto() { select(route: autoID) }
    public static func cache(_ routes: [ModelRouteInfo]) { lock.lock(); cached = routes; lock.unlock() }
    public static var routes: [ModelRouteInfo] { lock.lock(); defer { lock.unlock() }; return cached }
    public static func info(_ id: String) -> ModelRouteInfo? { routes.first { $0.id == id } }
    /// `X-Catpaw-Route`: `auto` or a listed id (unknown cached → auto, so headers stay valid).
    public static var headerRoute: String {
        let r = route
        if r == autoID { return autoID }
        let list = routes
        return list.isEmpty || list.contains(where: { $0.id == r }) ? r : autoID
    }
    /// `X-Catpaw-Model`: only with a concrete route and only if in that route's allow-list.
    public static var headerModel: String? {
        let r = headerRoute
        guard r != autoID, let m = model, let info = info(r), info.models.contains(where: { $0.id == m }) else { return nil }
        return m
    }
    public static func displayName(_ id: String) -> String { info(id)?.display_name ?? id }
}
/// Backend → UI bridge (NotificationCenter keeps the Domain free of UI types).
public enum ModelRouteNotifications {
    public static let event = Notification.Name("catpaw.modelRoute.event")        // object: ModelRouteEvent
    public static let rejected = Notification.Name("catpaw.modelRoute.rejected")  // object: String code
    public static func report(_ e: ModelRouteEvent) { NotificationCenter.default.post(name: event, object: e) }
    public static func reject(_ code: String) { ModelRouteSelection.resetToAuto(); NotificationCenter.default.post(name: rejected, object: code) }
}
/// Fixture matching the contract until the Edge endpoint is deployed.
public enum ModelRoutesFixture {
    public static let contract = ModelRoutesContract(
        contract: ModelRoutesContract.contractID, default_route: "auto",
        chain: ["openrouter", "gemini", "opencode", "agnes"], auto_failover: true,
        routes: [
            .init(id: "openrouter", display_name: "OpenRouter", models: [.init(id: "google/gemma-4-31b-it:free", default: true)], status: "online", last_error: nil, cooling_seconds: 0, free: true, billing: "free_tier", policy_url: "https://openrouter.ai/privacy", data_note: "zero_retention"),
            .init(id: "gemini", display_name: "Google Gemini", models: [.init(id: "gemini-3.5-flash-lite", default: true)], status: "online", last_error: .init(code: "rate_limited", at: "2026-10-16T08:01:02.000Z"), cooling_seconds: 0, free: true, billing: "free_tier", policy_url: "https://ai.google.dev/gemini-api/terms", data_note: "free_tier_may_train"),
            .init(id: "opencode", display_name: "OpenCode Zen", models: [.init(id: "opencode-zen", default: true)], status: "online", last_error: nil, cooling_seconds: 0, free: true, billing: "free_tier", policy_url: "https://opencode.ai/privacy", data_note: nil),
            .init(id: "agnes", display_name: "Agnes", models: [.init(id: "agnes-flash", default: true)], status: "online", last_error: nil, cooling_seconds: 0, free: true, billing: "promo_free_flash_paid_pro", policy_url: nil, data_note: nil),
        ])
}

/// First-launch intro gate (PR #24 OnboardingView). PR #24 defines no persisted flag, so this is
/// the single shared key; UI and app model must both use `CatpawOnboarding.completedKey`.
public enum CatpawOnboarding {
    public static let completedKey = "catpaw.onboarding.completed.v1"
    /// Launch argument used by UI tests/screenshots to start past the intro.
    public static let skipArgument = "-CatpawSkipOnboarding"
    public static func isCompleted(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: completedKey) }
    public static func markCompleted(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: completedKey) }
    public static func initialState(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments, fixture: Bool = false) -> OnboardingGateState {
        if arguments.contains(skipArgument) { markCompleted(defaults) } // later relaunches (prewarm, activate) keep it
        return (fixture || arguments.contains(skipArgument) || isCompleted(defaults)) ? .completed : .needsOnboarding
    }
}
/// UI contract: show the intro while `needsOnboarding`; `.entering` = "开启" tapped, waiting for the
/// background warm-up; `.failed` = warm-up failed twice (message is user-facing, tap "开启" again to retry).
public enum OnboardingGateState: Equatable, Sendable {
    case needsOnboarding, entering, failed(String), completed
    public var needsOnboarding: Bool { self != .completed }
}


#if DEBUG
/// Debug-only: PUBLIC Supabase/Edge values supplied via scheme / UI-test launch environment are remembered, so a
/// launch without that environment (system prewarm, BG refresh, relaunch after `activate()`) is still configured.
/// Only public values (project URL, publishable key, edge origin, scope id) ever pass through here.
public enum CatpawDebugPublicConfig {
    static let key = "catpaw.debug.publicConfig.v1"
    public static func remember(_ values: [String: String], defaults: UserDefaults = .standard) -> [String: String] {
        let present = values.filter { !$0.value.isEmpty }
        if !present.isEmpty { var stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]; stored.merge(present) { $1 }; defaults.set(stored, forKey: key); return values }
        guard let stored = defaults.dictionary(forKey: key) as? [String: String] else { return values }
        return values.merging(stored) { old, new in old.isEmpty ? new : old }
    }
}
#endif
