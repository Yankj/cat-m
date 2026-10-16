import SwiftUI
import WidgetKit

struct CatpawWidgetSuggestion: Hashable, Sendable {
    let id: String
    let title: String
    let why: String
}

struct CatpawWidgetMeeting: Hashable, Sendable {
    let id: String
    let title: String
    let why: String
    let startsAt: Date?
    let place: String?
}

struct CatpawWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let suggestion: CatpawWidgetSuggestion?
    let meeting: CatpawWidgetMeeting?
    let isPlaceholder: Bool

    static func empty(at date: Date) -> Self {
        .init(date: date, suggestion: nil, meeting: nil, isPlaceholder: false)
    }

    static func placeholder(at date: Date) -> Self {
        .init(
            date: date,
            suggestion: .init(
                id: "placeholder-suggestion",
                title: LA.s("会前留出 15 分钟准备", "Leave 15 minutes to prepare"),
                why: LA.s("下一场会议临近，资料还没有整理", "Your next meeting is approaching and the notes are not ready")
            ),
            meeting: .init(
                id: "placeholder-meeting",
                title: LA.s("项目复盘", "Project review"),
                why: LA.s("根据日历，这是接下来最早的会议", "This is the earliest upcoming meeting on your calendar"),
                startsAt: date.addingTimeInterval(45 * 60),
                place: LA.s("线上", "Online")
            ),
            isPlaceholder: true
        )
    }
}

protocol CatpawWidgetDataSource: Sendable {
    func snapshot(now: Date) -> CatpawWidgetEntry
}

/// Reads the minimal, versioned projection written by the app. Missing, corrupt, and older snapshots are
/// intentionally empty: a widget must never turn sample content into an apparent real suggestion.
struct AppGroupCatpawWidgetDataSource: CatpawWidgetDataSource {
    private let group = "group.com.yankj.catpawm"
    private let file = "catpaw.widget.snapshot.v1.json"

    func snapshot(now: Date) -> CatpawWidgetEntry {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 2 else {
            return .empty(at: now)
        }

        return .init(
            date: now,
            suggestion: suggestion(from: object["suggestion"]),
            meeting: meeting(from: object["meeting"]),
            isPlaceholder: false
        )
    }

    private func suggestion(from value: Any?) -> CatpawWidgetSuggestion? {
        guard let value = value as? [String: Any],
              let id = nonempty(value["id"]),
              let title = nonempty(value["title"]),
              let why = nonempty(value["why"]) else { return nil }
        return .init(id: id, title: title, why: why)
    }

    private func meeting(from value: Any?) -> CatpawWidgetMeeting? {
        guard let value = value as? [String: Any],
              let id = nonempty(value["id"]),
              let title = nonempty(value["title"]),
              let why = nonempty(value["why"]) else { return nil }
        let startsAt = (value["starts_at"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        return .init(id: id, title: title, why: why, startsAt: startsAt, place: nonempty(value["place"]))
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CatpawWidgetProvider: TimelineProvider {
    var source: any CatpawWidgetDataSource = AppGroupCatpawWidgetDataSource()

    func placeholder(in context: Context) -> CatpawWidgetEntry {
        .placeholder(at: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CatpawWidgetEntry) -> Void) {
        completion(context.isPreview ? .placeholder(at: .now) : source.snapshot(now: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CatpawWidgetEntry>) -> Void) {
        let now = Date.now
        completion(.init(entries: [source.snapshot(now: now)], policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

enum CatpawWidgetLinks {
    static let proactive = URL(string: "catpawm://proactive")!
    static let new = URL(string: "catpawm://new")!
}

enum CatpawWidgetStyle {
    static let canvas = Color(red: 0.984, green: 0.969, blue: 0.941)
    static let ink = Color(red: 0.145, green: 0.125, blue: 0.105)
    static let secondary = Color(red: 0.385, green: 0.345, blue: 0.305)
    static let accent = Color(red: 0.867, green: 0.333, blue: 0.118)
    static let accentSoft = Color(red: 0.965, green: 0.827, blue: 0.718)
}

private struct WidgetEyebrow: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CatpawWidgetStyle.accent)
                .frame(width: 24, height: 24)
                .background(CatpawWidgetStyle.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .widgetAccentable()
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(CatpawWidgetStyle.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct WidgetWhyLine: View {
    let why: String
    let lines: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(LA.s("原因", "WHY"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(CatpawWidgetStyle.accent)
            Text(why)
                .font(.caption)
                .foregroundStyle(CatpawWidgetStyle.secondary)
                .lineLimit(lines)
        }
    }
}

// MARK: - Next proactive suggestion

struct CatpawNextSuggestionView: View {
    let entry: CatpawWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 9 : 10) {
            WidgetEyebrow(title: LA.s("下一条建议", "Next suggestion"), symbol: "bell.badge.fill")
            if let suggestion = entry.suggestion {
                Text(suggestion.title)
                    .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(CatpawWidgetStyle.ink)
                    .lineLimit(family == .systemSmall ? 3 : 2)
                Spacer(minLength: 0)
                WidgetWhyLine(why: suggestion.why, lines: family == .systemSmall ? 2 : 2)
            } else {
                Text(LA.s("现在没有待处理建议", "No suggestion needs attention"))
                    .font(.headline)
                    .foregroundStyle(CatpawWidgetStyle.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                WidgetWhyLine(
                    why: LA.s("有明确变化或需要你决定时才会出现", "Catpaw surfaces only meaningful changes or decisions"),
                    lines: 2
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(CatpawWidgetLinks.proactive)
        .containerBackground(for: .widget) { CatpawWidgetStyle.canvas }
        .accessibilityElement(children: .combine)
    }
}

struct CatpawNextSuggestionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.next-suggestion", provider: CatpawWidgetProvider()) {
            CatpawNextSuggestionView(entry: $0)
        }
        .configurationDisplayName(LA.s("下一条主动建议", "Next proactive suggestion"))
        .description(LA.s("查看下一条建议和出现原因", "See the next suggestion and why it appeared"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Next meeting

struct CatpawNextMeetingView: View {
    let entry: CatpawWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            WidgetEyebrow(title: LA.s("下一场会议", "Next meeting"), symbol: "calendar")
            if let meeting = entry.meeting {
                if let startsAt = meeting.startsAt {
                    Text(startsAt, style: .time)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(CatpawWidgetStyle.accent)
                }
                Text(meeting.title)
                    .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(CatpawWidgetStyle.ink)
                    .lineLimit(family == .systemSmall ? 2 : 1)
                if let place = meeting.place, family == .systemMedium {
                    Label(place, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(CatpawWidgetStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                WidgetWhyLine(why: meeting.why, lines: family == .systemSmall ? 2 : 1)
            } else {
                Text(LA.s("日历里没有接下来的会议", "No upcoming meeting"))
                    .font(.headline)
                    .foregroundStyle(CatpawWidgetStyle.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                WidgetWhyLine(
                    why: LA.s("打开 Catpaw 可以新建对话并安排下一步", "Open Catpaw to start a conversation and plan what is next"),
                    lines: 2
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(CatpawWidgetLinks.new)
        .containerBackground(for: .widget) { CatpawWidgetStyle.canvas }
        .accessibilityElement(children: .combine)
    }
}

struct CatpawNextMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.next-meeting", provider: CatpawWidgetProvider()) {
            CatpawNextMeetingView(entry: $0)
        }
        .configurationDisplayName(LA.s("下一场会议", "Next meeting"))
        .description(LA.s("查看下一场会议和关注原因", "See the next meeting and why it matters"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Lock Screen

private extension CatpawWidgetEntry {
    var lockTitle: String {
        suggestion?.title ?? meeting?.title ?? LA.s("没有待处理建议", "Nothing needs attention")
    }

    var lockWhy: String {
        suggestion?.why ?? meeting?.why ?? LA.s("有重要变化时会显示在这里", "Important changes will appear here")
    }

    var lockURL: URL {
        suggestion == nil && meeting != nil ? CatpawWidgetLinks.new : CatpawWidgetLinks.proactive
    }

    var lockSymbol: String {
        suggestion != nil ? "bell.badge.fill" : (meeting != nil ? "calendar" : "checkmark")
    }
}

struct CatpawLockScreenView: View {
    let entry: CatpawWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: entry.lockSymbol)
                        .font(.title3.weight(.semibold))
                        .widgetAccentable()
                }
                .accessibilityLabel(entry.lockTitle)
            case .accessoryInline:
                Label(entry.lockTitle, systemImage: entry.lockSymbol)
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.lockTitle, systemImage: entry.lockSymbol)
                        .font(.headline)
                        .lineLimit(1)
                        .widgetAccentable()
                    Text(LA.s("原因：", "Why: ") + entry.lockWhy)
                        .font(.caption)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .widgetURL(entry.lockURL)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct CatpawLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.lock-screen", provider: CatpawWidgetProvider()) {
            CatpawLockScreenView(entry: $0)
        }
        .configurationDisplayName(LA.s("Catpaw 提醒", "Catpaw glance"))
        .description(LA.s("在锁屏查看下一项和原因", "See the next item and why it matters on the Lock Screen"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#if DEBUG
#Preview("Suggestion", as: .systemMedium) { CatpawNextSuggestionWidget() } timeline: {
    CatpawWidgetEntry.placeholder(at: .now)
}
#Preview("Meeting", as: .systemSmall) { CatpawNextMeetingWidget() } timeline: {
    CatpawWidgetEntry.placeholder(at: .now)
}
#Preview("Lock", as: .accessoryRectangular) { CatpawLockScreenWidget() } timeline: {
    CatpawWidgetEntry.placeholder(at: .now)
}
#endif
