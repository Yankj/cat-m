import Foundation

/// A deliberately bounded verifier for an edit suggestion, not a natural-language scheduling engine.
/// The selected arrangement is never an input: old dates and clocks cannot supply missing evidence.
enum ParentingRescheduleTime {
    struct Verification {
        let dueAt: Date?
        let clarification: String?
    }
    private static let clarification = "请补充一个明确日期和钟点，例如“明天下午五点”或“2027-02-18 17:00”。有歧义或夏令时变化的时间请手动选择后核对。"
    private static let datePattern = #"(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])|今天|明天|后天"#
    private static let clockPattern = #"(?<![0-9零〇一二两三四五六七八九十:：])(?:(凌晨|早上|上午|中午|下午|傍晚|晚上)\s*)?([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})(?:[:：]([0-9]{2})(?:[:：]([0-9]{2}))?|[点时](?:([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})分?|(半))?)(?![0-9零〇一二两三四五六七八九十半刻分:：]|\.[0-9])"#
    private static let absolutePattern = #"(?<![0-9])([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{2}:[0-9]{2})(?![0-9:+-]|\.[0-9])"#
    // Unsupported time operations or additional date/zone clues stay editable instead of being guessed.
    private static let unsupportedPattern = #"大后天|昨天|前天|周[一二三四五六日天1-7]|星期|[上下本这]周|[0-9一二两三四五六七八九十]+月[0-9一二两三四五六七八九十]+|取消|每[天周月]|每天|每星期|推迟|延后|提前|小时后|分钟后|一刻|三刻|左右|大约|大概|之前|之后|以前|以后|[点时分]多|不是|不要|不改|不用|或者|或是|也许|UTC|GMT|北京时间|当地时间|纽约时间|时区|[A-Za-z_]+/[A-Za-z_]+"#

    static func verify(proposed: Date, sourceText: String, evidence: String, now: Date, timeZone: TimeZone) -> Verification {
        guard proposed.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              matches(unsupportedPattern, in: sourceText).isEmpty,
              sourceText.range(of: evidence) != nil else { return unresolved() }
        let absolute = matches(absolutePattern, in: sourceText)
        if !absolute.isEmpty {
            guard absolute.count == 1, let match = absolute.first,
                  let expression = capture(0, match, sourceText), evidence.contains(expression),
                  let year = number(1, match, sourceText), let month = number(2, match, sourceText),
                  let day = number(3, match, sourceText), let hour = number(4, match, sourceText),
                  let minute = number(5, match, sourceText), let second = number(6, match, sourceText),
                  let offset = capture(7, match, sourceText), let zone = fixedZone(offset),
                  noOtherTime(in: removing([match.range], from: sourceText)),
                  let expected = strictDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second, zone: zone),
                  expected == proposed else { return unresolved() }
            return .init(dueAt: expected, clarification: nil)
        }

        let dates = matches(datePattern, in: sourceText), clocks = matches(clockPattern, in: sourceText)
        guard dates.count == 1, clocks.count == 1, let date = dates.first, let clock = clocks.first,
              let dateText = capture(0, date, sourceText), let clockText = capture(0, clock, sourceText),
              evidence.contains(dateText), evidence.contains(clockText),
              noOtherTime(in: removing([date.range, clock.range], from: sourceText)),
              let ymd = dateFields(dateText, now: now, zone: timeZone),
              let hms = clockFields(clock, in: sourceText, relative: !dateText.contains("-")),
              let expected = strictDate(year: ymd.year, month: ymd.month, day: ymd.day,
                                        hour: hms.hour, minute: hms.minute, second: hms.second, zone: timeZone),
              expected == proposed else { return unresolved() }
        return .init(dueAt: expected, clarification: nil)
    }

    private static func unresolved() -> Verification { .init(dueAt: nil, clarification: clarification) }
    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
    private static func capture(_ i: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        guard i < match.numberOfRanges, let range = Range(match.range(at: i), in: text) else { return nil }
        return String(text[range])
    }
    private static func number(_ i: Int, _ match: NSTextCheckingResult, _ text: String) -> Int? {
        capture(i, match, text).flatMap(Int.init)
    }
    private static func removing(_ ranges: [NSRange], from text: String) -> String {
        var value = text
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            if let swiftRange = Range(range, in: value) { value.replaceSubrange(swiftRange, with: " ") }
        }
        return value
    }
    private static func noOtherTime(in text: String) -> Bool {
        matches(datePattern, in: text).isEmpty && matches(clockPattern, in: text).isEmpty &&
            matches(unsupportedPattern, in: text).isEmpty && matches(#"[+-][0-9]{2}:?[0-9]{2}|[上下]午|凌晨|早上|中午|傍晚|晚上"#, in: text).isEmpty &&
            matches(#"[0-9]+\s*[:：]|[:：]\s*[0-9]+"#, in: text).isEmpty &&
            matches(#"(?i)(?<![A-Za-z])(?:Z|AM|PM)(?![A-Za-z])"#, in: text).isEmpty
    }
    private static func fixedZone(_ text: String) -> TimeZone? {
        if text == "Z" { return TimeZone(secondsFromGMT: 0) }
        let pieces = text.dropFirst().split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]), hour <= 23, minute <= 59 else { return nil }
        return TimeZone(secondsFromGMT: (text.first == "-" ? -1 : 1) * (hour * 3600 + minute * 60))
    }

    private struct Day { let year: Int; let month: Int; let day: Int }
    private struct Clock { let hour: Int; let minute: Int; let second: Int }
    private static func dateFields(_ text: String, now: Date, zone: TimeZone) -> Day? {
        if text.contains("-") {
            let fields = text.split(separator: "-").compactMap { Int($0) }
            guard fields.count == 3 else { return nil }
            return .init(year: fields[0], month: fields[1], day: fields[2])
        }
        let days: Int
        switch text { case "今天": days = 0; case "明天": days = 1; case "后天": days = 2; default: return nil }
        var calendar = gregorian(zone)
        let local = calendar.dateComponents([.year, .month, .day], from: now)
        // Add civil days in UTC, then validate in the requested zone. A skipped local day must not become the day after it.
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let civil = calendar.date(from: local), let shifted = calendar.date(byAdding: .day, value: days, to: civil) else { return nil }
        let fields = calendar.dateComponents([.year, .month, .day], from: shifted)
        guard let year = fields.year, let month = fields.month, let day = fields.day else { return nil }
        return .init(year: year, month: month, day: day)
    }
    private static func clockFields(_ match: NSTextCheckingResult, in text: String, relative: Bool) -> Clock? {
        let period = capture(1, match, text), hourText = capture(2, match, text)
        guard let hourText, let inputHour = chineseOrASCII(hourText) else { return nil }
        let colonMinute = number(3, match, text), colonSecond = number(4, match, text)
        let minuteText = capture(5, match, text), half = capture(6, match, text) != nil
        if period == nil {
            // A bare “五点” or “5点” leaves the day period unknown; colon notation is explicitly 24-hour.
            guard let minute = colonMinute, Int(hourText) != nil else { return nil }
            return .init(hour: inputHour, minute: minute, second: colonSecond ?? 0)
        }
        guard relative, let period else { return nil }
        let hour: Int
        switch period {
        case "凌晨": guard (0...5).contains(inputHour) else { return nil }; hour = inputHour
        case "早上", "上午": guard (1...11).contains(inputHour) else { return nil }; hour = inputHour
        case "中午": guard inputHour == 12 else { return nil }; hour = 12
        case "下午": guard (1...11).contains(inputHour) else { return nil }; hour = inputHour + 12
        case "傍晚": guard (5...7).contains(inputHour) else { return nil }; hour = inputHour + 12
        case "晚上": guard (6...11).contains(inputHour) else { return nil }; hour = inputHour + 12
        default: return nil
        }
        let minute: Int
        if let colonMinute { minute = colonMinute }
        else if half { minute = 30 }
        else if let minuteText { guard let value = chineseOrASCII(minuteText) else { return nil }; minute = value }
        else { minute = 0 }
        return .init(hour: hour, minute: minute, second: colonSecond ?? 0)
    }
    private static func chineseOrASCII(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text.count == 1, let character = text.first { return character == "十" ? 10 : digits[character] }
        let pieces = text.split(separator: "十", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count <= 1, pieces[1].count <= 1 else { return nil }
        let tens = pieces[0].first.flatMap { digits[$0] } ?? (pieces[0].isEmpty ? 1 : -1)
        let units = pieces[1].first.flatMap { digits[$0] } ?? (pieces[1].isEmpty ? 0 : -1)
        guard (1...9).contains(tens), (0...9).contains(units) else { return nil }
        return tens * 10 + units
    }
    private static func gregorian(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "en_US_POSIX"); calendar.timeZone = zone
        return calendar
    }
    private static func strictDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zone: TimeZone) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let calendar = gregorian(zone)
        let fields = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        func exact(_ date: Date, in calendar: Calendar) -> Bool {
            let actual = calendar.dateComponents(units, from: date)
            return actual.year == year && actual.month == month && actual.day == day && actual.hour == hour && actual.minute == minute && actual.second == second
        }
        let utc = gregorian(TimeZone(secondsFromGMT: 0)!)
        guard let wall = utc.date(from: fields), exact(wall, in: utc) else { return nil }
        // Calendar's first/last matching policies can both select the first instant of a half-hour fold.
        // Enumerate actual GMT offsets instead: instant = civil fields interpreted as UTC - offset.
        // This window covers system IANA/fixed offsets; it is not an assumed DST step.
        let radius: TimeInterval = 48 * 60 * 60
        let start = wall.addingTimeInterval(-radius), end = wall.addingTimeInterval(radius)
        var offsets: Set<Int> = [zone.secondsFromGMT(for: start), zone.secondsFromGMT(for: end)]
        var cursor = start
        var transitionCount = 0
        while let transition = zone.nextDaylightSavingTimeTransition(after: cursor), transition <= end {
            // Fail closed if the system cannot enumerate a bounded, strictly advancing transition list.
            guard transition > cursor, transitionCount < 16 else { return nil }
            offsets.insert(zone.secondsFromGMT(for: transition.addingTimeInterval(-1)))
            offsets.insert(zone.secondsFromGMT(for: transition))
            offsets.insert(zone.secondsFromGMT(for: transition.addingTimeInterval(1)))
            cursor = transition
            transitionCount += 1
        }
        var candidates = Set<Date>()
        for offset in offsets {
            guard abs(TimeInterval(offset)) < radius else { return nil }
            let candidate = wall.addingTimeInterval(-TimeInterval(offset))
            if zone.secondsFromGMT(for: candidate) == offset, exact(candidate, in: calendar) { candidates.insert(candidate) }
        }
        guard candidates.count == 1 else { return nil } // No instant is a gap; multiple instants are a fold.
        return candidates.first
    }
}
