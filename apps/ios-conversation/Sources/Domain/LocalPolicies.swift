import Foundation

public enum ProfilePreferences {
    public static let keys: Set<String> = ["theme", "language", "subagents", "model", "safety", "delete_confirmation", "result_notifications", "voice_locale", "readout_locale", "readout_rate"]
    public static func scope(_ profileID: UUID) -> DataScope { DataScope(profileID: profileID, workspaceID: stableID("profile-settings-\(profileID)")) }
    public static func destination(_ workspace: DataScope, key: String) -> DataScope { keys.contains(key) ? scope(workspace.profileID) : workspace }
}
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case chinese = "zh-Hans", english = "en"
    public func text(_ chinese: String, _ english: String) -> String { self == .english ? english : chinese }
    public init(locale: Locale) { self = locale.identifier.hasPrefix("en") ? .english : .chinese }
    public func ui(_ key: String, arguments: [String] = []) -> String { UIStrings.catalog.text(key, language: self, arguments: arguments) }
}

public struct UICatalog: Sendable {
    public let entries: [String: [String: String]]
    public init(data: Data) throws { entries = try JSONDecoder().decode([String: [String: String]].self, from: data) }
    public init(entries: [String: [String: String]]) { self.entries = entries }
    public func text(_ key: String, language: AppLanguage, arguments: [String] = []) -> String {
        let template = entries[key]?[language.rawValue] ?? key
        let pattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let source = template as NSString
        var result = "", cursor = 0
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}
public enum UIStrings {
    public static let catalog: UICatalog = {
        guard let url = Bundle.main.url(forResource: "UIStrings", withExtension: "json"), let data = try? Data(contentsOf: url), let catalog = try? UICatalog(data: data) else { return UICatalog(entries: [:]) }
        return catalog
    }()
}
public struct ViewReceipt: Codable, Sendable {
    public let userID: UUID
    public let document: DocumentReference
    public let openedAt: Date
    public static func id(scope: DataScope, reference: DocumentReference) -> UUID { stableID("view-\(scope.profileID)-\(scope.workspaceID)-\(reference.documentID)-v\(reference.version)") }
}
public struct DelegationRequirements: Codable, Sendable {
    public var delivery = "in_app"
    public var cross_task_memory = false
    public var requirements = ""
    public init(requirements: String = "") { self.requirements = requirements }
    public static func decode(_ data: Data) -> Self {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Self() }
        var result = Self(requirements: value["requirements"] as? String ?? "")
        result.delivery = value["delivery"] as? String ?? "in_app"
        result.cross_task_memory = value["cross_task_memory"] as? Bool ?? false
        return result
    }
    public static func replacing(_ data: Data, requirements: String) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CatpawError.corrupt("委托范围数据不可解析，保留原内容。") }
        value["requirements"] = requirements
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
public enum CatalogCategory: String, CaseIterable, Codable, Sendable {
    case office, data, design
    public func title(_ language: AppLanguage) -> String {
        switch self { case .office: return language.ui("日常办公"); case .data: return language.ui("数据分析"); case .design: return language.ui("设计创作") }
    }
}
public enum CatalogFilter {
    public static func category(_ record: StoredRecord) -> CatalogCategory? {
        let data: Data
        switch record.payload { case .core(.expert(let item)): data = item.configurationJSON; case .core(.skill(let item)): data = item.definitionJSON; default: return nil }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let id = value?["categoryID"] as? String, let category = CatalogCategory(rawValue: id) { return category }
        switch value?["category"] as? String { case "文档", "办公", "日常办公": return .office; case "数据分析", "数据": return .data; case "设计创作", "设计": return .design; default: return nil }
    }
    public static func matches(_ record: StoredRecord, category: CatalogCategory?, query: String) -> Bool {
        if let category, self.category(record) != category { return false }
        let summary: String
        switch record.payload { case .core(.expert(let item)): summary = item.summary; case .core(.skill(let item)): summary = item.summary; default: return false }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty || record.title.localizedCaseInsensitiveContains(search) || summary.localizedCaseInsensitiveContains(search)
    }
}
public enum ScheduleInput {
    public static func intervalCadence(_ input: String) throws -> String {
        guard let hours = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)), hours > 0, hours <= Int.max / 3600 else { throw CatpawError.invalid("间隔需为可表示的正整数小时。") }
        return "interval_\(hours)h"
    }
    public static func isoWeekdays(_ spec: ScheduleSpec) -> [Int] {
        spec.weekdayConvention == nil ? spec.weekdays.map { (1...7).contains($0) ? (($0 + 5) % 7) + 1 : $0 } : spec.weekdays
    }
    public static func calendarWeekday(_ iso: Int) -> Int { (iso % 7) + 1 }
}
