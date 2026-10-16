import Foundation

/// Minimal key-value persistence the queue needs (UserDefaults conforms; tests inject an in-memory store).
protocol CatpawKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: CatpawKeyValueStore {}

/// Codex PR90 #5: small generic persistent outbox for write-backs that must survive restarts and failures
/// (proactive action/undo sync; reusable by 三角 for feedback retry).
/// - `enqueue` dedupes by `key` (use the operation's idempotency key), so a replay never sends twice.
/// - `drain` sends due items in FIFO order; `.done` removes it (exactly once), `.retry` backs off exponentially,
///   `.drop` discards. After `maxAttempts` an item moves to `deadLetters` (kept for diagnostics, never resent).
/// - Items are bound to the account they were created for and are only sent while that account is signed in;
///   `purge(account:)` on sign-out. Re-entrant `drain` calls are ignored while one is running.
@MainActor final class CatpawPersistentQueue<Op: Codable & Sendable> {
    struct Item: Codable, Sendable {
        let key: String; var op: Op; var account: String?
        /// Ordering group (e.g. the suggestion id): items of one group are sent strictly FIFO; a failure blocks the rest.
        var group: String? = nil
        var attempts: Int; var nextAt: Double; let enqueuedAt: Double
    }
    enum Result: Sendable { case done, retry, drop }
    private struct Saved: Codable { var items: [Item]; var dead: [Item]; var poisoned: [String]? = nil }

    let name: String
    private let store: CatpawKeyValueStore
    private let maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, maxDead = 50
    private var draining = false
    private(set) var items: [Item] = []
    private(set) var deadLetters: [Item] = []
    /// Codex PR90e: groups (account|group) whose op dead-lettered. Persisted; later ops of them are parked, never sent.
    private var poisoned: Set<String> = []
    private static func mark(_ account: String?, _ group: String) -> String { (account ?? "") + "|" + group }
    private var storageKey: String { "catpaw.queue.\(name).v1" }

    init(name: String, store: CatpawKeyValueStore = UserDefaults.standard, maxAttempts: Int = 8, baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 3600) {
        self.name = name; self.store = store; self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay
        if let d = store.data(forKey: storageKey), let s = try? JSONDecoder().decode(Saved.self, from: d) { items = s.items; deadLetters = s.dead; poisoned = Set(s.poisoned ?? []) }
    }
    private func persist() { store.set(try? JSONEncoder().encode(Saved(items: items, dead: deadLetters, poisoned: Array(poisoned))), forKey: storageKey) }

    /// Returns false when an item with this key is already queued (idempotent enqueue).
    /// `supersedes`: earlier, still-queued items of the same group this op makes pointless (e.g. dismiss over snooze).
    @discardableResult func enqueue(_ op: Op, key: String, account: String?, group: String? = nil, supersedes: ((Op) -> Bool)? = nil, now: Date = .now) -> Bool {
        guard !items.contains(where: { $0.key == key }) else { return false }
        if let group, poisoned.contains(Self.mark(account, group)) {   // its group already failed: keep the order, never send
            deadLetters.append(Item(key: key, op: op, account: account, group: group, attempts: 0, nextAt: now.timeIntervalSince1970, enqueuedAt: now.timeIntervalSince1970))
            if deadLetters.count > maxDead { deadLetters.removeFirst(deadLetters.count - maxDead) }
            persist(); return false
        }
        if let group, let supersedes { items.removeAll { $0.group == group && $0.account == account && supersedes($0.op) } }
        items.append(Item(key: key, op: op, account: account, group: group, attempts: 0, nextAt: now.timeIntervalSince1970, enqueuedAt: now.timeIntervalSince1970))
        persist(); return true
    }
    func remove(key: String) { items.removeAll { $0.key == key }; persist() }
    func contains(key: String) -> Bool { items.contains { $0.key == key } }
    func purge(account: String?) {
        items.removeAll { $0.account == account || account == nil }
        poisoned = account.map { a in poisoned.filter { !$0.hasPrefix(a + "|") } } ?? []
        persist()
    }
    /// Keep only `account`'s items (migration of unknown-owner data to the signed-in account).
    func retainOnly(account: String) {
        items.removeAll { ($0.account ?? "").caseInsensitiveCompare(account) != .orderedSame }
        poisoned = poisoned.filter { $0.lowercased().hasPrefix(account.lowercased() + "|") }
        persist()
    }

    @discardableResult func drain(now: Date = .now, account: String?, send: (Op) async -> Result) async -> (sent: Int, retried: Int, dropped: Int) {
        guard !draining else { return (0, 0, 0) }
        draining = true; defer { draining = false }
        var sent = 0, retried = 0, dropped = 0
        var blocked = Set<String>()
        let candidates = items.filter { $0.account == account }.map(\.key)
        for key in candidates {
            guard let item = items.first(where: { $0.key == key }) else { continue }
            if let g = item.group, blocked.contains(g) || poisoned.contains(Self.mark(item.account, g)) { continue }
            guard item.nextAt <= now.timeIntervalSince1970 else { if let g = item.group { blocked.insert(g) }; continue }
            let result = await send(item.op)
            guard let i = items.firstIndex(where: { $0.key == key }) else { continue }
            switch result {
            case .done: items.remove(at: i); sent += 1
            case .drop: items.remove(at: i); dropped += 1
            case .retry:
                items[i].attempts += 1
                if items[i].attempts >= maxAttempts {
                    let dead = items.remove(at: i); deadLetters.append(dead); dropped += 1
                    // Codex PR90d: a dead op poisons its group — later ops of it are parked with it, never sent out of order.
                    if let g = dead.group {
                        poisoned.insert(Self.mark(dead.account, g))
                        let later = items.filter { $0.group == g && $0.account == dead.account }
                        items.removeAll { $0.group == g && $0.account == dead.account }; deadLetters += later; dropped += later.count
                        blocked.insert(g)
                    }
                    if deadLetters.count > maxDead { deadLetters.removeFirst(deadLetters.count - maxDead) }
                } else {
                    items[i].nextAt = now.timeIntervalSince1970 + min(maxDelay, baseDelay * pow(2, Double(items[i].attempts - 1)))
                    retried += 1
                    if let g = items[i].group { blocked.insert(g) }  // keep this suggestion's later ops behind it
                }
            }
            persist()
        }
        return (sent, retried, dropped)
    }
}
