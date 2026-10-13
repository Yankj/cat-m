import Foundation

struct MemoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    var content: String
    var kind: Kind
    var confidence: Double
    var createdAt: Date
    var source: String

    enum Kind: String, Codable, CaseIterable {
        case profile = "偏好"
        case episodic = "事件"
        case procedural = "习惯"
    }

    init(id: UUID = UUID(), content: String, kind: Kind, confidence: Double = 0.9, source: String = "用户确认") {
        self.id = id
        self.content = content
        self.kind = kind
        self.confidence = confidence
        self.createdAt = .now
        self.source = source
    }
}

struct ProactiveItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var reason: String
    var actionPreview: String
    var risk: Risk
    var createdAt: Date

    enum Risk: String {
        case low, medium, high
    }

    init(id: UUID = UUID(), title: String, reason: String, actionPreview: String, risk: Risk = .medium) {
        self.id = id
        self.title = title
        self.reason = reason
        self.actionPreview = actionPreview
        self.risk = risk
        self.createdAt = .now
    }
}

struct ActionLog: Identifiable {
    let id: UUID
    let description: String
    let timestamp: Date
    let outcome: String

    init(id: UUID = UUID(), description: String, outcome: String) {
        self.id = id
        self.description = description
        self.timestamp = .now
        self.outcome = outcome
    }
}
