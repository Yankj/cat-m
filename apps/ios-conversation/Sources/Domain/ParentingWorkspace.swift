import Foundation

/// A parent's local ledger. These plans and records do not represent agent tasks or external effects.
public struct ParentingWorkspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var revision: Int
    public var children: [ParentingChild]
    public var goals: [ParentingGoal]
    public var arrangements: [ParentingArrangement]
    public var records: [ParentingRecord]
    public var suggestionsEnabled: Bool

    public static let empty = ParentingWorkspace()
    public init(schemaVersion: Int = 1, revision: Int = 0, children: [ParentingChild] = [], goals: [ParentingGoal] = [], arrangements: [ParentingArrangement] = [], records: [ParentingRecord] = [], suggestionsEnabled: Bool = false) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.children = children; self.goals = goals
        self.arrangements = arrangements; self.records = records; self.suggestionsEnabled = suggestionsEnabled
    }

    public func validate() throws {
        guard schemaVersion == 1, revision >= 0 else { throw catError.corrupt("育儿账本版本不支持，已保留原数据。") }
        let allIDs = children.map(\.id) + goals.map(\.id) + arrangements.map(\.id) + records.map(\.id)
        guard Set(allIDs).count == allIDs.count else { throw catError.corrupt("育儿账本标识重复，已停止写入。") }
        let childIDs = Set(children.map(\.id))
        let goalsByID = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) })
        let arrangementsByID = Dictionary(uniqueKeysWithValues: arrangements.map { ($0.id, $0) })
        for child in children { try Self.text(child.name, limit: 40); try Self.date(child.createdAt) }
        for goal in goals {
            guard childIDs.contains(goal.childID) else { throw catError.corrupt("育儿目标的孩子关联无效。") }
            try Self.text(goal.title, limit: 120); try Self.date(goal.createdAt)
        }
        for arrangement in arrangements {
            try Self.references(childID: arrangement.childID, goalID: arrangement.goalID, children: childIDs, goals: goalsByID)
            try Self.text(arrangement.title, limit: 160); try Self.text(arrangement.sourceText, limit: 8000, allowEmpty: true)
            try Self.date(arrangement.dueAt); try Self.dates(arrangement.createdAt, arrangement.updatedAt)
        }
        var completionArrangementIDs = Set<UUID>()
        for record in records {
            try Self.references(childID: record.childID, goalID: record.goalID, children: childIDs, goals: goalsByID)
            try Self.text(record.text, limit: 8000); try Self.text(record.sourceText, limit: 8000, allowEmpty: true)
            try Self.dates(record.createdAt, record.updatedAt)
            if let id = record.arrangementID {
                guard record.kind == .completion, let arrangement = arrangementsByID[id], arrangement.childID == record.childID,
                      arrangement.state == .completed, completionArrangementIDs.insert(id).inserted else {
                    throw catError.corrupt("育儿记录的安排关联无效。")
                }
            }
        }
    }

    /// Pure transition: callers persist the resulting value atomically before presenting it.
    public func applying(_ command: ParentingCommand, now: Date = Date()) throws -> ParentingWorkspace {
        try validate(); try Self.date(now)
        guard revision < Int.max else { throw catError.invalid("育儿账本版本已达上限。") }
        var next = self
        switch command {
        case .addChild(let id, let name):
            try next.unused(id); try Self.text(name, limit: 40)
            next.children.append(.init(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now))
        case .renameChild(let id, let name):
            let i = try next.childIndex(id); try Self.text(name, limit: 40)
            next.children[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .deleteChild(let id):
            _ = try next.childIndex(id)
            next.children.removeAll { $0.id == id }; next.goals.removeAll { $0.childID == id }
            next.arrangements.removeAll { $0.childID == id }; next.records.removeAll { $0.childID == id }
        case .addGoal(let id, let childID, let title):
            try next.unused(id); _ = try next.childIndex(childID); try Self.text(title, limit: 120)
            next.goals.append(.init(id: id, childID: childID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now))
        case .deleteGoal(let id):
            guard next.goals.contains(where: { $0.id == id }) else { throw catError.missing }
            next.goals.removeAll { $0.id == id }
            for i in next.arrangements.indices where next.arrangements[i].goalID == id { next.arrangements[i].goalID = nil }
            for i in next.records.indices where next.records[i].goalID == id { next.records[i].goalID = nil }
        case .createDraft(let id, let childID, let title, let dueAt, let goalID, let sourceText):
            try next.unused(id); try next.checkReferences(childID: childID, goalID: goalID)
            try Self.text(title, limit: 160); try Self.text(sourceText, limit: 8000, allowEmpty: true); try Self.date(dueAt)
            next.arrangements.append(.init(id: id, childID: childID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), dueAt: dueAt, goalID: goalID, state: .draft, sourceText: sourceText, createdAt: now, updatedAt: now))
        case .editArrangement(let id, let title, let dueAt, let goalID):
            let i = try next.arrangementIndex(id)
            guard [.draft, .planned].contains(next.arrangements[i].state) else { throw catError.invalid("仅待确认或已安排的内容可以修改。") }
            try next.checkReferences(childID: next.arrangements[i].childID, goalID: goalID)
            try Self.text(title, limit: 160); try Self.date(dueAt)
            next.arrangements[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            next.arrangements[i].dueAt = dueAt; next.arrangements[i].goalID = goalID; next.arrangements[i].updatedAt = now
        case .confirmArrangement(let id):
            let i = try next.arrangementIndex(id)
            guard [.draft, .planned].contains(next.arrangements[i].state) else { throw catError.invalid("已取消或已完成的安排不能确认。") }
            if next.arrangements[i].state == .draft { next.arrangements[i].state = .planned; next.arrangements[i].updatedAt = now }
        case .cancelArrangement(let id):
            let i = try next.arrangementIndex(id)
            guard next.arrangements[i].state != .completed else { throw catError.invalid("已完成的安排不能取消。") }
            if next.arrangements[i].state != .cancelled { next.arrangements[i].state = .cancelled; next.arrangements[i].updatedAt = now }
        case .completeArrangement(let id, let recordID, let note):
            let i = try next.arrangementIndex(id)
            try Self.text(note, limit: 8000, allowEmpty: true)
            guard next.arrangements[i].state != .cancelled else { throw catError.invalid("已取消的安排不能完成。") }
            if next.arrangements[i].state == .completed { break }
            guard next.arrangements[i].state == .planned else { throw catError.invalid("请先确认安排，再记录完成。") }
            try next.unused(recordID)
            let arrangement = next.arrangements[i]
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            next.records.append(.init(id: recordID, childID: arrangement.childID, goalID: arrangement.goalID, arrangementID: id, kind: .completion, text: trimmed.isEmpty ? arrangement.title : trimmed, sourceText: note, createdAt: now, updatedAt: now))
            next.arrangements[i].state = .completed; next.arrangements[i].updatedAt = now
        case .deleteArrangement(let id):
            _ = try next.arrangementIndex(id)
            next.arrangements.removeAll { $0.id == id }
            for i in next.records.indices where next.records[i].arrangementID == id { next.records[i].arrangementID = nil }
        case .addObservation(let id, let childID, let goalID, let text):
            try next.unused(id); try next.checkReferences(childID: childID, goalID: goalID); try Self.text(text, limit: 8000)
            next.records.append(.init(id: id, childID: childID, goalID: goalID, arrangementID: nil, kind: .observation, text: text.trimmingCharacters(in: .whitespacesAndNewlines), sourceText: text, createdAt: now, updatedAt: now))
        case .editRecord(let id, let text):
            guard let i = next.records.firstIndex(where: { $0.id == id }) else { throw catError.missing }
            try Self.text(text, limit: 8000)
            next.records[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines); next.records[i].updatedAt = now
        case .deleteRecord(let id):
            guard next.records.contains(where: { $0.id == id }) else { throw catError.missing }
            next.records.removeAll { $0.id == id }
        case .setSuggestionsEnabled(let enabled): next.suggestionsEnabled = enabled
        }
        next.revision += 1
        try next.validate()
        return next
    }

    private func unused(_ id: UUID) throws {
        guard !children.contains(where: { $0.id == id }), !goals.contains(where: { $0.id == id }),
              !arrangements.contains(where: { $0.id == id }), !records.contains(where: { $0.id == id }) else { throw catError.conflict }
    }
    private func childIndex(_ id: UUID) throws -> Int {
        guard let i = children.firstIndex(where: { $0.id == id }) else { throw catError.missing }; return i
    }
    private func arrangementIndex(_ id: UUID) throws -> Int {
        guard let i = arrangements.firstIndex(where: { $0.id == id }) else { throw catError.missing }; return i
    }
    private func checkReferences(childID: UUID, goalID: UUID?) throws {
        try Self.references(childID: childID, goalID: goalID, children: Set(children.map(\.id)), goals: Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) }))
    }
    private static func references(childID: UUID, goalID: UUID?, children: Set<UUID>, goals: [UUID: ParentingGoal]) throws {
        guard children.contains(childID) else { throw catError.invalid("请先选择当前账本中的孩子。") }
        if let goalID { guard goals[goalID]?.childID == childID else { throw catError.invalid("目标必须属于当前孩子。") } }
    }
    private static func text(_ value: String, limit: Int, allowEmpty: Bool = false) throws {
        guard value.count <= limit, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw catError.invalid("内容不能为空，且不能超过\(limit)字。") }
    }
    private static func date(_ value: Date) throws {
        guard value.timeIntervalSince1970.isFinite else { throw catError.invalid("时间无效。") }
    }
    private static func dates(_ created: Date, _ updated: Date) throws {
        try date(created); try date(updated)
        guard updated >= created else { throw catError.corrupt("育儿账本时间无效，已保留原数据。") }
    }
}

public struct ParentingChild: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID; public var name: String; public var createdAt: Date
    public init(id: UUID, name: String, createdAt: Date) { self.id = id; self.name = name; self.createdAt = createdAt }
}
public struct ParentingGoal: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID; public var childID: UUID; public var title: String; public var createdAt: Date
    public init(id: UUID, childID: UUID, title: String, createdAt: Date) { self.id = id; self.childID = childID; self.title = title; self.createdAt = createdAt }
}
public enum ParentingArrangementState: String, Codable, Sendable, CaseIterable { case draft, planned, cancelled, completed }
public struct ParentingArrangement: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID; public var childID: UUID; public var title: String; public var dueAt: Date; public var goalID: UUID?
    public var state: ParentingArrangementState; public var sourceText: String; public var createdAt: Date; public var updatedAt: Date
    public init(id: UUID, childID: UUID, title: String, dueAt: Date, goalID: UUID?, state: ParentingArrangementState, sourceText: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.childID = childID; self.title = title; self.dueAt = dueAt; self.goalID = goalID; self.state = state
        self.sourceText = sourceText; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
public enum ParentingRecordKind: String, Codable, Sendable, CaseIterable { case observation, completion }
public struct ParentingRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID; public var childID: UUID; public var goalID: UUID?; public var arrangementID: UUID?
    public var kind: ParentingRecordKind; public var text: String; public var sourceText: String; public var createdAt: Date; public var updatedAt: Date
    public init(id: UUID, childID: UUID, goalID: UUID?, arrangementID: UUID?, kind: ParentingRecordKind, text: String, sourceText: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.childID = childID; self.goalID = goalID; self.arrangementID = arrangementID; self.kind = kind
        self.text = text; self.sourceText = sourceText; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum ParentingCommand: Codable, Sendable, Equatable {
    case addChild(id: UUID, name: String)
    case renameChild(id: UUID, name: String)
    case deleteChild(id: UUID)
    case addGoal(id: UUID, childID: UUID, title: String)
    case deleteGoal(id: UUID)
    case createDraft(id: UUID, childID: UUID, title: String, dueAt: Date, goalID: UUID?, sourceText: String)
    case editArrangement(id: UUID, title: String, dueAt: Date, goalID: UUID?)
    case confirmArrangement(id: UUID)
    case cancelArrangement(id: UUID)
    case completeArrangement(id: UUID, recordID: UUID, note: String)
    case deleteArrangement(id: UUID)
    case addObservation(id: UUID, childID: UUID, goalID: UUID?, text: String)
    case editRecord(id: UUID, text: String)
    case deleteRecord(id: UUID)
    case setSuggestionsEnabled(Bool)
}
