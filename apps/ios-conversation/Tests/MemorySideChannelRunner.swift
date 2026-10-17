import Foundation
// Portable check for the #63 side channel: every fixture event type is a known side-channel type, the installed
// handler receives type/turnID/raw data unchanged, and the payload case carries the same bytes.
final class SideChannelLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [(String, UUID, Data)] = []
    func add(_ v: (String, UUID, Data)) { lock.lock(); items.append(v); lock.unlock() }
    var all: [(String, UUID, Data)] { lock.lock(); defer { lock.unlock() }; return items }
}
@main struct MemorySideChannelRunner {
    static func main() throws {
        func check(_ condition: Bool, _ text: String) throws { guard condition else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let wire = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else { throw CatpawError.invalid("fixture") }
        ConversationSideChannelEvents.dispatch(type: "memory.used", turnID: UUID(), data: Data("{}".utf8), token: nil)
        try check(ConversationSideChannelEvents.handler == nil, "dispatch without an installed handler is a no-op")
        let log = SideChannelLog(), turn = UUID()
        ConversationSideChannelEvents.handler = { type, turnID, data, _ in log.add((type, turnID, data)) }
        for event in wire {
            let type = event["type"] as? String ?? ""
            try check(ConversationSideChannelEvents.types.contains(type), "fixture type \(type) is a side-channel type")
            let data = try JSONSerialization.data(withJSONObject: event["data"] ?? [:])
            ConversationSideChannelEvents.dispatch(type: type, turnID: turn, data: data, token: nil)
            let payload = ConversationTurnEvent.Payload.sideChannel(type: type, data: data)
            if case let .sideChannel(t, d) = payload { try check(t == type && d == data, "payload carries \(type) bytes") }
        }
        let got = log.all
        try check(got.count == wire.count && got.allSatisfy({ $0.1 == turn }), "handler saw every event with the turn id")
        let used = try JSONSerialization.jsonObject(with: got[0].2) as? [String: Any]
        try check((used?["ids"] as? [String])?.count == 1, "memory.used raw data is passed through")
        ConversationSideChannelEvents.handler = nil
    }
}
