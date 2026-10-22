import Foundation

/// catpaw.family.v1 wire types (docs/design/family-companion/api-v1.md). Server facts only:
/// an item is "已安排" only when the projection lists it under `today.schedule`.
public enum FamilyProtocol { public static let name = "catpaw.family.v1"; public static let prefix = "/catpaw/family/v1" }

public struct FamilySource: Codable, Sendable, Equatable { public let source_kind: String; public let source_ref: String; public let captured_at: String? }

public struct FamilyScheduleEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { item_id }
    public let item_id: UUID; public let revision: Int; public let title: String; public let status: String
    public let member_id: UUID?; public let child_display_name: String?
    public let local_date: String?; public let local_time: String?; public let timezone: String?
    public let place: String?; public let bring: [String]
}
public struct FamilyPendingConfirmation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { item_id }
    public let item_id: UUID; public let revision: Int; public let proposal_id: UUID; public let title: String
    public let member_id: UUID?; public let child_display_name: String?
    public let local_date: String?; public let local_time: String?; public let place: String?; public let bring: [String]
    public let source_kind: String?
}
public struct FamilyReminder: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { reminder_id }
    public let reminder_id: UUID; public let item_id: UUID; public let kind: String; public let why_now: String; public let fire_at: String; public let revision: Int
}
public struct FamilyChild: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { member_id }
    public let member_id: UUID; public let display_name: String; public let birth_year: Int?
    public let school_label: String?; public let class_label: String?; public let teacher_label: String?; public let place_label: String?; public let notes: String?
    public let revision: Int
}
public struct FamilyMemory: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { memory_id }
    public let memory_id: UUID; public let member_id: UUID?; public let text: String; public let source: FamilySource?; public let revision: Int
}
public struct FamilyObservation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { observation_id }
    public let observation_id: UUID; public let member_id: UUID; public let text: String; public let observed_on: String; public let revision: Int
}
public struct FamilyHousehold: Codable, Sendable, Equatable { public let household_id: UUID; public let name: String; public let timezone: String; public let revision: Int }
public struct FamilySettings: Codable, Sendable, Equatable { public let memory_paused: Bool; public let reminders_paused: Bool; public let revision: Int }

public struct FamilyProjection: Codable, Sendable, Equatable {
    public struct Today: Codable, Sendable, Equatable { public let schedule: [FamilyScheduleEntry]; public let pending_confirmations: [FamilyPendingConfirmation]; public let reminders: [FamilyReminder] }
    public struct Home: Codable, Sendable, Equatable {
        public let household: FamilyHousehold?; public let children: [FamilyChild]; public let memories: [FamilyMemory]?; public let observations: [FamilyObservation]; public let settings: FamilySettings?
    }
    public let protocol_: String; public let household_id: UUID; public let projection_revision: Int; public let local_date: String; public let timezone: String
    public let today: Today; public let home: Home
    enum CodingKeys: String, CodingKey { case protocol_ = "protocol", household_id, projection_revision, local_date, timezone, today, home }
}

public struct FamilyReceipt: Codable, Sendable, Equatable {
    public struct Object: Codable, Sendable, Equatable { public let type: String; public let id: UUID; public let revision: Int }
    public struct Failure: Codable, Sendable, Equatable { public let code: String; public let recoverable: String }
    public let command_id: UUID; public let status: String; public let objects: [Object]; public let error: Failure?
    public var applied: Bool { status == "applied" }
}

/// JSON value for command payloads (strings, integers, bools, arrays, null only: api-v1 §5 forbids non-integers).
public indirect enum FamilyJSON: Codable, Sendable, Equatable {
    case string(String), int(Int), bool(Bool), array([FamilyJSON]), object([String: FamilyJSON]), null
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) } else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) } else if let v = try? c.decode([FamilyJSON].self) { self = .array(v) } else { self = .object(try c.decode([String: FamilyJSON].self)) }
    }
}

public struct FamilyCommand: Codable, Sendable, Equatable {
    public let command_id: UUID; public let type: String; public let household_id: UUID
    public var target_id: UUID?; public var expected_revision: Int?; public var proposal_id: UUID?
    public var payload: [String: FamilyJSON]?; public var consent: [String: FamilyJSON]?
    /// command_id is generated once and kept for retries of the same intent (api-v1 §1, §5).
    public init(type: String, household: UUID, target: UUID? = nil, expectedRevision: Int? = nil, proposal: UUID? = nil, payload: [String: FamilyJSON]? = nil, consent: [String: FamilyJSON]? = nil, id: UUID = UUID()) {
        command_id = id; self.type = type; household_id = household; target_id = target; expected_revision = expectedRevision; proposal_id = proposal; self.payload = payload; self.consent = consent
    }
}

public struct FamilyCaptureCard: Codable, Sendable, Equatable {
    public struct Candidate: Codable, Sendable, Equatable { public let title: String; public let local_date: String?; public let local_time: String?; public let member_id: UUID?; public let place: String?; public let bring: [String]; public let missing: [String] }
    public let receipt: FamilyReceipt; public let item_id: UUID?; public let proposal_id: UUID?; public let candidate: Candidate
}
public struct FamilyCaptureResponse: Codable, Sendable, Equatable { public let capture_id: UUID; public let cards: [FamilyCaptureCard] }

public enum FamilyError: Error, Equatable { case unavailable, notFound, conflict(String), rejected(String), invalidResponse, outcomeUnknown(UUID) }
