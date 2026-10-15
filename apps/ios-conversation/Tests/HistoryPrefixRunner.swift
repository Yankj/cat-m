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
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser)], request: mixed, strict: false) }, "an extra local assistant message (not a pure unsent user tail) is still a conflict")
        try check(conflict { try NativeChatHTTPBackend.checkServerHistory([wire(admittedUser), wire(admittedReply), wire(orphanB)], request: request([admittedUser, admittedReply, current]), strict: false) }, "server longer than local is still a conflict")
    }
}
