import ActivityKit
import SwiftUI
import WidgetKit

@main struct CatpawWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CatpawWorkLiveActivity()
        CatpawLeaveLiveActivity()
        CatpawNextSuggestionWidget()
        CatpawNextMeetingWidget()
        CatpawLockScreenWidget()
    }
}

// MARK: - Catpaw work Live Activity — ux-round-1505 glass redesign (方块 SPEC.md, /workspace/codex-review/ux-round-1505/live-activity)

struct CatpawWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CatpawWorkAttributes.self) { context in
            LockScreenWorkView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .modifier(LAGlass())
                .activitySystemActionForegroundColor(LAPalette.adaptiveInk)
                .widgetURL(LA.url(context.attributes))
        } dynamicIsland: { context in
            let p = LAPalette(dark: true), m = LAModel(context.state, attributes: context.attributes, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LAKitten(model: m, palette: p, size: 44, badge: 18).padding(.leading, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.9)
                        Text(m.status).font(.subheadline).foregroundStyle(p.secondary).lineLimit(m.kind == .needsUser ? 2 : 1).contentTransition(.opacity)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LATimer(model: m).font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(.white).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LAFooter(model: m, palette: p, attributes: context.attributes).padding(.leading, 56).padding(.bottom, 6)
                }
            } compactLeading: {
                LAKitten(model: m, palette: p, size: 24, badge: 11).padding(.leading, 6)
            } compactTrailing: {
                LACompactTrailing(model: m, palette: p)
            } minimal: {
                LAKitten(model: m, palette: p, size: 24, badge: 11)
            }
            .widgetURL(LA.url(context.attributes))
            .keylineTint(Color(lahex: 0xE8622A).opacity(0.6))
        }
    }
}

/// iOS 26: system Liquid Glass, no tint. iOS 17–18: translucent tint (white 0.50 light / #161412 0.48 dark); the system blurs behind it.
struct LAGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content } else { content.activityBackgroundTint(LAPalette.glassTint) }
    }
}

extension Color {
    init(lahex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((lahex >> 16) & 0xFF) / 255, green: Double((lahex >> 8) & 0xFF) / 255, blue: Double(lahex & 0xFF) / 255, opacity: alpha)
    }
}
extension UIColor {
    convenience init(lahex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((lahex >> 16) & 0xFF) / 255, green: CGFloat((lahex >> 8) & 0xFF) / 255, blue: CGFloat(lahex & 0xFF) / 255, alpha: alpha)
    }
}

/// SPEC §2 tokens. Text is only ink / secondary — never orange. Color lives in badges and the current-step dot.
struct LAPalette {
    let dark: Bool
    var ink: Color { dark ? Color(lahex: 0xF5F2EE) : Color(lahex: 0x1C1A18) }
    var secondary: Color { dark ? Color(lahex: 0xF5F2EE, alpha: 0.64) : Color(lahex: 0x1C1A18, alpha: 0.62) }
    var tertiary: Color { dark ? Color(lahex: 0xF5F2EE, alpha: 0.30) : Color(lahex: 0x1C1A18, alpha: 0.28) }
    var stepCurrent: Color { dark ? Color(lahex: 0xF07A45) : Color(lahex: 0xE8622A) }
    var amber: Color { dark ? Color(lahex: 0xE9A23B) : Color(lahex: 0xD98A1A) }
    var green: Color { dark ? Color(lahex: 0x3DBA7E) : Color(lahex: 0x2FA36B) }
    var red: Color { dark ? Color(lahex: 0xF0605A) : Color(lahex: 0xE0483E) }
    var badgeNeutral: Color { dark ? Color(lahex: 0x2E2C2A) : Color(lahex: 0xF6F4F1) }
    var badgeStroke: Color { dark ? Color(lahex: 0x161412) : .white }
    var primaryFill: Color { dark ? Color(lahex: 0xF5F2EE) : Color(lahex: 0x1C1A18) }
    var primaryText: Color { dark ? Color(lahex: 0x1C1A18) : .white }
    var secondaryFill: Color { dark ? Color.white.opacity(0.12) : Color(lahex: 0x1C1A18, alpha: 0.08) }
    static let glassTint = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(lahex: 0x161412, alpha: 0.48) : UIColor(white: 1, alpha: 0.50) })
    static let adaptiveInk = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(lahex: 0xF5F2EE) : UIColor(lahex: 0x1C1A18) })
}

/// Presentation model: kind → kitten, badge, spoken status, footer. Pure (no View), so it is unit-testable.
struct LAModel {
    enum Kind: Equatable { case thinking, tool, writing, needsUser, done, failed, reminder, unknown }
    let kind: Kind
    let title: String
    let status: String
    let step: Int
    let startedAt: Date?
    let endedAt: Date?
    let tool: String?
    let stale: Bool

    init(_ s: CatpawWorkAttributes.ContentState, attributes: CatpawWorkAttributes? = nil, stale: Bool = false) {
        typealias K = CatpawWorkAttributes.ContentState.Kind
        switch s.kind {
        case K.thinking: kind = .thinking
        case K.working: kind = (s.tool ?? "").isEmpty ? .thinking : .tool
        case K.tool: kind = .tool
        case K.writing: kind = .writing
        case K.needsUser: kind = .needsUser
        case K.done: kind = .done
        case K.failed: kind = .failed
        case "reminder_due": kind = .reminder
        default: kind = .unknown
        }
        self.stale = stale && kind != .done && kind != .failed
        step = max(0, s.step ?? 0); startedAt = s.startedAt; endedAt = s.endedAt; tool = s.tool
        let generic: Set<String> = ["", "Catpaw 正在工作", "Catpaw is working", "Catpaw 正在处理"]
        if let summary = s.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty { title = summary }
        else if !generic.contains(s.title) { title = s.title }
        else { title = LA.s("Catpaw 正在处理", "Catpaw is on it") }
        let genericBodies: Set<String> = ["", "正在思考…", "已完成", "未完成，需核对", "等你确认", "正在整理回答…"]
        let body = genericBodies.contains(s.body) ? nil : s.body
        if self.stale { status = LA.s("可能已暂停 · 点按查看", "May be paused · Tap to check"); return }
        switch kind {
        case .thinking: status = LA.s("正在理解你的请求", "Working out your request")
        case .tool: status = LA.verb(s.tool)
        case .writing: status = LA.s("正在整理回复", "Writing the reply")
        case .needsUser: status = body ?? LA.s("等你确认", "Waiting for you")
        case .done: status = body ?? LA.s("已完成", "Done")
        case .failed: status = body ?? LA.s("没能完成", "Couldn't finish")
        case .reminder: status = LA.s("提醒：", "Reminder: ") + s.title
        case .unknown: status = s.body
        }
    }
    var kittenName: String {
        switch kind {
        case .thinking: "LAKittenThinking"
        case .tool: "LAKittenTool"
        case .writing: "LAKittenWriting"
        case .needsUser: "LAKittenWaiting"
        case .done: "LAKittenDone"
        case .failed: "LAKittenFailed"
        case .reminder, .unknown: "LALogo"
        }
    }
    /// SF Symbol badge; nil = no badge.
    var badgeSymbol: String? {
        switch kind {
        case .thinking, .unknown: nil
        case .tool: LA.toolGlyph(tool)
        case .writing: "pencil"
        case .needsUser: "questionmark"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .reminder: "bell.fill"
        }
    }
    var running: Bool { [.thinking, .tool, .writing, .unknown].contains(kind) && !stale }
    var elapsed: TimeInterval? { guard let startedAt, let endedAt else { return nil }; return max(0, endedAt.timeIntervalSince(startedAt)) }
    var axKind: String {
        switch kind {
        case .thinking: LA.s("思考中", "Thinking")
        case .tool: LA.s("使用工具", "Using a tool")
        case .writing: LA.s("整理回复", "Writing")
        case .needsUser: LA.s("等你确认", "Waiting for you")
        case .done: LA.s("已完成", "Done")
        case .failed: LA.s("没能完成", "Couldn't finish")
        case .reminder: LA.s("提醒", "Reminder")
        case .unknown: LA.s("进行中", "In progress")
        }
    }
}

enum LA {
    static func s(_ zh: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "zh" ? zh : en
    }
    static func url(_ attributes: CatpawWorkAttributes) -> URL {
        URL(string: "catpawm://conversation/" + attributes.conversationID) ?? URL(string: "catpawm://proactive")!
    }
    /// SPEC §5 tool → spoken verb. Never shows a raw tool id.
    static func verb(_ tool: String?) -> String {
        let t = tool ?? ""
        // status-line v1.0: zh copy comes from the shared ToolStepCopy table.
        if ToolStepCopy.table[t] != nil { return ToolStepCopy.short(t, en: s("zh", "en") == "en") }
        if t.hasPrefix("delegate_") { return s("正在交给助手处理", "Handing off") }
        switch t {
        case "calendar_list": return s("正在查看日历", "Checking your calendar")
        case "calendar_create", "create_calendar_event": return s("正在添加日程", "Adding the event")
        case "places_search": return s("正在搜索附近", "Searching nearby")
        case "reminder_create", "create_reminder", "alarm_set": return s("正在设置提醒", "Setting a reminder")
        case "web_search": return s("正在搜索网页", "Searching the web")
        default: return s("正在处理", "Working on it")
        }
    }
    static func toolGlyph(_ tool: String?) -> String {
        if let t = tool, ToolStepCopy.table[t] != nil { return ToolStepCopy.symbol(t) }
        return switch tool ?? "" {
        case "calendar_list", "calendar_create", "create_calendar_event": "calendar"
        case "places_search", "maps_open": "location.fill"
        case "web_search", "contacts_search": "magnifyingglass"
        case "reminder_create", "create_reminder", "alarm_set": "bell.fill"
        default: "wrench.and.screwdriver.fill"
        }
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded()); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Kitten (widget-catalog image at display size) + SF Symbol status badge at bottom-trailing.
struct LAKitten: View {
    let model: LAModel
    let palette: LAPalette
    let size: CGFloat
    let badge: CGFloat
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let asset = size <= 24 ? model.kittenName + "24" : model.kittenName + "36"
        let name = UIImage(named: asset) != nil ? asset : (size <= 24 ? "LALogo24" : "LALogo36")
        ZStack(alignment: .bottomTrailing) {
            Image(name).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).opacity(luminanceReduced ? 0.7 : 1)
                .id(model.kittenName).transition(.opacity)
            if let symbol = model.badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: badge * 0.56, weight: .bold))
                    .foregroundStyle(badgeGlyph)
                    .frame(width: badge, height: badge)
                    .background(badgeFill, in: Circle())
                    .overlay(Circle().strokeBorder(palette.badgeStroke, lineWidth: 1.5))
                    .offset(x: 3, y: 3)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Catpaw · " + model.axKind)
    }
    private var badgeFill: Color {
        switch model.kind {
        case .needsUser, .reminder: palette.amber
        case .done: palette.green
        case .failed: palette.red
        default: palette.badgeNeutral
        }
    }
    /// status-line visual SPEC §2.2 contrast fix: white on amber is 2.76:1 and white on dark-mode red is 3.2:1, so those use dark glyphs.
    private var badgeGlyph: Color {
        switch model.kind {
        case .needsUser, .reminder: palette.dark ? Color(lahex: 0x161412) : Color(lahex: 0x1C1A18)
        case .failed: palette.dark ? Color(lahex: 0x161412) : .white
        case .done: .white
        default: palette.ink
        }
    }
}

/// Live elapsed time — only when startedAt is known (old payloads: hidden, never faked). Frozen on done/failed.
struct LATimer: View {
    let model: LAModel
    var body: some View {
        if let elapsed = model.elapsed { Text(LA.clock(elapsed)) }
        else if model.running, let start = model.startedAt { Text(timerInterval: start...Date.distantFuture, countsDown: false) }
    }
}

/// Row 2: honest step dots + 第 N 步 / waiting action / done-failed footer.
struct LAFooter: View {
    let model: LAModel
    let palette: LAPalette
    let attributes: CatpawWorkAttributes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        switch model.kind {
        case .needsUser:
            // 「确认添加」 deliberately not on the lock screen (trust & safety: would write to the calendar from a locked
            // device). Only 「打开查看」, which deep-links into the chat where the in-app card confirms.
            Link(destination: LA.url(attributes)) {
                Text(LA.s("打开查看", "Open")).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink)
                    .padding(.horizontal, 16).frame(height: 34).background(palette.secondaryFill, in: Capsule())
            }
        case .done:
            Text(doneLine).font(.caption2.weight(.medium)).foregroundStyle(palette.secondary)
        case .failed:
            Text(LA.s("点按打开 Catpaw 处理", "Tap to open Catpaw")).font(.caption2.weight(.medium)).foregroundStyle(palette.secondary)
        default:
            if model.step > 0 && !model.stale {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(0..<min(model.step, 6), id: \.self) { i in
                            let current = i == min(model.step, 6) - 1
                            Circle().fill(current ? palette.stepCurrent : palette.tertiary).frame(width: 6, height: 6)
                                .overlay(current ? Circle().stroke(palette.stepCurrent.opacity(0.25), lineWidth: 2).padding(-2) : nil)
                        }
                    }
                    Text(LA.s("第 \(model.step) 步", "Step \(model.step)")).font(.caption2.weight(.medium)).foregroundStyle(palette.secondary)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(LA.s("第 \(model.step) 步", "Step \(model.step)"))
            }
        }
    }
    private var doneLine: String {
        var parts: [String] = []
        if model.step > 0 { parts.append(LA.s("共 \(model.step) 步", "\(model.step) steps")) }
        if let e = model.elapsed { parts.append(LA.s("用时 ", "") + LA.clock(e)) }
        return parts.isEmpty ? LA.s("已完成", "Done") : parts.joined(separator: " · ")
    }
}

struct LACompactTrailing: View {
    let model: LAModel
    let palette: LAPalette
    var body: some View {
        switch model.kind {
        case .needsUser:
            Text(LA.s("待确认", "Confirm")).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 22).background(Color.white.opacity(0.18), in: Capsule())
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(palette.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20)).foregroundStyle(palette.red)
        default: LATimer(model: model).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.white).frame(maxWidth: 52)
        }
    }
}

struct LockScreenWorkView: View {
    let attributes: CatpawWorkAttributes
    let state: CatpawWorkAttributes.ContentState
    var stale = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = LAPalette(dark: scheme == .dark), m = LAModel(state, attributes: attributes, stale: stale)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                LAKitten(model: m, palette: p, size: 36, badge: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.9)
                    Text(m.status).font(.footnote).foregroundStyle(p.secondary).lineLimit(m.kind == .needsUser ? 2 : 1).truncationMode(.tail)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                LATimer(model: m).font(.footnote.weight(.medium).monospacedDigit()).foregroundStyle(p.ink)
            }
            ViewThatFits(in: .vertical) {
                LAFooter(model: m, palette: p, attributes: attributes).padding(.leading, 47)
                EmptyView()
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .combine)
    }
}

struct CatpawLeaveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CatpawLeaveAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "tram.fill").foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title).font(.headline)
                    Text(context.state.meetingTitle).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Text("出发 \(context.state.leaveAt, style: .time) · 还剩 ")
                        Text(context.state.leaveAt, style: .timer)
                    }
                    .font(.caption.monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .activityBackgroundTint(Color.black.opacity(0.08))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "tram.fill") }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.meetingTitle).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 0) {
                        Text("出发 \(context.state.leaveAt, style: .time) · 还剩 ")
                        Text(context.state.leaveAt, style: .timer)
                    }.font(.caption.monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: "tram.fill")
            } compactTrailing: {
                Text(context.state.leaveAt, style: .timer).font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "tram.fill")
            }
        }
    }
}

