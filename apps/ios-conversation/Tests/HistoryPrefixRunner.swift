import Foundation
// Regression: an old client left user messages in the local transcript that the server never admitted and that
// have no notSent turn record, so dispatchHistory cannot filter them. prepare()/validateHistory must accept a
// server history that is a strict prefix (extras = user messages only) for plain turns, and stay strict otherwise.
@main struct HistoryPrefixRunner {
    static func main() throws {
        func check(_ condition: Bool, _ text: String) throws { guard condition else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        func conflict(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch CatpawError.conflict { return true } catch { return false } }
        let scope = Profiles.user
        let conversation = UUID()
        let admittedUser = ConversationTranscriptMessage(role: .user, content: "早")
        let admittedReply = ConversationTranscriptMessage(role: .assistant, content: "早上好")
        let orphanA = ConversationTranscriptMessage(role: .user, content: "你是？")
        let orphanB = ConversationTranscriptMessage(role: .user, content: "在吗")
        let current = ConversationTranscriptMessage(role: .user, content: "现在呢")
        func wire(_ m: ConversationTranscriptMessage) -> [String: Any] { ["id": m.id.uuidString.lowercased(), "role": m.role.rawValue, "content": m.content] }
        func request(_ history: [ConversationTranscriptMessage]) -> ConversationTurnRequest { .init(scope: scope, conversationID: conversation, threadID: nil, operationID: UUID(), epoch: 1, history: history) }
        let legacy = request([orphanA, orphanB, current])
        let unsent = try NativeChatHTTPBackend.checkServerHistory([], request: legacy, strict: false)
        try check(unsent == [orphanA.id, orphanB.id], "legacy unsent messages without notSent records are tolerated when the server has none; only the current message is posted")
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([], request: legacy, strict: true) }, "frozen-history requests stay strict")
        let mixed = request([admittedUser, admittedReply, orphanA, current])
        try check(try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply)], request: mixed, strict: false) == [orphanA.id], "server strict prefix: only the unadmitted local tail is treated as unsent")
        try check(try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply), wire(orphanA)], request: mixed, strict: true).isEmpty, "exact match still passes strictly")
        var edited = wire(admittedReply); edited["content"] = "改过的回复"
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), edited], request: mixed, strict: false) }, "prefix with different content is still a conflict")
        var failedNotice = ConversationTranscriptMessage(role: .assistant, content: "消息尚未发送，输入已保留。内容已更新", complete: true)
        failedNotice.failure = "notSent"
        let stuck = request([orphanA, failedNotice, orphanB, current])
        let stuckEmpty = try NativeChatHTTPBackend.checkServerHistory([], request: stuck, strict: false)
        try check(stuckEmpty == [orphanA.id, failedNotice.id, orphanB.id], "old stuck chat: unsent user + local failed assistant notice without server ids are local-only when the server is empty")
        let stuckPartial = request([admittedUser, admittedReply, orphanA, failedNotice, orphanB, current])
        let partialUnsent = try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply)], request: stuckPartial, strict: false)
        try check(partialUnsent == [orphanA.id, failedNotice.id, orphanB.id], "old stuck chat: server holds the earlier part; only confirmed messages are compared")
        let interleaved = request([admittedUser, failedNotice, admittedReply, current])
        let interleavedUnsent = try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply)], request: interleaved, strict: false)
        try check(interleavedUnsent == [failedNotice.id], "a local-only failure notice between confirmed messages is skipped, not compared")
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([], request: stuck, strict: true) }, "frozen-history requests stay strict with local-only notices")
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([wire(admittedReply), wire(admittedUser)], request: mixed, strict: false) }, "confirmed messages in a different order are a conflict")
        let longer = request([admittedUser, admittedReply, current])
        let realigned = try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply), wire(orphanB)], request: longer, strict: false)
        try check(realigned.isEmpty, "plain turn: server longer than local realigns on the server instead of conflicting")
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply), wire(orphanB)], request: longer, strict: true) }, "strict request: server longer than local is still a conflict")
        // Device log: local=[user:B1D31D0D:complete:4] server=[user:b09acdc3:-:128]
        let serverOnly: [String: Any] = ["id": UUID().uuidString.lowercased(), "role": "user", "content": String(repeating: "x", count: 128)]
        let logged = request([ConversationTranscriptMessage(role: .user, content: "你好吗？")])
        try check(try NativeChatHTTPBackend.checkServerHistory([serverOnly], request: logged, strict: false).isEmpty, "logged stuck chat: one server-only user message, local only the current message, realigns and sends")
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([serverOnly], request: logged, strict: true) }, "logged stuck chat stays a conflict for strict requests")
    }
}
