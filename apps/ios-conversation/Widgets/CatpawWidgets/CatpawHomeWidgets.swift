import SwiftUI
import WidgetKit

// V5 (wave2 plan): Home/Lock Screen widget views. Demo-grade; data comes from `CatpawWidgetDataSource`
// (mock now). Real data needs an App Group snapshot written by the app (M4): today's tasks
// (GET /tasks?due=today from catpaw-proactive) and cat status (latest Live Activity / turn status).

struct CatpawWidgetTask: Identifiable, Hashable, Sendable { let id: String; let title: String; let dueAt: Date?; let done: Bool }
enum CatpawCatMood: String, Sendable { case idle, working, needsUser, done }

struct CatpawWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let tasks: [CatpawWidgetTask]
    let mood: CatpawCatMood
    let statusLine: String
}

protocol CatpawWidgetDataSource: Sendable { func snapshot(now: Date) -> CatpawWidgetEntry }

struct MockCatpawWidgetDataSource: CatpawWidgetDataSource {
    func snapshot(now: Date) -> CatpawWidgetEntry {
        CatpawWidgetEntry(date: now, tasks: [
            .init(id: "t1", title: LA.s("喝水提醒", "Drink water"), dueAt: now.addingTimeInterval(1800), done: false),
            .init(id: "t2", title: LA.s("整理会议纪要", "Tidy meeting notes"), dueAt: now.addingTimeInterval(5400), done: false),
            .init(id: "t3", title: LA.s("提交报销单", "Submit expenses"), dueAt: now.addingTimeInterval(-3600), done: true),
        ], mood: .working, statusLine: LA.s("正在整理会议纪要", "Tidying meeting notes"))
    }
}

/// #48: reads the app's App Group snapshot; falls back to the sample when there is none (no entitlement yet / first run).
struct AppGroupCatpawWidgetDataSource: CatpawWidgetDataSource {
    func snapshot(now: Date) -> CatpawWidgetEntry {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.yankj.catpawm"),
              let data = try? Data(contentsOf: dir.appendingPathComponent("catpaw.widget.snapshot.v1.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return MockCatpawWidgetDataSource().snapshot(now: now) }
        let tasks = (json["tasks"] as? [[String: Any]] ?? []).compactMap { t -> CatpawWidgetTask? in
            guard let id = t["id"] as? String, let title = t["title"] as? String else { return nil }
            return .init(id: id, title: title, dueAt: nil, done: t["done"] as? Bool ?? false)
        }
        return CatpawWidgetEntry(date: now, tasks: tasks, mood: CatpawCatMood(rawValue: json["mood"] as? String ?? "") ?? .idle, statusLine: json["status"] as? String ?? "")
    }
}

struct CatpawWidgetProvider: TimelineProvider {
    var source: any CatpawWidgetDataSource = AppGroupCatpawWidgetDataSource()
    func placeholder(in context: Context) -> CatpawWidgetEntry { source.snapshot(now: .now) }
    func getSnapshot(in context: Context, completion: @escaping (CatpawWidgetEntry) -> Void) { completion(source.snapshot(now: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CatpawWidgetEntry>) -> Void) {
        let now = Date.now
        completion(Timeline(entries: [source.snapshot(now: now)], policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

enum CatpawWidgetLinks {
    // DeepLinkResolver currently only accepts conversation/<uuid>; `catpawm://` opens the app root.
    // Needed routes (M4): catpawm://tasks, catpawm://new?focus=composer.
    static let root = URL(string: "catpawm://")!
    static let tasks = URL(string: "catpawm://tasks")!
    static let new = URL(string: "catpawm://new")!
}

// MARK: - Today's tasks (small / medium)

struct CatpawTodayTasksView: View {
    let entry: CatpawWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let open = entry.tasks.filter { !$0.done }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image("catpaw.paw").resizable().scaledToFit().frame(width: 18, height: 18).widgetAccentable().accessibilityHidden(true)
                Text(LA.s("今日任务", "Today")).font(.headline).foregroundStyle(LA.ink)
                Spacer()
                Text("\(open.count)").font(.headline.monospacedDigit()).foregroundStyle(LA.ink)
            }
            if open.isEmpty {
                Text(LA.s("今天没有待办", "Nothing due today")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(open.prefix(family == .systemSmall ? 2 : 4)) { t in
                HStack(spacing: 6) {
                    Circle().fill(LA.paw).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(t.title).font(.footnote).foregroundStyle(LA.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    if let d = t.dueAt, family != .systemSmall { Text(d, style: .time).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }
        .widgetURL(CatpawWidgetLinks.tasks)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

struct CatpawTodayTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.today-tasks", provider: CatpawWidgetProvider()) { CatpawTodayTasksView(entry: $0) }
            .configurationDisplayName(LA.s("今日任务", "Today's tasks"))
            .description(LA.s("查看今天的提醒和任务", "See today's reminders and tasks"))
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Quick ask (small)

struct CatpawQuickAskView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image("catpaw.paw").resizable().scaledToFit().frame(width: 32, height: 32).widgetAccentable().accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(LA.s("问问小爪", "Ask Catpaw")).font(.headline).foregroundStyle(LA.ink)
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").foregroundStyle(.white).padding(6).background(LA.paw, in: Circle()).accessibilityHidden(true)
                Text(LA.s("说点什么…", "Say something…")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(CatpawWidgetLinks.root)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

struct CatpawQuickAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.quick-ask", provider: CatpawWidgetProvider()) { _ in CatpawQuickAskView() }
            .configurationDisplayName(LA.s("快速提问", "Quick ask"))
            .description(LA.s("一键打开对话", "Jump straight into a conversation"))
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - Cat status (small) + lock screen accessories

enum CatpawMoodUI {
    static func image(_ m: CatpawCatMood) -> String {
        switch m { case .idle: "catpaw.paw"; case .working: "catpaw.paw.thinking"; case .needsUser: "catpaw.paw.badge.hand"; case .done: "catpaw.paw.badge.check" }
    }
    static func label(_ m: CatpawCatMood) -> String {
        switch m { case .idle: LA.s("休息中", "Resting"); case .working: LA.s("干活中", "Working"); case .needsUser: LA.s("需要你", "Needs you"); case .done: LA.s("搞定了", "Done") }
    }
}

struct CatpawCatStatusView: View {
    let entry: CatpawWidgetEntry
    var body: some View {
        VStack(spacing: 6) {
            Image(CatpawMoodUI.image(entry.mood)).resizable().scaledToFit().frame(width: 48, height: 48).widgetAccentable().accessibilityHidden(true)
            Text(CatpawMoodUI.label(entry.mood)).font(.headline).foregroundStyle(LA.ink)
            Text(entry.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
        .widgetURL(CatpawWidgetLinks.root)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

struct CatpawCatStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.cat-status", provider: CatpawWidgetProvider()) { CatpawCatStatusView(entry: $0) }
            .configurationDisplayName(LA.s("小爪状态", "Catpaw status"))
            .description(LA.s("看看小爪在忙什么", "See what Catpaw is doing"))
            .supportedFamilies([.systemSmall])
    }
}

struct CatpawLockScreenView: View {
    let entry: CatpawWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let next = entry.tasks.first { !$0.done }
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(CatpawMoodUI.image(entry.mood)).resizable().scaledToFit().padding(10).widgetAccentable()
                }.accessibilityLabel(CatpawMoodUI.label(entry.mood))
            case .accessoryInline:
                Label(next.map { $0.title } ?? CatpawMoodUI.label(entry.mood), systemImage: "pawprint.fill")
            default: // accessoryRectangular
                VStack(alignment: .leading, spacing: 1) {
                    Label(CatpawMoodUI.label(entry.mood), systemImage: "pawprint.fill").font(.headline).widgetAccentable()
                    if let next {
                        Text(next.title).font(.footnote).lineLimit(1)
                        if let d = next.dueAt { Text(d, style: .time).font(.caption) }
                    } else { Text(LA.s("今天没有待办", "Nothing due today")).font(.footnote) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .widgetURL(CatpawWidgetLinks.root)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct CatpawLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "catpaw.lock-screen", provider: CatpawWidgetProvider()) { CatpawLockScreenView(entry: $0) }
            .configurationDisplayName(LA.s("小爪锁屏", "Catpaw lock screen"))
            .description(LA.s("锁屏上看下一项任务和小爪状态", "Next task and Catpaw status on the Lock Screen"))
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#if DEBUG
#Preview("Today", as: .systemMedium) { CatpawTodayTasksWidget() } timeline: { MockCatpawWidgetDataSource().snapshot(now: .now) }
#Preview("Lock", as: .accessoryRectangular) { CatpawLockScreenWidget() } timeline: { MockCatpawWidgetDataSource().snapshot(now: .now) }
#endif
