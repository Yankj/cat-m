import Foundation

/// CGUI-1 is presentation data. These values never accept a turn, grant approval, or execute effects.
public enum CGUILimits {
    public static let payloadBytes = 65_536
    public static let tableColumns = 12
    public static let tableRows = 200
    public static let cellCharacters = 2_000
    public static let chartSeries = 4
    public static let pointsPerSeries = 200
    public static let sourceReferences = 20
    public static let titleCharacters = 200
    public static let labelCharacters = 80
}

public struct CGUIValidationError: Error, LocalizedError, Sendable, Equatable {
    public let field: String
    public let reason: String
    public init(_ field: String, _ reason: String) { self.field = field; self.reason = reason }
    public var errorDescription: String? { "\(field): \(reason)" }
}

/// Decimal text is retained exactly; JSON numbers and binary floating point are not calculator inputs.
/// The character bound is the CGUI cell bound, preventing unbounded arithmetic within a valid envelope.
public struct CGUIDecimal: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String
    public init(_ value: String) throws {
        _ = try CGUIExactDecimal(value, field: "number")
        rawValue = value
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    /// Approximation for drawing only. Computation and formatted results use exact decimal arithmetic.
    public var doubleValue: Double { Double(rawValue) ?? 0 }
    /// Optional Foundation representation for native controls; exact sorting uses `compared(to:)`.
    public var decimalValue: Decimal? { Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) }
    public var bankersDisplay: String { display() }
    public func compared(to other: Self) -> ComparisonResult {
        let a = try! CGUIExactDecimal(rawValue, field: "number", maximumCharacters: 4_012), b = try! CGUIExactDecimal(other.rawValue, field: "number", maximumCharacters: 4_012)
        if a.negative != b.negative { return a.negative ? .orderedAscending : .orderedDescending }
        let comparison = a.comparedMagnitude(to: b) * (a.negative ? -1 : 1)
        return comparison < 0 ? .orderedAscending : comparison > 0 ? .orderedDescending : .orderedSame
    }
    public func display(scale: Int = 2) -> String { (try? CGUIExactDecimal(rawValue, field: "number", maximumCharacters: 4_012).display(scale: min(12, max(0, scale)))) ?? rawValue }
    fileprivate init(exactResult value: String) { rawValue = value }
}

public struct CGUIArtifactIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let contentHash: String
    public init(id: String, version: Int, contentHash: String) { self.id = id; self.version = version; self.contentHash = contentHash }
}
public struct CGUIIdentity: Codable, Sendable, Equatable {
    public let blockID: String
    public let conversationID: UUID
    public let turnID: UUID
    public let dataRevision: Int
    public let cardID: String?
    public let objectID: String?
    public let objectRevision: Int?
    public let artifact: CGUIArtifactIdentity?
    public init(blockID: String, conversationID: UUID, turnID: UUID, dataRevision: Int, cardID: String? = nil, objectID: String? = nil, objectRevision: Int? = nil, artifact: CGUIArtifactIdentity? = nil) {
        self.blockID = blockID; self.conversationID = conversationID; self.turnID = turnID; self.dataRevision = dataRevision
        self.cardID = cardID; self.objectID = objectID; self.objectRevision = objectRevision; self.artifact = artifact
    }
}
public enum CGUIPresentation: String, Codable, Sendable { case table, chart, calculator }
public enum CGUIDomainCard: String, Codable, Sendable { case choice, form, plan, approval, artifact, comparison }
public struct CGUISource: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case userProvided = "user_provided", readArtifact = "read_artifact", assumption }
    public let id: String
    public let label: String
    public let kind: Kind
    /// An opaque source reference, never a request or executable URL.
    public let reference: String?
    public let contentHash: String?
    public init(id: String, label: String, kind: Kind, reference: String? = nil, contentHash: String? = nil) { self.id = id; self.label = label; self.kind = kind; self.reference = reference; self.contentHash = contentHash }
}
public struct CGUITableColumn: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let unit: String?
    public init(id: String, label: String, unit: String? = nil) { self.id = id; self.label = label; self.unit = unit }
}
public struct CGUITableCell: Codable, Sendable, Equatable {
    public let text: String?
    public let number: CGUIDecimal?
    public let sourceIDs: [String]
    public init(text: String? = nil, number: CGUIDecimal? = nil, sourceIDs: [String]) { self.text = text; self.number = number; self.sourceIDs = sourceIDs }
    public var readableValue: String { text ?? number?.rawValue ?? "" }
}
public struct CGUITableRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let cells: [CGUITableCell]
    public init(id: String, cells: [CGUITableCell]) { self.id = id; self.cells = cells }
}
public struct CGUITable: Codable, Sendable, Equatable {
    public let columns: [CGUITableColumn]
    public let rows: [CGUITableRow]
    public init(columns: [CGUITableColumn], rows: [CGUITableRow]) { self.columns = columns; self.rows = rows }
}
public struct CGUIChartPoint: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let value: CGUIDecimal
    public let sourceIDs: [String]
    public init(id: String, label: String, value: CGUIDecimal, sourceIDs: [String]) { self.id = id; self.label = label; self.value = value; self.sourceIDs = sourceIDs }
}
public struct CGUIChartSeries: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let points: [CGUIChartPoint]
    public init(id: String, label: String, points: [CGUIChartPoint]) { self.id = id; self.label = label; self.points = points }
}
public struct CGUIChart: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case bar, line }
    public let kind: Kind
    public let unit: String
    public let series: [CGUIChartSeries]
    public init(kind: Kind, unit: String, series: [CGUIChartSeries]) { self.kind = kind; self.unit = unit; self.series = series }
}
public struct CGUIDurationBudgetInput: Codable, Sendable, Equatable {
    public let unit: String
    public let total: CGUIDecimal
    public let reserved: CGUIDecimal
    public let stepCount: Int
    public let perStep: CGUIDecimal
    public init(total: CGUIDecimal, reserved: CGUIDecimal, stepCount: Int, perStep: CGUIDecimal, unit: String = "minutes") { self.unit = unit; self.total = total; self.reserved = reserved; self.stepCount = stepCount; self.perStep = perStep }
}
public struct CGUIWeightedDimension: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let weight: CGUIDecimal
    public init(id: String, label: String, weight: CGUIDecimal) { self.id = id; self.label = label; self.weight = weight }
}
public struct CGUIWeightedOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// Scores follow the dimension order; no generated formula or missing-score substitution.
    public let scores: [CGUIDecimal]
    public let sourceIDs: [String]
    public init(id: String, label: String, scores: [CGUIDecimal], sourceIDs: [String]) { self.id = id; self.label = label; self.scores = scores; self.sourceIDs = sourceIDs }
}
public struct CGUIWeightedComparisonInput: Codable, Sendable, Equatable {
    public let unit: String
    public let dimensions: [CGUIWeightedDimension]
    public let options: [CGUIWeightedOption]
    public init(dimensions: [CGUIWeightedDimension], options: [CGUIWeightedOption], unit: String = "score_0_100") { self.unit = unit; self.dimensions = dimensions; self.options = options }
}
public enum CGUIKernel: String, Codable, Sendable { case durationBudget = "duration_budget_v1", weightedComparison = "weighted_comparison_v1" }
public struct CGUICalculatorPayload: Codable, Sendable, Equatable {
    public let kernel: CGUIKernel
    public let kernelVersion: Int
    public let duration: CGUIDurationBudgetInput?
    public let weighted: CGUIWeightedComparisonInput?
    public init(duration: CGUIDurationBudgetInput) { kernel = .durationBudget; kernelVersion = 1; self.duration = duration; weighted = nil }
    public init(weighted: CGUIWeightedComparisonInput) { kernel = .weightedComparison; kernelVersion = 1; duration = nil; self.weighted = weighted }
}
public enum CGUIActionClass: String, Codable, Sendable { case localInteraction = "local_interaction", agentFollowup = "agent_followup", domainCommand = "domain_command" }
public enum CGUIRegisteredAction: String, Codable, Sendable {
    case reset, sort, filter, selectPoint = "select_point", updateInputs = "update_inputs"
    case useSelection = "use_selection", explainSelection = "explain_selection"
    case referencedCommand = "referenced_command"
    public var actionClass: CGUIActionClass {
        switch self {
        case .reset, .sort, .filter, .selectPoint, .updateInputs: return .localInteraction
        case .useSelection, .explainSelection: return .agentFollowup
        case .referencedCommand: return .domainCommand
        }
    }
}
public struct CGUICommandReference: Codable, Sendable, Equatable {
    public let actionID: String
    public let objectID: String
    public let objectRevision: Int
    public init(actionID: String, objectID: String, objectRevision: Int) { self.actionID = actionID; self.objectID = objectID; self.objectRevision = objectRevision }
}
public struct CGUIAction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let actionClass: CGUIActionClass
    public let action: CGUIRegisteredAction
    /// Reference only. A service must re-read authority before exposing a command submission.
    public let command: CGUICommandReference?
    public init(id: String, label: String, action: CGUIRegisteredAction, command: CGUICommandReference? = nil) { self.id = id; self.label = label; self.action = action; actionClass = action.actionClass; self.command = command }
}
public struct CGUIFallback: Codable, Sendable, Equatable {
    public let text: String
    public let artifact: CGUIArtifactIdentity?
    public init(text: String, artifact: CGUIArtifactIdentity? = nil) { self.text = text; self.artifact = artifact }
}
public struct CGUIBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: String { identity.blockID }
    public let identity: CGUIIdentity
    public let presentation: CGUIPresentation
    public let schemaVersion: Int
    public let rendererVersion: Int
    public let card: CGUIDomainCard?
    public let title: String
    public let summary: String
    public let sources: [CGUISource]
    public let actions: [CGUIAction]
    public let fallback: CGUIFallback
    public let table: CGUITable?
    public let chart: CGUIChart?
    public let calculator: CGUICalculatorPayload?
    public init(identity: CGUIIdentity, presentation: CGUIPresentation, schemaVersion: Int = 1, rendererVersion: Int = 1, card: CGUIDomainCard? = nil, title: String, summary: String, sources: [CGUISource], actions: [CGUIAction] = [], fallback: CGUIFallback, table: CGUITable? = nil, chart: CGUIChart? = nil, calculator: CGUICalculatorPayload? = nil) {
        self.identity = identity; self.presentation = presentation; self.schemaVersion = schemaVersion; self.rendererVersion = rendererVersion; self.card = card; self.title = title; self.summary = summary; self.sources = sources; self.actions = actions; self.fallback = fallback; self.table = table; self.chart = chart; self.calculator = calculator
    }
}
public struct CGUIReadableFallback: Sendable, Equatable {
    public let text: String
    public let reason: CGUIValidationError
    public let identity: CGUIIdentity?
    public let artifact: CGUIArtifactIdentity?
    /// A fallback carries no actionable payload.
    public init(text: String, reason: CGUIValidationError, identity: CGUIIdentity? = nil, artifact: CGUIArtifactIdentity? = nil) { self.text = text; self.reason = reason; self.identity = identity; self.artifact = artifact }
}
public enum CGUIDecodeResult: Sendable, Equatable { case ready(CGUIBlock), fallback(CGUIReadableFallback) }

public enum CGUIRegistry {
    public static let schemaVersion = 1
    public static let rendererVersion = 1
    public static let kernels: Set<CGUIKernel> = [.durationBudget, .weightedComparison]

    public static func decode(_ data: Data) -> CGUIDecodeResult {
        guard data.count <= CGUILimits.payloadBytes else { return failure(CGUIValidationError("payload", "payload_too_large")) }
        guard String(data: data, encoding: .utf8) != nil else { return failure(CGUIValidationError("payload", "invalid_utf8")) }
        var readable: String?
        var identity: CGUIIdentity?
        var artifact: CGUIArtifactIdentity?
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CGUIValidationError("payload", "expected_object") }
            if let fallback = root["fallback"] as? [String: Any], let text = fallback["text"] as? String, !text.isEmpty, text.count <= CGUILimits.cellCharacters { readable = text }
            if let raw = root["identity"], JSONSerialization.isValidJSONObject(raw) {
                identity = try? JSONDecoder().decode(CGUIIdentity.self, from: JSONSerialization.data(withJSONObject: raw))
                if let candidate = identity, (try? validateIdentity(candidate)) == nil { identity = nil }
            }
            if let candidate = identity?.artifact { artifact = candidate }
            guard root["schemaVersion"] as? Int == schemaVersion else { throw CGUIValidationError("schemaVersion", "unsupported_schema_version") }
            guard root["rendererVersion"] as? Int == rendererVersion else { throw CGUIValidationError("rendererVersion", "unsupported_renderer_version") }
            guard let presentation = root["presentation"] as? String, CGUIPresentation(rawValue: presentation) != nil else { throw CGUIValidationError("presentation", "unsupported_presentation") }
            try validateShape(root)
            let block = try JSONDecoder().decode(CGUIBlock.self, from: data)
            try validate(block)
            return .ready(block)
        } catch {
            let reason = (error as? CGUIValidationError) ?? CGUIValidationError("payload", "invalid_schema")
            return failure(reason, text: readable, identity: identity, artifact: artifact)
        }
    }
    public static func validate(_ block: CGUIBlock) throws {
        guard block.schemaVersion == schemaVersion else { throw CGUIValidationError("schemaVersion", "unsupported_schema_version") }
        guard block.rendererVersion == rendererVersion else { throw CGUIValidationError("rendererVersion", "unsupported_renderer_version") }
        try validateIdentity(block.identity)
        try bounded(block.title, CGUILimits.titleCharacters, "title", required: true)
        try bounded(block.summary, CGUILimits.cellCharacters, "summary")
        try bounded(block.fallback.text, CGUILimits.cellCharacters, "fallback.text", required: true)
        if let artifact = block.fallback.artifact { try validateArtifact(artifact, field: "fallback.artifact") }
        guard (1...CGUILimits.sourceReferences).contains(block.sources.count) else { throw CGUIValidationError("sources", "source_count") }
        try unique(block.sources.map(\.id), "sources")
        for source in block.sources {
            try identifier(source.id, "sources.id"); try bounded(source.label, CGUILimits.labelCharacters, "sources.label", required: true)
            if source.kind != .assumption { guard let reference = source.reference else { throw CGUIValidationError("sources.reference", "missing_source") }; try bounded(reference, CGUILimits.cellCharacters, "sources.reference", required: true) }
            if let reference = source.reference { try bounded(reference, CGUILimits.cellCharacters, "sources.reference") }
            if let hash = source.contentHash { try hashValue(hash, "sources.contentHash") }
        }
        let sourceIDs = Set(block.sources.map(\.id))
        guard [block.table != nil, block.chart != nil, block.calculator != nil].filter({ $0 }).count == 1 else { throw CGUIValidationError("data", "exactly_one_presentation_payload") }
        switch block.presentation {
        case .table:
            guard let table = block.table else { throw CGUIValidationError("table", "presentation_mismatch") }
            try validateTable(table, sources: sourceIDs)
        case .chart:
            guard let chart = block.chart else { throw CGUIValidationError("chart", "presentation_mismatch") }
            try validateChart(chart, sources: sourceIDs)
        case .calculator:
            guard let calculator = block.calculator else { throw CGUIValidationError("calculator", "presentation_mismatch") }
            guard calculator.kernelVersion == 1 else { throw CGUIValidationError("calculator.kernelVersion", "unsupported_kernel_version") }
            switch calculator.kernel {
            case .durationBudget:
                guard let input = calculator.duration, calculator.weighted == nil else { throw CGUIValidationError("calculator", "kernel_payload_mismatch") }
                _ = try CGUICalculator.duration(input)
            case .weightedComparison:
                guard let input = calculator.weighted, calculator.duration == nil else { throw CGUIValidationError("calculator", "kernel_payload_mismatch") }
                _ = try CGUICalculator.weighted(input)
                for option in input.options { try references(option.sourceIDs, sources: sourceIDs, field: "calculator.weighted.options.sourceIDs") }
            }
        }
        guard block.actions.count <= 12 else { throw CGUIValidationError("actions", "action_count") }
        try unique(block.actions.map(\.id), "actions")
        for action in block.actions {
            try identifier(action.id, "actions.id"); try bounded(action.label, CGUILimits.labelCharacters, "actions.label", required: true)
            guard action.actionClass == action.action.actionClass else { throw CGUIValidationError("actions.actionClass", "action_class_mismatch") }
            switch action.action {
            case .sort, .filter: guard block.presentation == .table else { throw CGUIValidationError("actions.action", "action_not_registered_for_presentation") }
            case .selectPoint: guard block.presentation == .chart else { throw CGUIValidationError("actions.action", "action_not_registered_for_presentation") }
            case .updateInputs: guard block.presentation == .calculator else { throw CGUIValidationError("actions.action", "action_not_registered_for_presentation") }
            case .referencedCommand:
                guard let command = action.command, command.objectID == block.identity.objectID, command.objectRevision == block.identity.objectRevision, command.objectRevision > 0 else { throw CGUIValidationError("actions.command", "missing_or_mismatched_command_reference") }
                try identifier(command.actionID, "actions.command.actionID"); try identifier(command.objectID, "actions.command.objectID")
            case .reset, .useSelection, .explainSelection: break
            }
            if action.actionClass != .domainCommand, action.command != nil { throw CGUIValidationError("actions.command", "command_on_non_domain_action") }
        }
        let data = try JSONEncoder().encode(block)
        guard data.count <= CGUILimits.payloadBytes else { throw CGUIValidationError("payload", "payload_too_large") }
    }
    private static func failure(_ reason: CGUIValidationError, text: String? = nil, identity: CGUIIdentity? = nil, artifact: CGUIArtifactIdentity? = nil) -> CGUIDecodeResult {
        .fallback(CGUIReadableFallback(text: text ?? "该内容暂时无法展示。原回答仍可阅读，请从原工作查看完整成果。", reason: reason, identity: identity, artifact: artifact))
    }
    private static func validateIdentity(_ value: CGUIIdentity) throws {
        try identifier(value.blockID, "identity.blockID")
        guard value.dataRevision > 0 else { throw CGUIValidationError("identity.dataRevision", "invalid_revision") }
        if let cardID = value.cardID { try identifier(cardID, "identity.cardID") }
        guard (value.objectID == nil) == (value.objectRevision == nil) else { throw CGUIValidationError("identity.objectRevision", "incomplete_object_identity") }
        if let objectID = value.objectID { try identifier(objectID, "identity.objectID"); guard value.objectRevision! > 0 else { throw CGUIValidationError("identity.objectRevision", "invalid_revision") } }
        if let artifact = value.artifact { try validateArtifact(artifact, field: "identity.artifact") }
    }
    private static func validateArtifact(_ value: CGUIArtifactIdentity, field: String) throws {
        try identifier(value.id, field + ".id")
        guard value.version > 0 else { throw CGUIValidationError(field + ".version", "invalid_revision") }
        try hashValue(value.contentHash, field + ".contentHash")
    }
    private static func validateTable(_ table: CGUITable, sources: Set<String>) throws {
        guard (1...CGUILimits.tableColumns).contains(table.columns.count), (1...CGUILimits.tableRows).contains(table.rows.count) else { throw CGUIValidationError("table", "table_limits") }
        try unique(table.columns.map(\.id), "table.columns"); try unique(table.rows.map(\.id), "table.rows")
        for column in table.columns { try identifier(column.id, "table.columns.id"); try bounded(column.label, CGUILimits.labelCharacters, "table.columns.label", required: true); if let unit = column.unit { try bounded(unit, CGUILimits.labelCharacters, "table.columns.unit", required: true) } }
        for row in table.rows {
            try identifier(row.id, "table.rows.id")
            guard row.cells.count == table.columns.count else { throw CGUIValidationError("table.rows.cells", "column_count_mismatch") }
            for (index, cell) in row.cells.enumerated() {
                guard (cell.text == nil) != (cell.number == nil) else { throw CGUIValidationError("table.rows.cells", "exactly_one_cell_value") }
                if let text = cell.text { try bounded(text, CGUILimits.cellCharacters, "table.rows.cells.text") }
                if let number = cell.number { _ = try CGUIExactDecimal(number.rawValue, field: "table.rows.cells.number"); guard table.columns[index].unit != nil else { throw CGUIValidationError("table.columns.unit", "missing_numeric_unit") } }
                try references(cell.sourceIDs, sources: sources, field: "table.rows.cells.sourceIDs")
            }
        }
    }
    private static func validateChart(_ chart: CGUIChart, sources: Set<String>) throws {
        try bounded(chart.unit, CGUILimits.labelCharacters, "chart.unit", required: true)
        guard (1...CGUILimits.chartSeries).contains(chart.series.count) else { throw CGUIValidationError("chart.series", "series_limits") }
        try unique(chart.series.map(\.id), "chart.series")
        for series in chart.series {
            try identifier(series.id, "chart.series.id"); try bounded(series.label, CGUILimits.labelCharacters, "chart.series.label", required: true)
            guard (1...CGUILimits.pointsPerSeries).contains(series.points.count) else { throw CGUIValidationError("chart.series.points", "point_limits") }
            try unique(series.points.map(\.id), "chart.series.points")
            for point in series.points {
                try identifier(point.id, "chart.series.points.id"); try bounded(point.label, CGUILimits.labelCharacters, "chart.series.points.label", required: true)
                let exact = try CGUIExactDecimal(point.value.rawValue, field: "chart.series.points.value")
                guard let drawable = Double(point.value.rawValue), drawable.isFinite, drawable != 0 || exact.coefficient.isZero else { throw CGUIValidationError("chart.series.points.value", "not_representable_in_native_chart") }
                try references(point.sourceIDs, sources: sources, field: "chart.series.points.sourceIDs")
            }
        }
    }
    fileprivate static func bounded(_ value: String, _ limit: Int, _ field: String, required: Bool = false) throws {
        guard value.count <= limit else { throw CGUIValidationError(field, "text_too_long") }
        if required, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CGUIValidationError(field, "required") }
    }
    fileprivate static func identifier(_ value: String, _ field: String) throws { try bounded(value, CGUILimits.labelCharacters, field, required: true) }
    fileprivate static func unique(_ values: [String], _ field: String) throws { guard Set(values).count == values.count else { throw CGUIValidationError(field, "duplicate_identity") } }
    private static func hashValue(_ value: String, _ field: String) throws { guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CGUIValidationError(field, "invalid_sha256") } }
    private static func references(_ values: [String], sources: Set<String>, field: String) throws {
        guard !values.isEmpty, values.count <= CGUILimits.sourceReferences, Set(values).count == values.count, values.allSatisfy({ sources.contains($0) }) else { throw CGUIValidationError(field, "missing_or_unknown_source") }
    }
    /// Reject extra fields, including generated formulas/code, instead of silently decoding them away.
    private static func validateShape(_ root: [String: Any]) throws {
        func object(_ value: Any?, keys: Set<String>, field: String) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw CGUIValidationError(field, "invalid_or_unknown_fields") }; return value
        }
        func objects(_ value: Any?, field: String) throws -> [[String: Any]] { guard let values = value as? [[String: Any]] else { throw CGUIValidationError(field, "expected_object_array") }; return values }
        func artifact(_ value: Any?, _ field: String) throws { if value != nil { _ = try object(value, keys: ["id", "version", "contentHash"], field: field) } }
        _ = try object(root, keys: ["identity", "presentation", "schemaVersion", "rendererVersion", "card", "title", "summary", "sources", "actions", "fallback", "table", "chart", "calculator"], field: "payload")
        let identity = try object(root["identity"], keys: ["blockID", "conversationID", "turnID", "dataRevision", "cardID", "objectID", "objectRevision", "artifact"], field: "identity"); try artifact(identity["artifact"], "identity.artifact")
        let fallback = try object(root["fallback"], keys: ["text", "artifact"], field: "fallback"); try artifact(fallback["artifact"], "fallback.artifact")
        for source in try objects(root["sources"], field: "sources") { _ = try object(source, keys: ["id", "label", "kind", "reference", "contentHash"], field: "sources") }
        for action in try objects(root["actions"], field: "actions") { _ = try object(action, keys: ["id", "label", "actionClass", "action", "command"], field: "actions"); if let command = action["command"] { _ = try object(command, keys: ["actionID", "objectID", "objectRevision"], field: "actions.command") } }
        if let raw = root["table"] {
            let table = try object(raw, keys: ["columns", "rows"], field: "table")
            for column in try objects(table["columns"], field: "table.columns") { _ = try object(column, keys: ["id", "label", "unit"], field: "table.columns") }
            for row in try objects(table["rows"], field: "table.rows") { _ = try object(row, keys: ["id", "cells"], field: "table.rows"); for cell in try objects(row["cells"], field: "table.rows.cells") { _ = try object(cell, keys: ["text", "number", "sourceIDs"], field: "table.rows.cells") } }
        }
        if let raw = root["chart"] {
            let chart = try object(raw, keys: ["kind", "unit", "series"], field: "chart")
            for series in try objects(chart["series"], field: "chart.series") { _ = try object(series, keys: ["id", "label", "points"], field: "chart.series"); for point in try objects(series["points"], field: "chart.series.points") { _ = try object(point, keys: ["id", "label", "value", "sourceIDs"], field: "chart.series.points") } }
        }
        if let raw = root["calculator"] {
            let calculator = try object(raw, keys: ["kernel", "kernelVersion", "duration", "weighted"], field: "calculator")
            if let duration = calculator["duration"] { _ = try object(duration, keys: ["unit", "total", "reserved", "stepCount", "perStep"], field: "calculator.duration") }
            if let raw = calculator["weighted"] {
                let weighted = try object(raw, keys: ["unit", "dimensions", "options"], field: "calculator.weighted")
                for dimension in try objects(weighted["dimensions"], field: "calculator.weighted.dimensions") { _ = try object(dimension, keys: ["id", "label", "weight"], field: "calculator.weighted.dimensions") }
                for option in try objects(weighted["options"], field: "calculator.weighted.options") { _ = try object(option, keys: ["id", "label", "scores", "sourceIDs"], field: "calculator.weighted.options") }
            }
        }
    }
}

public struct CGUIDurationBudgetResult: Sendable, Equatable {
    public let kernel = CGUIKernel.durationBudget
    public let unit = "minutes"
    public let remaining: CGUIDecimal
    public let displayRemaining: String
    public let isOverBudget: Bool
}
/// A normalized weighted score is an exact decimal ratio; repeating values are never stored as a rounded original.
public struct CGUIExactRatio: Codable, Sendable, Equatable {
    public let numerator: CGUIDecimal
    public let denominator: CGUIDecimal
    public var doubleValue: Double {
        let a = try! CGUIExactDecimal(numerator.rawValue, field: "numerator", maximumCharacters: 4_012), b = try! CGUIExactDecimal(denominator.rawValue, field: "denominator", maximumCharacters: 4_012)
        if a.coefficient.isZero { return 0 }
        let aDigits = a.coefficient.text, bDigits = b.coefficient.text, aPrefix = aDigits.prefix(17), bPrefix = bDigits.prefix(17)
        let exponent = aDigits.count - aPrefix.count - a.scale - bDigits.count + bPrefix.count + b.scale
        return Double(aPrefix)! / Double(bPrefix)! * pow(10, Double(exponent))
    }
    private enum CodingKeys: CodingKey { case numerator, denominator }
    init(numerator: CGUIDecimal, denominator: CGUIDecimal) { self.numerator = numerator; self.denominator = denominator }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self), n = try container.decode(String.self, forKey: .numerator), d = try container.decode(String.self, forKey: .denominator)
        let numerator = try CGUIExactDecimal(n, field: "numerator", maximumCharacters: 4_012), denominator = try CGUIExactDecimal(d, field: "denominator", maximumCharacters: 4_012)
        guard !numerator.negative, !denominator.negative, !denominator.coefficient.isZero, numerator.comparedMagnitude(to: denominator.multiplied(by: CGUIExactDecimal(integer: 100))) <= 0 else { throw CGUIValidationError("ratio", "invalid_normalized_score_ratio") }
        self.numerator = CGUIDecimal(exactResult: n); self.denominator = CGUIDecimal(exactResult: d)
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.container(keyedBy: CodingKeys.self); try container.encode(numerator.rawValue, forKey: .numerator); try container.encode(denominator.rawValue, forKey: .denominator) }
}
public struct CGUIWeightedResult: Sendable, Equatable, Identifiable {
    public var id: String { optionID }
    public let optionID: String
    public let score: CGUIExactRatio
    public let displayScore: String
}
public enum CGUICalculator {
    public static let durationFormula = "total - reserved - stepCount × perStep"
    public static let weightedFormula = "Σ(score × weight) / Σ(weight)"
    public static let roundingRule = "bankers"

    public static func duration(_ input: CGUIDurationBudgetInput) throws -> CGUIDurationBudgetResult {
        guard input.unit == "minutes" else { throw CGUIValidationError("duration.unit", "unit_mismatch") }
        let total = try ranged(input.total, maximum: 10_080, field: "duration.total")
        let reserved = try ranged(input.reserved, maximum: 10_080, field: "duration.reserved")
        let perStep = try ranged(input.perStep, maximum: 10_080, field: "duration.perStep")
        guard (0...200).contains(input.stepCount) else { throw CGUIValidationError("duration.stepCount", "integer_out_of_range") }
        let remaining = total.subtracting(reserved).subtracting(perStep.multiplied(by: CGUIExactDecimal(integer: input.stepCount)))
        return CGUIDurationBudgetResult(remaining: CGUIDecimal(exactResult: remaining.text), displayRemaining: remaining.display(scale: 2), isOverBudget: remaining.negative && !remaining.coefficient.isZero)
    }
    public static func weighted(_ input: CGUIWeightedComparisonInput) throws -> [CGUIWeightedResult] {
        guard input.unit == "score_0_100" else { throw CGUIValidationError("weighted.unit", "unit_mismatch") }
        guard (1...12).contains(input.dimensions.count) else { throw CGUIValidationError("weighted.dimensions", "dimension_count") }
        guard (2...12).contains(input.options.count) else { throw CGUIValidationError("weighted.options", "option_count") }
        try CGUIRegistry.unique(input.dimensions.map(\.id), "weighted.dimensions"); try CGUIRegistry.unique(input.options.map(\.id), "weighted.options")
        var weights: [CGUIExactDecimal] = []
        for (index, dimension) in input.dimensions.enumerated() {
            try CGUIRegistry.identifier(dimension.id, "weighted.dimensions[\(index)].id"); try CGUIRegistry.bounded(dimension.label, CGUILimits.labelCharacters, "weighted.dimensions[\(index)].label", required: true)
            weights.append(try ranged(dimension.weight, maximum: 100, field: "weighted.dimensions[\(index)].weight"))
        }
        let denominator = weights.reduce(CGUIExactDecimal(integer: 0), { $0.adding($1) })
        guard !denominator.coefficient.isZero else { throw CGUIValidationError("weighted.dimensions.weight", "total_weight_must_be_positive") }
        return try input.options.enumerated().map { index, option in
            try CGUIRegistry.identifier(option.id, "weighted.options[\(index)].id"); try CGUIRegistry.bounded(option.label, CGUILimits.labelCharacters, "weighted.options[\(index)].label", required: true)
            guard option.scores.count == weights.count else { throw CGUIValidationError("weighted.options[\(index)].scores", "dimension_count_mismatch") }
            var numerator = CGUIExactDecimal(integer: 0)
            for (dimension, raw) in option.scores.enumerated() { let score = try ranged(raw, maximum: 100, field: "weighted.options[\(index)].scores[\(dimension)]"); numerator = numerator.adding(score.multiplied(by: weights[dimension])) }
            let ratio = CGUIExactRatio(numerator: CGUIDecimal(exactResult: numerator.text), denominator: CGUIDecimal(exactResult: denominator.text))
            return CGUIWeightedResult(optionID: option.id, score: ratio, displayScore: ratioDisplay(numerator, denominator))
        }
    }
    private static func ranged(_ raw: CGUIDecimal, maximum: Int, field: String) throws -> CGUIExactDecimal {
        let value = try CGUIExactDecimal(raw.rawValue, field: field)
        guard !value.negative || value.coefficient.isZero, value.comparedMagnitude(to: CGUIExactDecimal(integer: maximum)) <= 0 else { throw CGUIValidationError(field, "decimal_out_of_range") }
        return value
    }
    /// The score is in [0,100]. Compare exact integers to find hundredths, then round ties to even.
    private static func ratioDisplay(_ numerator: CGUIExactDecimal, _ denominator: CGUIExactDecimal) -> String {
        let scale = max(numerator.scale, denominator.scale)
        let n = numerator.coefficient.scaledByPowerOfTen(scale - numerator.scale + 2)
        let d = denominator.coefficient.scaledByPowerOfTen(scale - denominator.scale)
        var lower = 0, upper = 10_001
        while lower + 1 < upper { let middle = (lower + upper) / 2; if d.multiplied(by: UInt32(middle)) <= n { lower = middle } else { upper = middle } }
        let remainder = n.subtracting(d.multiplied(by: UInt32(lower)))
        let comparison = remainder.multiplied(by: 2).compared(to: d)
        if comparison > 0 || (comparison == 0 && lower % 2 == 1) { lower += 1 }
        return "\(lower / 100)." + String(format: "%02d", lower % 100)
    }
}

/// Small bounded decimal-integer arithmetic. No Double, NSDecimal precision loss, eval, or external dependency.
private struct CGUIMagnitude: Comparable {
    private static let base: UInt64 = 1_000_000_000
    private var words: [UInt32]
    init(_ digits: String) {
        var words: [UInt32] = [], end = digits.endIndex
        while end > digits.startIndex { let start = digits.index(end, offsetBy: -min(9, digits.distance(from: digits.startIndex, to: end))); words.append(UInt32(digits[start..<end])!); end = start }
        self.words = words; normalize()
    }
    private init(words: [UInt32]) { self.words = words; normalize() }
    private mutating func normalize() { while words.count > 1 && words.last == 0 { words.removeLast() }; if words.isEmpty { words = [0] } }
    var isZero: Bool { words.count == 1 && words[0] == 0 }
    var text: String { String(words.last!) + words.dropLast().reversed().map { String(format: "%09u", $0) }.joined() }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.compared(to: rhs) < 0 }
    func compared(to other: Self) -> Int {
        if words.count != other.words.count { return words.count < other.words.count ? -1 : 1 }
        for (a, b) in zip(words.reversed(), other.words.reversed()) { if a != b { return a < b ? -1 : 1 } }; return 0
    }
    func adding(_ other: Self) -> Self {
        var result: [UInt32] = [], carry: UInt64 = 0
        for index in 0..<max(words.count, other.words.count) { let value = UInt64(index < words.count ? words[index] : 0) + UInt64(index < other.words.count ? other.words[index] : 0) + carry; result.append(UInt32(value % Self.base)); carry = value / Self.base }
        if carry != 0 { result.append(UInt32(carry)) }; return Self(words: result)
    }
    /// Caller compares magnitudes first, so unsigned subtraction cannot underflow.
    func subtracting(_ other: Self) -> Self {
        precondition(self >= other)
        var result: [UInt32] = [], borrow: Int64 = 0
        for index in words.indices { var value = Int64(words[index]) - Int64(index < other.words.count ? other.words[index] : 0) - borrow; if value < 0 { value += Int64(Self.base); borrow = 1 } else { borrow = 0 }; result.append(UInt32(value)) }; return Self(words: result)
    }
    func multiplied(by factor: UInt32) -> Self {
        var result: [UInt32] = [], carry: UInt64 = 0
        for word in words { let value = UInt64(word) * UInt64(factor) + carry; result.append(UInt32(value % Self.base)); carry = value / Self.base }
        while carry > 0 { result.append(UInt32(carry % Self.base)); carry /= Self.base }; return Self(words: result)
    }
    func multiplied(by other: Self) -> Self {
        if isZero || other.isZero { return Self("0") }
        var result = [UInt32](repeating: 0, count: words.count + other.words.count)
        for a in words.indices {
            var carry: UInt64 = 0
            for b in other.words.indices { let index = a + b, value = UInt64(words[a]) * UInt64(other.words[b]) + UInt64(result[index]) + carry; result[index] = UInt32(value % Self.base); carry = value / Self.base }
            result[a + other.words.count] = UInt32(carry)
        }
        return Self(words: result)
    }
    func scaledByPowerOfTen(_ power: Int) -> Self {
        if isZero { return self }
        let powers: [UInt32] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]
        let multiplied = self.multiplied(by: powers[power % 9])
        return Self(words: [UInt32](repeating: 0, count: power / 9) + multiplied.words)
    }
}
private struct CGUIExactDecimal {
    let coefficient: CGUIMagnitude
    let scale: Int
    let negative: Bool
    init(integer: Int) { coefficient = CGUIMagnitude(String(abs(integer))); scale = 0; negative = integer < 0 }
    init(_ text: String, field: String, maximumCharacters: Int = CGUILimits.cellCharacters) throws {
        guard !text.isEmpty, text.utf8.count <= maximumCharacters else { throw CGUIValidationError(field, "invalid_decimal_length") }
        var bytes = Array(text.utf8), negative = false
        if bytes.first == 45 { negative = true; bytes.removeFirst() }
        guard !bytes.isEmpty else { throw CGUIValidationError(field, "finite_decimal_required") }
        var point: Int?
        for (index, byte) in bytes.enumerated() {
            if byte == 46, point == nil { point = index }
            else if !(48...57).contains(byte) { throw CGUIValidationError(field, "finite_decimal_required") }
        }
        if let point { guard point > 0, point < bytes.count - 1 else { throw CGUIValidationError(field, "finite_decimal_required") } }
        let digits = String(bytes: bytes.filter { $0 != 46 }, encoding: .utf8)!
        coefficient = CGUIMagnitude(digits); scale = point.map { bytes.count - $0 - 1 } ?? 0; self.negative = negative && !coefficient.isZero
    }
    private init(coefficient: CGUIMagnitude, scale: Int, negative: Bool) { self.coefficient = coefficient; self.scale = scale; self.negative = negative && !coefficient.isZero }
    var text: String {
        var digits = coefficient.text
        if scale > 0 { if digits.count <= scale { digits = String(repeating: "0", count: scale + 1 - digits.count) + digits }; digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale)); while digits.last == "0" { digits.removeLast() }; if digits.last == "." { digits.removeLast() } }
        return (negative ? "-" : "") + digits
    }
    func comparedMagnitude(to other: Self) -> Int { let scale = max(scale, other.scale); return coefficient.scaledByPowerOfTen(scale - self.scale).compared(to: other.coefficient.scaledByPowerOfTen(scale - other.scale)) }
    func adding(_ other: Self) -> Self {
        let scale = max(scale, other.scale), a = coefficient.scaledByPowerOfTen(scale - self.scale), b = other.coefficient.scaledByPowerOfTen(scale - other.scale)
        if negative == other.negative { return Self(coefficient: a.adding(b), scale: scale, negative: negative) }
        if a >= b { return Self(coefficient: a.subtracting(b), scale: scale, negative: negative) }
        return Self(coefficient: b.subtracting(a), scale: scale, negative: other.negative)
    }
    func subtracting(_ other: Self) -> Self { adding(Self(coefficient: other.coefficient, scale: other.scale, negative: !other.negative)) }
    func multiplied(by other: Self) -> Self { Self(coefficient: coefficient.multiplied(by: other.coefficient), scale: scale + other.scale, negative: negative != other.negative) }
    func display(scale target: Int) -> String {
        var digits = coefficient.text
        if scale > target {
            if digits.count <= scale - target { digits = String(repeating: "0", count: scale - target + 1 - digits.count) + digits }
            let split = digits.index(digits.endIndex, offsetBy: -(scale - target)), prefix = String(digits[..<split]), tail = digits[split...]
            var rounded = CGUIMagnitude(prefix)
            let first = tail.first!, greater = first > "5" || (first == "5" && tail.dropFirst().contains(where: { $0 != "0" })), tie = first == "5" && tail.dropFirst().allSatisfy({ $0 == "0" })
            if greater || (tie && Int(prefix.last!.asciiValue! - 48) % 2 == 1) { rounded = rounded.adding(CGUIMagnitude("1")) }; digits = rounded.text
        } else { digits += String(repeating: "0", count: target - scale) }
        if target > 0 { if digits.count <= target { digits = String(repeating: "0", count: target + 1 - digits.count) + digits }; digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -target)) }
        let isZero = digits.allSatisfy { $0 == "0" || $0 == "." }
        return (negative && !isZero ? "-" : "") + digits
    }
}
