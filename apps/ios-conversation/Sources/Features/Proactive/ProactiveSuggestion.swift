import Foundation

// Wave 2 demo · proactive meeting / travel assistant. Card + 主动 inbox behind `ProactiveSuggestionBackend`, mock data
// until 三角 exposes the API (see PR body): GET /catpaw/proactive/v1/suggestions, POST …/suggestions/{id}/action,
// POST …/suggestions/{id}/feedback, POST …/suggestions/{id}/undo; SSE/`catpaw-card` kind `proactive_suggestion`.

/// ```catpaw-card `{"kind":"proactive_suggestion","id":"s1","title":"…","reason":"…","memories":[{"id","content"}],
///   "actions":["create_reminder","notify_attendees","snooze","dismiss"],"signals":[{"kind":"calendar","text":"…"}]}`
struct ProactiveSuggestion: Codable, Sendable, Equatable, Identifiable {
    enum Action: String, Codable, Sendable, CaseIterable { case create_reminder, notify_attendees, snooze, dismiss }
    enum Status: String, Codable, Sendable { case pending, done, snoozed, dismissed }
    struct MemoryRef: Codable, Sendable, Equatable, Identifiable { let id: String; let content: String }
    struct Signal: Codable, Sendable, Equatable { let kind: String; let text: String }
    struct Taken: Codable, Sendable, Equatable {
        let action: Action; let at: Date; var detail: String?
        /// Codex P0-5: per-action outcome (nil on older records: a create_reminder entry is a success).
        var outcome: ProactiveActionState? = nil
    }

    let id: String
    var title: String
    var reason: String
    var memories: [MemoryRef]? = nil
    var actions: [Action]? = nil
    var signals: [Signal]? = nil
    var status: Status? = nil
    var createdAt: Date? = nil
    var taken: [Taken]? = nil
    /// Codex PR90 #4: the cloud's per-action state (`action_states`, e.g. {"notify_attendees":"done"}).
    var serverActionStates: [String: String]? = nil
    /// NoBug: the trigger this suggestion came from (feedback weights are keyed by it; cloud sends the same field).
    var trigger: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, title, reason, memories, actions, signals, status, createdAt, taken, trigger
        case serverActionStates = "action_states"
    }

    var usedMemories: [MemoryRef] { memories ?? [] }
    var effectiveActions: [Action] { actions ?? Action.allCases }
    var effectiveStatus: Status { status ?? .pending }
    /// Codex P0-5: latest outcome per action, derived from `taken` (so undo, which trims `taken`, stays consistent).
    var actionStates: [String: ProactiveActionState] {
        var st: [String: ProactiveActionState] = [:]
        for t in taken ?? [] { st[t.action.rawValue] = t.outcome ?? (t.action == .create_reminder ? .succeeded : nil) ?? st[t.action.rawValue] }
        return ProactiveActionStates.merge(local: st, server: serverActionStates)
    }
    /// Actions still offered on the card (a created reminder no longer hides 「告诉参会人」).
    var remainingActions: [Action] {
        ProactiveActionStates.remaining(effectiveActions.map(\.rawValue), actionStates).compactMap(Action.init(rawValue:))
    }
    var allEffectsDone: Bool { ProactiveActionStates.allEffectsDone(effectiveActions.map(\.rawValue), actionStates) }
}

enum ProactiveFeedback: String, Codable, Sendable, CaseIterable { case helpful, not_helpful, intrusive }

@MainActor protocol ProactiveSuggestionBackend: AnyObject {
    func list() async throws -> [ProactiveSuggestion]
    func perform(_ action: ProactiveSuggestion.Action, on id: String) async throws -> ProactiveSuggestion
    func undo(_ id: String) async throws -> ProactiveSuggestion
    func feedback(_ value: ProactiveFeedback, on id: String) async throws
}

@MainActor final class ProactiveSuggestionMock: ProactiveSuggestionBackend {
    private var items: [String: ProactiveSuggestion]
    init(_ seed: [ProactiveSuggestion] = ProactiveSuggestionMock.samples) { items = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) }) }
    func list() async throws -> [ProactiveSuggestion] { items.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) } }
    func perform(_ action: ProactiveSuggestion.Action, on id: String) async throws -> ProactiveSuggestion {
        try? await Task.sleep(for: .milliseconds(350))
        var s = items[id] ?? ProactiveSuggestion(id: id, title: "", reason: "")
        s.status = switch action {
        case .create_reminder: .done
        case .notify_attendees: s.status ?? .pending  // real MessageUI path is ProactiveLocalBackend only
        case .snooze: .snoozed
        case .dismiss: .dismissed
        }
        s.taken = (s.taken ?? []) + [.init(action: action, at: .now)]
        items[id] = s; return s
    }
    func undo(_ id: String) async throws -> ProactiveSuggestion {
        var s = items[id] ?? ProactiveSuggestion(id: id, title: "", reason: ""); s.status = .pending; s.taken = []; items[id] = s; return s
    }
    func feedback(_ value: ProactiveFeedback, on id: String) async throws {}
    func adopt(_ s: ProactiveSuggestion) { if items[s.id] == nil { items[s.id] = s } }
    /// Codex P0-5: the local cache must take updates (adopt only inserts).
    func upsert(_ s: ProactiveSuggestion) { items[s.id] = s }

    static let samples: [ProactiveSuggestion] = [
        .init(id: "demo-meeting", title: "该出发去望京 SOHO 了", reason: "因为你 10:30 有会，地铁 25 分钟",
              memories: [.init(id: "m1", content: "住在北京望京"), .init(id: "m6", content: "通勤习惯坐地铁")],
              signals: [.init(kind: "calendar", text: "10:30 与张三开会 · 望京 SOHO T1"), .init(kind: "travel", text: "地铁 14 号线约 25 分钟"), .init(kind: "time", text: "现在 09:50")],
              createdAt: .now),
        .init(id: "demo-flight", title: "航班延误 40 分钟", reason: "CA1234 延误，你 15:00 的会可能赶不上",
              memories: [.init(id: "m7", content: "常坐国航")], signals: [.init(kind: "travel", text: "CA1234 预计 14:20 到达")],
              status: .done, createdAt: .now.addingTimeInterval(-3600), taken: [.init(action: .notify_attendees, at: .now.addingTimeInterval(-3500))]),
        .init(id: "demo-coffee", title: "附近有你喜欢的咖啡", reason: "会前还有 15 分钟", memories: [.init(id: "m3", content: "咖啡只喝燕麦拿铁")],
              status: .dismissed, createdAt: .now.addingTimeInterval(-7200)),
    ]
}

@MainActor enum ProactiveSuggestionHub {
    /// 三角 replaces with the real client; mock by default for the demo.
    static var backend: any ProactiveSuggestionBackend = ProactiveSuggestionMock()
}

/// Shared state for cards in chat and the inbox.
@MainActor final class ProactiveSuggestionStore: ObservableObject {
    static let shared = ProactiveSuggestionStore()
    @Published private(set) var items: [String: ProactiveSuggestion] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published var errorKey: String?
    private var backend: any ProactiveSuggestionBackend { ProactiveSuggestionHub.backend }

    func current(_ s: ProactiveSuggestion) -> ProactiveSuggestion { items[s.id] ?? s }
    /// Codex PR90c #1: sign-out / switch — nothing of the previous account stays on screen.
    func resetForAccountChange() { items = [:]; busy = []; errorKey = nil }
    /// Persistence hook for a merged card (set by the real backend).
    var onMerged: ((ProactiveSuggestion) -> Void)?
    func adopt(_ s: ProactiveSuggestion) {
        if var existing = items[s.id] {
            // Codex PR90c #6: an existing card takes the cloud's newer success states (never loses one it had).
            let merged = ProactiveActionStates.mergeServer(existing: existing.serverActionStates, incoming: s.serverActionStates)
            if merged != (existing.serverActionStates ?? [:]) {
                existing.serverActionStates = merged
                if existing.allEffectsDone { existing.status = .done }
                items[s.id] = existing
                onMerged?(existing)   // Codex PR90d: persisted, so a reload from disk cannot resurrect the action
            }
        } else { items[s.id] = s }
        (backend as? ProactiveSuggestionMock)?.adopt(s)
    }
    func load() async {
        do { for s in try await backend.list() { items[s.id] = s }; errorKey = nil } catch { errorKey = "暂时连不上服务，请稍后重试" }
    }
    func perform(_ action: ProactiveSuggestion.Action, _ s: ProactiveSuggestion) async {
        busy.insert(s.id); defer { busy.remove(s.id) }
        do { items[s.id] = try await backend.perform(action, on: s.id); errorKey = nil }
        catch let e as ProactiveEngineError where e == .smsUnavailable { errorKey = "本机无法打开短信（模拟器上常见），未标记完成" }
        catch { errorKey = "没有完成，请稍后重试" }
    }
    func undo(_ s: ProactiveSuggestion) async {
        busy.insert(s.id); defer { busy.remove(s.id) }
        do { items[s.id] = try await backend.undo(s.id); errorKey = nil } catch { errorKey = "没有完成，请稍后重试" }
    }
    func feedback(_ value: ProactiveFeedback, _ s: ProactiveSuggestion) async { try? await backend.feedback(value, on: s.id) }
    func sorted(_ status: ProactiveSuggestion.Status) -> [ProactiveSuggestion] {
        items.values.filter { $0.effectiveStatus == status || (status == .pending && $0.effectiveStatus == .snoozed) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}
