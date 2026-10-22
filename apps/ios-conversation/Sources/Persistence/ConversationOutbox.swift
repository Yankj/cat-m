import Foundation

/// R7 §5.2/§5.3 offline outbox. A plain text turn that could not be sent (never POSTed) is
/// recorded here on disk so it survives a killed process, then re-sent with the SAME
/// operationID (= clientMessageID; the Edge deduplicates by turn_id) once the path is usable.
public struct ConversationOutboxEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID            // original operationID / clientMessageID
    public let scope: DataScope
    public let conversationID: UUID
    public let text: String
    public let enqueuedAt: Date
    public var attempts: Int
    public init(id: UUID, scope: DataScope, conversationID: UUID, text: String, enqueuedAt: Date = Date(), attempts: Int = 0) {
        self.id = id; self.scope = scope; self.conversationID = conversationID; self.text = text; self.enqueuedAt = enqueuedAt; self.attempts = attempts
    }
}

public actor ConversationOutbox {
    public static let maxEntries = 50
    private let fileURL: URL
    private var cache: [ConversationOutboxEntry]?
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func entries() -> [ConversationOutboxEntry] { load() }
    public func entries(conversationID: UUID) -> [ConversationOutboxEntry] { load().filter { $0.conversationID == conversationID } }
    public func contains(_ id: UUID) -> Bool { load().contains { $0.id == id } }

    /// Idempotent by operationID.
    public func enqueue(_ entry: ConversationOutboxEntry) throws {
        var all = load()
        guard !all.contains(where: { $0.id == entry.id }) else { return }
        guard all.count < Self.maxEntries else { throw catError.invalid("待发消息过多，请联网后再发送。") }
        all.append(entry); try persist(all)
    }
    public func remove(_ id: UUID) throws {
        var all = load(); let before = all.count
        all.removeAll { $0.id == id }
        if all.count != before { try persist(all) }
    }
    public func recordAttempt(_ id: UUID) throws {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].attempts += 1; try persist(all)
    }

    private func load() -> [ConversationOutboxEntry] {
        if let cache { return cache }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([ConversationOutboxEntry].self, from: $0) } ?? []
        cache = value; return value
    }
    private func persist(_ value: [ConversationOutboxEntry]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
        cache = value
    }
}
