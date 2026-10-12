import Foundation
actor QueueSendLog {
    var ids: [UUID] = []
    var continuation: CheckedContinuation<Void,Never>?
    var waiting: CheckedContinuation<Void,Never>?
    func send(_ message: ConversationFollowup) async { ids.append(message.id); if ids.count == 1 { await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil } } }
    func untilFirst() async { if continuation != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func captured() -> [UUID] { ids }
}
@main struct ConversationQueueRunner {
    static func main() async throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("queue.json")
        let repo = try Repository(persistence: FilePersistence(url: path)), service = ConversationSessionService(repository: repo)
        let id = try await service.openLatest(scope: Profiles.user)
        let queue = ConversationFollowupQueueService(repository: repo, scope: Profiles.user, conversationID: id)
        func check(_ good: Bool, _ text: String) throws { guard good else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        let a = ConversationFollowup(text: "first"), b = ConversationFollowup(text: "second"), c = ConversationFollowup(text: "third")
        try await queue.enqueue(a); try await queue.enqueue(b)
        let log = QueueSendLog()
        let flush = Task { try await queue.flush { message in await log.send(message); return .sent } }
        await log.untilFirst()
        try await queue.enqueue(c)
        try await queue.flush { message in await log.send(message); return .sent }
        let crashed = ConversationFollowupQueueService(repository: try Repository(persistence: FilePersistence(url: path)), scope: Profiles.user, conversationID: id)
        let crashState = try await crashed.state()
        var inflightRejected = false
        do { try await crashed.resume() } catch ConversationSessionError.unresolvedOperation { inflightRejected = true }
        try check(crashState.paused && crashState.inflight?.id == a.id && inflightRejected, "restart with durable in-flight intent holds original identity instead of dispatching again")
        let before = await log.captured()
        try check(before == [a.id], "one active run while new follow-ups can be added")
        try await queue.pause(); await log.release(); try await flush.value
        var state = try await queue.state()
        try check(state.paused && state.pending.map(\.id) == [b.id,c.id], "pause holds ordered follow-ups and never sends the next message")
        let disk = ConversationFollowupQueueService(repository: try Repository(persistence: FilePersistence(url: path)), scope: Profiles.user, conversationID: id)
        state = try await disk.state()
        try check(state.paused && state.pending.map(\.text) == ["second","third"], "held follow-ups survive real repository restart")
        try await queue.resume(); try await queue.flush { message in await log.send(message); return .sent }
        let order = await log.captured()
        try check(order == [a.id,b.id,c.id], "explicit resume drains follow-ups in order once")
        let d = ConversationFollowup(text: "server refused before admission")
        try await queue.enqueue(d); try await queue.flush { _ in .heldBeforeAdmission }
        state = try await queue.state()
        try check(state.paused && state.pending.map(\.id) == [d.id], "known pre-admission refusal restores same message to queue front on hold")
        try await queue.resume()
        do { try await queue.flush { message in await log.send(message); throw CatpawError.unavailable("explicit test failure after transcript admission") } } catch { }
        try await queue.resume(); try await queue.flush { message in await log.send(message); return .sent }
        let failures = await log.captured()
        try check(failures.filter { $0 == d.id }.count == 1, "failed admitted message is never implicitly resent")
        let e = ConversationFollowup(text: "remove only this")
        try await queue.enqueue(e); try await queue.remove(e.id)
        state = try await queue.state(); try check(state.pending.isEmpty, "user can remove an unsent follow-up")
        let cross = ConversationFollowupQueueService(repository: repo, scope: Profiles.demo, conversationID: id)
        var rejected = false; do { _ = try await cross.state() } catch CatpawError.scopeMismatch { rejected = true }
        try check(rejected, "queue state cannot cross scope")
        print("EVIDENCE: migrated public queue behavior; transport actions in tests are explicit test closures")
    }
}
