import Foundation

/// catpaw.ui.v1 — native generative-UI block (r10 spec §4, `render_ui` tool → SSE `ui.block`).
/// Contract: services/edge/docs/generative-ui-contract.md (三角, 64fc410/1e8e529). Interactive blocks are approval.v1
/// interrupts (`kind:'ui'`): `ui.block` carries `interruptId`/`argsHash`/`expiresAt`, the turn suspends, and the answer is
/// a decision (`submit`/`dismiss`/`report_error`) on the SAME turn. Unknown keys are ignored; unknown `kind` or
/// over-limit content degrades to a `card` (never raw JSON). Markdown and all block text are untrusted.
public enum GenerativeBlockLimits {
    public static let schemaVersion = 1
    public static let payloadBytes = 32_768
    public static let titleCharacters = 60
    public static let bodyCharacters = 600
    public static let items = 8, fields = 8, actions = 3, steps = 12
    public static let itemLabelCharacters = 40, actionLabelCharacters = 16
}

public struct GenerativeBlock: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case card, choices, confirm, form, sheet, list, progress }
    public enum Presentation: String, Codable, Sendable { case inline, sheet }
    public enum Selection: String, Codable, Sendable { case single, multiple, none }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: String; public let label: String; public var detail: String?; public var icon: String?
        public init(id: String, label: String, detail: String? = nil, icon: String? = nil) { self.id = id; self.label = label; self.detail = detail; self.icon = icon }
    }
    public struct Field: Codable, Sendable, Equatable, Identifiable {
        public enum FieldType: String, Codable, Sendable { case text, multiline, number, date, time, datetime, toggle, select, stepper }
        public let id: String; public let type: FieldType; public let label: String
        public var placeholder: String?; public var required: Bool?; public var options: [String]?
        public var `default`: GenerativeValue?
        public init(id: String, type: FieldType, label: String, placeholder: String? = nil, required: Bool? = nil, options: [String]? = nil, default value: GenerativeValue? = nil) {
            self.id = id; self.type = type; self.label = label; self.placeholder = placeholder; self.required = required; self.options = options; self.default = value
        }
    }
    public struct Action: Codable, Sendable, Equatable, Identifiable {
        public enum Style: String, Codable, Sendable { case primary, secondary, destructive }
        public let id: String; public let label: String; public var style: Style?
        public init(id: String, label: String, style: Style? = nil) { self.id = id; self.label = label; self.style = style }
    }
    /// PROPOSAL extension for `progress` (not in the r10 schema): ordered steps, patched via `ui.block.update`.
    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public enum State: String, Codable, Sendable { case pending, running, done, failed }
        public let id: String; public let label: String; public var state: State
        public init(id: String, label: String, state: State) { self.id = id; self.label = label; self.state = state }
    }

    public var schemaVersion: Int?
    public let id: String
    public let kind: Kind
    public var title: String?
    public var body: String?
    public var presentation: Presentation?
    public var image: URL?
    public var items: [Item]?
    public var selection: Selection?
    public var allowOther: Bool?
    public var fields: [Field]?
    public var actions: [Action]?
    public var steps: [Step]?
    public var expiresAt: Date?
    /// For `sheet`: the kind rendered inside the sheet (default form if fields, choices if items, else card).
    public var content: Kind?
    /// Server linkage, present only on blocks that wait for an answer (contract §0.2).
    public var interruptId: String?
    public var argsHash: String?

    public init(id: String, kind: Kind, title: String? = nil, body: String? = nil, presentation: Presentation? = nil, image: URL? = nil, items: [Item]? = nil, selection: Selection? = nil,
                allowOther: Bool? = nil, fields: [Field]? = nil, actions: [Action]? = nil, steps: [Step]? = nil, expiresAt: Date? = nil, content: Kind? = nil) {
        self.schemaVersion = GenerativeBlockLimits.schemaVersion; self.id = id; self.kind = kind; self.title = title; self.body = body; self.presentation = presentation; self.image = image
        self.items = items; self.selection = selection; self.allowOther = allowOther; self.fields = fields; self.actions = actions; self.steps = steps; self.expiresAt = expiresAt; self.content = content
    }
    public init(id: String, kind: Kind, title: String?, body: String?, interruptId: String?, argsHash: String?, expiresAt: Date?) {
        self.init(id: id, kind: kind, title: title, body: body, expiresAt: expiresAt); self.interruptId = interruptId; self.argsHash = argsHash
    }

    public func isExpired(at now: Date = .now) -> Bool { expiresAt.map { $0 <= now } ?? false }
    public var effectiveSelection: Selection { selection ?? (kind == .choices ? .single : .none) }
    /// Kind actually rendered (resolves `sheet.content`).
    public var contentKind: Kind {
        guard kind == .sheet else { return kind }
        return content ?? ((fields ?? []).isEmpty ? ((items ?? []).isEmpty ? .card : .choices) : .form)
    }
    /// Contract §0.4: which blocks wait for an answer. The server's `interruptId` is authoritative when present.
    public var needsAnswer: Bool {
        if interruptId != nil { return true }
        switch contentKind {
        case .choices: return !(effectiveSelection == .none && (actions ?? []).isEmpty)
        case .confirm, .form: return true
        case .card, .list: return !(actions ?? []).isEmpty
        case .progress, .sheet: return false
        }
    }
    public var opensAsSheet: Bool { kind == .sheet || presentation == .sheet || (kind == .form && (fields?.count ?? 0) > 4) }

    /// Shallow patch for `ui.block.update` (same id): non-nil fields replace.
    public func applying(_ patch: GenerativeBlockPatch) -> GenerativeBlock {
        var copy = self
        if let v = patch.title { copy.title = v }; if let v = patch.body { copy.body = v }; if let v = patch.items { copy.items = v }
        if let v = patch.actions { copy.actions = v }; if let v = patch.steps { copy.steps = v }; if let v = patch.expiresAt { copy.expiresAt = v }
        return copy
    }
}

/// `ui.block.resolve` data. status: submitted | dismissed | errored | expired | cancelled.
public struct GenerativeBlockResolution: Codable, Sendable, Equatable {
    public let id: String
    public let status: String
}

/// Decision on a ui interrupt (approval.v1 decision endpoint, contract §4). Same type as the network layer's
/// `ConversationUIDecision` (4454bee), kept as an alias so block code reads naturally.
public typealias GenerativeUIDecision = ConversationUIDecision

/// Implemented by `ConversationServiceUIDecisionSubmitter` over `ConversationSessionService.submitUIDecision`
/// (approval.v1 decision route; the DEBUG demo backend serves the same path). `response` is the encoded
/// `ui.response` (submit) or `ui.error` (report_error) JSON, nil for dismiss. Resend with the SAME `operationID` after
/// `.transport`. Throws `ConversationApprovalFailure` (`.expired`, `.consumed`, `.stale`, `.notFound`, `.rejected`, …).
/// The continuation events (approval_resolved, ui.block.resolve, …) flow through the normal turn event path.
public protocol GenerativeUIDecisionSubmitting: Sendable {
    func submitUIDecision(conversationID: UUID, turnID: UUID, interruptID: String, decision: GenerativeUIDecision, argsHash: String, response: Data?, operationID: UUID) async throws
}

public struct GenerativeBlockPatch: Codable, Sendable, Equatable {
    public let id: String
    public var title: String?, body: String?, items: [GenerativeBlock.Item]?, actions: [GenerativeBlock.Action]?, steps: [GenerativeBlock.Step]?, expiresAt: Date?
}

/// Field/response value. JSON: string | number | bool. Dates travel as ISO-8601 strings.
public enum GenerativeValue: Codable, Sendable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .number(let n): try c.encode(n); case .bool(let b): try c.encode(b) }
    }
    public var text: String {
        switch self { case .string(let s): s; case .number(let n): n.rounded() == n ? String(Int(n)) : String(n); case .bool(let b): b ? "true" : "false" }
    }
}

/// Client → server, delivered as the tool result of the `render_ui` call on the next turn.
public struct GenerativeBlockResponse: Codable, Sendable, Equatable {
    public var type = "ui.response"
    public let blockId: String
    public let actionId: String?
    public var values: [String: GenerativeValue]
    public var selected: [String]
    /// Free text for `allowOther` (PROPOSAL; also mirrored into `values["other"]`).
    public var other: String?
    public var respondedAt: Date
    public init(blockId: String, actionId: String?, values: [String: GenerativeValue] = [:], selected: [String] = [], other: String? = nil, respondedAt: Date = .now) {
        self.blockId = blockId; self.actionId = actionId; self.values = values; self.selected = selected; self.other = other; self.respondedAt = respondedAt
        if let other, !other.isEmpty { self.values["other"] = .string(other) }
    }
}

/// Client → server when a block fails validation (`ui.error`), so the model can correct itself.
public struct GenerativeBlockError: Codable, Sendable, Equatable {
    public var type = "ui.error"
    public let blockId: String?
    public let code: String
    public let path: String?
    /// Linkage salvaged from an invalid interactive block, so the error can be reported as `decision:"report_error"`.
    public var interruptId: String?
    public var argsHash: String?
    private enum CodingKeys: String, CodingKey { case type, blockId, code, path }
    public init(blockId: String?, code: String, path: String?, interruptId: String? = nil, argsHash: String? = nil) {
        self.blockId = blockId; self.code = code; self.path = path; self.interruptId = interruptId; self.argsHash = argsHash
    }
}

public enum GenerativeBlockDecodeResult: Sendable, Equatable {
    case ready(GenerativeBlock)
    /// Degraded card + the `ui.error` to report.
    case fallback(GenerativeBlock, GenerativeBlockError)
}

public enum GenerativeBlockCodec {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
        }
        return d
    }
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }

    /// Accepts the bare block or the `render_ui` arguments wrapper `{ "block": {...} }`.
    public static func decode(_ data: Data) -> GenerativeBlockDecodeResult {
        guard data.count <= GenerativeBlockLimits.payloadBytes else { return fallback(from: data, code: "payload_too_large", path: nil) }
        struct Wrapper: Decodable { let block: GenerativeBlock }
        let block: GenerativeBlock
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) { block = wrapped.block }
        else if let bare = try? decoder.decode(GenerativeBlock.self, from: data) { block = bare }
        else { return fallback(from: data, code: "schema_invalid", path: nil) }
        if var error = validate(block) { error.interruptId = block.interruptId; error.argsHash = block.argsHash; return .fallback(degrade(block), error) }
        return .ready(block)
    }

    public static func validate(_ b: GenerativeBlock) -> GenerativeBlockError? {
        func err(_ code: String, _ path: String) -> GenerativeBlockError { .init(blockId: b.id, code: code, path: path) }
        if let v = b.schemaVersion, v > GenerativeBlockLimits.schemaVersion { return err("schema_version_unsupported", "schemaVersion") }
        if b.id.isEmpty { return err("id_missing", "id") }
        if (b.interruptId == nil) != (b.argsHash == nil) { return err("schema_invalid", "interruptId") }
        if (b.title?.count ?? 0) > GenerativeBlockLimits.titleCharacters { return err("too_long", "title") }
        if (b.body?.count ?? 0) > GenerativeBlockLimits.bodyCharacters { return err("too_long", "body") }
        if (b.items?.count ?? 0) > GenerativeBlockLimits.items { return err("too_many", "items") }
        if b.items?.contains(where: { $0.label.count > GenerativeBlockLimits.itemLabelCharacters || $0.id.isEmpty }) == true { return err("invalid", "items") }
        if Set(b.items?.map(\.id) ?? []).count != (b.items?.count ?? 0) { return err("duplicate_id", "items") }
        if (b.fields?.count ?? 0) > GenerativeBlockLimits.fields { return err("too_many", "fields") }
        if Set(b.fields?.map(\.id) ?? []).count != (b.fields?.count ?? 0) { return err("duplicate_id", "fields") }
        if b.fields?.contains(where: { $0.type == .select && ($0.options ?? []).isEmpty }) == true { return err("options_missing", "fields") }
        if (b.actions?.count ?? 0) > GenerativeBlockLimits.actions { return err("too_many", "actions") }
        if b.actions?.contains(where: { $0.label.count > GenerativeBlockLimits.actionLabelCharacters }) == true { return err("too_long", "actions") }
        if (b.steps?.count ?? 0) > GenerativeBlockLimits.steps { return err("too_many", "steps") }
        if let url = b.image, url.scheme != "https" { return err("image_not_https", "image") }
        switch b.kind {
        case .choices: if (b.items ?? []).isEmpty { return err("items_missing", "items") }
        case .list: if (b.items ?? []).isEmpty { return err("items_missing", "items") }
        case .form: if (b.fields ?? []).isEmpty { return err("fields_missing", "fields") }
        case .progress: if (b.steps ?? []).isEmpty { return err("steps_missing", "steps") }
        case .card, .confirm, .sheet: break
        }
        return nil
    }

    static func degrade(_ b: GenerativeBlock) -> GenerativeBlock {
        GenerativeBlock(id: b.id, kind: .card, title: b.title.map { String($0.prefix(GenerativeBlockLimits.titleCharacters)) },
                        body: b.body.map { String($0.prefix(GenerativeBlockLimits.bodyCharacters)) }, interruptId: b.interruptId, argsHash: b.argsHash, expiresAt: b.expiresAt)
    }
    private static func fallback(from data: Data, code: String, path: String?) -> GenerativeBlockDecodeResult {
        // Salvage id/title/body without trusting the rest; never surface raw JSON.
        let object = (try? JSONSerialization.jsonObject(with: data.prefix(GenerativeBlockLimits.payloadBytes))) as? [String: Any]
        let raw = (object?["block"] as? [String: Any]) ?? object ?? [:]
        let id = (raw["id"] as? String) ?? "invalid-\(data.count)"
        let interrupt = raw["interruptId"] as? String, hash = raw["argsHash"] as? String
        let card = GenerativeBlock(id: id, kind: .card, title: (raw["title"] as? String).map { String($0.prefix(GenerativeBlockLimits.titleCharacters)) },
                                   body: (raw["body"] as? String).map { String($0.prefix(GenerativeBlockLimits.bodyCharacters)) }, interruptId: interrupt, argsHash: hash, expiresAt: nil)
        return .fallback(card, .init(blockId: raw["id"] as? String, code: code, path: path, interruptId: interrupt, argsHash: hash))
    }
}
