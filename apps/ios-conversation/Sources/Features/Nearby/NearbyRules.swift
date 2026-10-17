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
    /// Id of the place card the server emits after a places_search (mirror of grounded-ui.mjs autoPlaceBlock).
    static func placeBlockID(callID: String) -> String {
        let safe = callID.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        return String(("places-" + String(safe)).prefix(64))
    }
    /// Search radii: start at 3 km; widen once when fewer than `minResults` came back.
    static let radii: [Double] = [3000, 8000]
    static func needsWiderSearch(_ count: Int) -> Bool { count < minResults }

    /// Keywords pulled from taste memories: likes boost, dislikes demote (e.g. 「喜欢吃辣，不吃香菜」 → like 辣, dislike 香菜).
    static func tasteKeywords(_ prefs: Preferences) -> (likes: [String], dislikes: [String]) {
        var likes: [String] = [], dislikes: [String] = []
        let stop = CharacterSet(charactersIn: "，,。.、；;！!？? ")
        func grab(_ text: String, after marker: String) -> [String] {
            var out: [String] = []; var rest = Substring(text)
            while let r = rest.range(of: marker) {
                let tail = rest[r.upperBound...]
                let word = String(tail.prefix { ch in !ch.unicodeScalars.contains { stop.contains($0) } }).trimmingCharacters(in: .whitespaces)
                if !word.isEmpty { out.append(String(word.prefix(6))) }
                rest = tail
            }
            return out
        }
        for item in prefs.tastes {
            let t = item.content
            for m in ["不吃", "忌口", "不喝"] { dislikes += grab(t, after: m) }
            var cleaned = t; for m in ["不吃", "忌口", "不喝"] { cleaned = cleaned.replacingOccurrences(of: m, with: "|") }
            for m in ["喜欢吃", "爱吃", "喜欢喝", "爱喝", "只喝", "口味偏"] { likes += grab(cleaned, after: m) }
        }
        likes = likes.flatMap { w in w.hasSuffix("的") ? [String(w.dropLast())] : [w] }.filter { !$0.isEmpty && !$0.contains("|") }
        return (Array(Set(likes)).sorted(), Array(Set(dislikes)).sorted())
    }
    struct Candidate: Equatable, Sendable { var name: String; var category: String; var distance: Double }
    /// Order candidates: taste likes first, dislikes last, then by distance. Without taste memory → pure distance order.
    static func rank(_ cands: [Candidate], prefs: Preferences) -> [Int] {
        let (likes, dislikes) = tasteKeywords(prefs)
        func score(_ c: Candidate) -> Int {
            let text = c.name + " " + c.category
            return likes.filter { text.contains($0) }.count - 2 * dislikes.filter { text.contains($0) }.count
        }
        return cands.indices.sorted { a, b in
            let sa = score(cands[a]), sb = score(cands[b])
            return sa != sb ? sa > sb : cands[a].distance < cands[b].distance
        }
    }

    private static let tasteHints = ["喜欢吃", "爱吃", "口味", "不吃", "忌口", "吃辣", "不辣", "素食", "清淡", "咖啡", "拿铁", "茶"]
    /// Taste + travel-mode memories, honouring 「使用记忆」 per library.
    static func preferences(in snapshots: [MemoryLibrarySnapshot]) -> Preferences {
        var p = Preferences()
        for snap in MemoryRecallGate.effective(snapshots) {   // Codex P0-2: one switch
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
    static func why(prefs: Preferences, mode: Mode, modeFromArg: Bool, originNote: String, radius: Double = radii[0]) -> String {
        var parts: [String] = []
        if radius > radii[0] {
            parts.append("\(Int(radii[0] / 1000)) 公里内不足 \(minResults) 家，已扩到 \(Int(radius / 1000)) 公里")
        }
        let kw = tasteKeywords(prefs)
        if !kw.likes.isEmpty || !kw.dislikes.isEmpty {
            parts.append("按口味记忆「" + prefs.tastes.map(\.content).joined(separator: "」「") + "」调整了排序（" + (kw.likes.isEmpty ? "" : "优先含 " + kw.likes.joined(separator: "/")) + (kw.dislikes.isEmpty ? "" : (kw.likes.isEmpty ? "" : "，") + "靠后含 " + kw.dislikes.joined(separator: "/")) + "）")
        }
        let modeName = ["driving": "开车", "walking": "步行", "transit": "公共交通"][mode.rawValue] ?? "步行"
        if modeFromArg { parts.append("按你指定的\(modeName)估算") }
        else if let item = prefs.modeItem { parts.append("按出行记忆「\(item.content)」用\(modeName)估算") }
        else { parts.append("默认\(modeName)估算") }
        parts.append(originNote)
        return parts.joined(separator: "；")
    }
}
