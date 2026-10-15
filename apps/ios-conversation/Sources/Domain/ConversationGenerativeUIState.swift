import Foundation

/// Every local edit belongs to one account, conversation, original turn, and exact compiled data version.
public struct CGUILocalStateIdentity: Codable, Sendable, Equatable {
    public let scope: DataScope
    public let block: CGUIIdentity
    public let schemaVersion: Int
    public let rendererVersion: Int
    public let presentation: CGUIPresentation
    /// Also fences a producer that accidentally reuses a data revision with changed inputs.
    public let payloadHash: String
    public init(scope: DataScope, block: CGUIBlock) throws {
        try CGUIRegistry.validate(block)
        self.scope = scope; self.block = block.identity; schemaVersion = block.schemaVersion
        rendererVersion = block.rendererVersion; presentation = block.presentation
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        payloadHash = bytesHash(try encoder.encode(block))
    }
    public var recordID: UUID {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return stableID("conversation-ui-state-" + bytesHash(try! encoder.encode(self)))
    }
    public func isSameLineage(as other: Self) -> Bool {
        scope == other.scope && block.conversationID == other.block.conversationID && block.turnID == other.block.turnID && block.blockID == other.block.blockID
    }
}

/// Raw editing text is data, including "", "-", "12." and out-of-range input. Validation errors remain editable.
public struct CGUILocalState: Codable, Sendable, Equatable {
    public var tableFilter: String
    public var sortColumnID: String?
    public var sortAscending: Bool
    public var selectedSeriesID: String?
    public var selectedPointID: String?
    public var durationValues: [String]
    public var weightValues: [String]
    public static func defaults(for block: CGUIBlock) -> Self {
        let duration = block.calculator?.duration
        return Self(tableFilter: "", sortColumnID: nil, sortAscending: true,
                    selectedSeriesID: block.chart?.series.first?.id, selectedPointID: block.chart?.series.first?.points.first?.id,
                    durationValues: duration.map { [$0.total.rawValue, $0.reserved.rawValue, String($0.stepCount), $0.perStep.rawValue] } ?? [],
                    weightValues: block.calculator?.weighted?.dimensions.map { $0.weight.rawValue } ?? [])
    }
    public func validate(for block: CGUIBlock) throws {
        guard tableFilter.count <= CGUILimits.cellCharacters,
              (durationValues + weightValues).allSatisfy({ $0.utf8.count <= CGUILimits.cellCharacters }) else { throw CGUIValidationError("localState", "editing_text_too_long") }
        if let table = block.table {
            if let sortColumnID { guard table.columns.contains(where: { $0.id == sortColumnID }) else { throw CGUIValidationError("localState.sortColumnID", "unknown_column") } }
        } else if !tableFilter.isEmpty || sortColumnID != nil { throw CGUIValidationError("localState.table", "presentation_mismatch") }
        if let chart = block.chart {
            guard let selectedSeriesID, let series = chart.series.first(where: { $0.id == selectedSeriesID }),
                  let selectedPointID, series.points.contains(where: { $0.id == selectedPointID }) else { throw CGUIValidationError("localState.selection", "unknown_chart_selection") }
        } else if selectedSeriesID != nil || selectedPointID != nil { throw CGUIValidationError("localState.chart", "presentation_mismatch") }
        guard durationValues.count == (block.calculator?.duration == nil ? 0 : 4),
              weightValues.count == (block.calculator?.weighted?.dimensions.count ?? 0) else { throw CGUIValidationError("localState.inputs", "field_count_mismatch") }
        guard try JSONEncoder().encode(self).count <= CGUILimits.payloadBytes else { throw CGUIValidationError("localState", "editing_payload_too_large") }
    }
}

public struct CGUIStoredLocalState: Codable, Sendable {
    public let schemaVersion: Int
    public let identity: CGUILocalStateIdentity
    /// An independently decoded value keeps malformed/future local state from making the whole Repository unreadable.
    /// The original bytes remain a string until the user explicitly resets this record.
    public let stateJSON: String
    public var state: CGUILocalState? { try? JSONDecoder().decode(CGUILocalState.self, from: Data(stateJSON.utf8)) }
    public init(identity: CGUILocalStateIdentity, state: CGUILocalState, schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; self.identity = identity
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        stateJSON = String(decoding: try! encoder.encode(state), as: UTF8.self)
    }
    public init(identity: CGUILocalStateIdentity, stateJSON: String, schemaVersion: Int = 1) { self.schemaVersion = schemaVersion; self.identity = identity; self.stateJSON = stateJSON }
}
public struct CGUILocalStateHandle: Sendable, Equatable {
    public let id: UUID
    public let identity: CGUILocalStateIdentity
    public let generation: UUID
}
public struct CGUILocalStateSession: Sendable {
    public let handle: CGUILocalStateHandle
    public let initialState: CGUILocalState
    public let restored: Bool
    public let dataChanged: Bool
    /// Corrupt/unsupported bytes are retained. An explicit Reset may replace them; loading alone never does.
    public let readIssue: CGUIValidationError?
}
