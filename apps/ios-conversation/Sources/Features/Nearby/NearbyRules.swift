import Foundation

/// Pure rules for 附近 POI + 路线 (places_search). Unit-tested in Tests/NoBugP0Runner.swift.
enum NearbyRules {
    enum Mode: String, Sendable { case driving, walking, transit }
    struct Preferences: Equatable, Sendable {
        var tastes: [MemoryLibraryItem] = []
        var mode: Mode?
        var modeItem: MemoryLibraryItem?
        var cited: [MemoryLibraryItem] { tastes + (modeItem.map { [$0] } ?? []) }
    }
    static let maxResults = 5, minResults = 3

    private static let tasteHints = ["喜欢吃", "爱吃", "口味", "不吃", "忌口", "吃辣", "不辣", "素食", "清淡", "咖啡", "拿铁", "茶"]
    /// Taste + travel-mode memories, honouring 「使用记忆」 per library.
    static func preferences(in snapshots: [MemoryLibrarySnapshot]) -> Preferences {
        var p = Preferences()
        for snap in snapshots where snap.useMemory {
            for item in snap.items {
                let t = item.content
                if p.tastes.count < 3, tasteHints.contains(where: t.contains) { p.tastes.append(item) }
                if p.mode == nil, let m = mode(in: t) { p.mode = m; p.modeItem = item }
            }
        }
        return p
    }
    static func mode(in text: String) -> Mode? {
        if ["步行", "走路", "walk"].contains(where: text.lowercased().contains) { return .walking }
        if ["地铁", "公交", "公共交通", "transit"].contains(where: text.lowercased().contains) { return .transit }
        if ["开车", "自驾", "打车", "drive"].contains(where: text.lowercased().contains) { return .driving }
        return nil
    }
    /// Explicit tool arg wins over memory; default walking for "附近".
    static func effectiveMode(arg: String, prefs: Preferences) -> Mode { Mode(rawValue: arg) ?? prefs.mode ?? .walking }
    static func mapsURL(lat: Double, lng: Double, name: String, mode: Mode) -> String {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let flag = ["driving": "d", "walking": "w", "transit": "r"][mode.rawValue] ?? "w"
        return "maps://?daddr=\(lat),\(lng)&q=\(q)&dirflg=\(flag)"
    }
    static func telURL(_ phone: String?) -> String? {
        guard let digits = phone?.filter({ $0.isNumber || $0 == "+" }), digits.count >= 3 else { return nil }
        return "tel:\(digits)"
    }
    /// Why line: cites memories (content), the mode source, and the origin honestly.
    static func why(prefs: Preferences, mode: Mode, modeFromArg: Bool, originNote: String) -> String {
        var parts: [String] = []
        if !prefs.tastes.isEmpty { parts.append("按你的口味记忆「" + prefs.tastes.map(\.content).joined(separator: "」「") + "」") }
        let modeName = ["driving": "开车", "walking": "步行", "transit": "公共交通"][mode.rawValue] ?? "步行"
        if modeFromArg { parts.append("按你指定的\(modeName)估算") }
        else if let item = prefs.modeItem { parts.append("按出行记忆「\(item.content)」用\(modeName)估算") }
        else { parts.append("默认\(modeName)估算") }
        parts.append(originNote)
        return parts.joined(separator: "；")
    }
}
