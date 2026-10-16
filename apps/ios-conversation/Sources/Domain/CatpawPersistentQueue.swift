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
        var attempts: Int; var nextAt: Double; let enqueuedAt: Double
    }
    enum Result: Sendable { case done, retry, drop }
    private struct Saved: Codable { var items: [Item]; var dead: [Item] }

    let name: String
    private let store: CatpawKeyValueStore
    private let maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, maxDead = 50
    private var draining = false
    private(set) var items: [Item] = []
    private(set) var deadLetters: [Item] = []
    private var storageKey: String { "catpaw.queue.\(name).v1" }

    init(name: String, store: CatpawKeyValueStore = UserDefaults.standard, maxAttempts: Int = 8, baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 3600) {
        self.name = name; self.store = store; self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay
        if let d = store.data(forKey: storageKey), let s = try? JSONDecoder().decode(Saved.self, from: d) { items = s.items; deadLetters = s.dead }
    }
    private func persist() { store.set(try? JSONEncoder().encode(Saved(items: items, dead: deadLetters)), forKey: storageKey) }

    /// Returns false when an item with this key is already queued (idempotent enqueue).
    @discardableResult func enqueue(_ op: Op, key: String, account: String?, now: Date = .now) -> Bool {
        guard !items.contains(where: { $0.key == key }) else { return false }
        items.append(Item(key: key, op: op, account: account, attempts: 0, nextAt: now.timeIntervalSince1970, enqueuedAt: now.timeIntervalSince1970))
        persist(); return true
    }
    func remove(key: String) { items.removeAll { $0.key == key }; persist() }
    func contains(key: String) -> Bool { items.contains { $0.key == key } }
    func purge(account: String?) { items.removeAll { $0.account == account || account == nil }; persist() }

    @discardableResult func drain(now: Date = .now, account: String?, send: (Op) async -> Result) async -> (sent: Int, retried: Int, dropped: Int) {
        guard !draining else { return (0, 0, 0) }
        draining = true; defer { draining = false }
        var sent = 0, retried = 0, dropped = 0
        let due = items.filter { $0.nextAt <= now.timeIntervalSince1970 && $0.account == account }.map(\.key)
        for key in due {
            guard let item = items.first(where: { $0.key == key }) else { continue }
            let result = await send(item.op)
            guard let i = items.firstIndex(where: { $0.key == key }) else { continue }
            switch result {
            case .done: items.remove(at: i); sent += 1
            case .drop: items.remove(at: i); dropped += 1
            case .retry:
                items[i].attempts += 1
                if items[i].attempts >= maxAttempts {
                    deadLetters.append(items.remove(at: i)); if deadLetters.count > maxDead { deadLetters.removeFirst(deadLetters.count - maxDead) }
                    dropped += 1
                } else {
                    items[i].nextAt = now.timeIntervalSince1970 + min(maxDelay, baseDelay * pow(2, Double(items[i].attempts - 1)))
                    retried += 1
                }
            }
            persist()
        }
        return (sent, retried, dropped)
    }
}
