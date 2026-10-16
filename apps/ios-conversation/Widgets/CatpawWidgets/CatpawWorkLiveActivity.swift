import ActivityKit
import SwiftUI
import WidgetKit

@main struct CatpawWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CatpawWorkLiveActivity()
        CatpawNextSuggestionWidget()
        CatpawNextMeetingWidget()
        CatpawLockScreenWidget()
    }
}

struct CatpawWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CatpawWorkAttributes.self) { context in
            LockScreenWorkView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(LA.canvas)
                .activitySystemActionForegroundColor(LA.ink)
                .widgetURL(LA.url(context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LAStatusMark(state: context.state, onDark: true)
                        .frame(width: 34, height: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LAStatusText(state: context.state, onDark: true)
                        .font(.caption.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title.isEmpty ? context.attributes.title : context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(context.state.body)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 9) {
                        if context.state.status == .working {
                            LAProgressTrack(pose: context.state.pose, onDark: true)
                        }
                        if context.state.status == .needsUser || context.state.status == .reminder {
                            Link(destination: LA.url(context.attributes)) {
                                Label(LA.s("查看详情", "Open details"), systemImage: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(LA.accent.opacity(0.34), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LAStatusMark(state: context.state, onDark: true)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                LACompactStatus(state: context.state)
            } minimal: {
                LAStatusMark(state: context.state, onDark: true)
                    .frame(width: 18, height: 18)
            }
            .widgetURL(LA.url(context.attributes))
            .keylineTint(LA.accent)
        }
    }
}

enum LA {
    static let canvas = Color(red: 0.984, green: 0.969, blue: 0.941)
    static let ink = Color(red: 0.145, green: 0.125, blue: 0.105)
    static let muted = Color(red: 0.385, green: 0.345, blue: 0.305)
    static let accent = Color(red: 0.867, green: 0.333, blue: 0.118)
    static let attention = Color(red: 0.753, green: 0.459, blue: 0.071)
    static let success = Color(red: 0.176, green: 0.482, blue: 0.318)
    static let failure = Color(red: 0.710, green: 0.216, blue: 0.173)

    static func s(_ zh: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "zh" ? zh : en
    }

    static func url(_ attributes: CatpawWorkAttributes) -> URL {
        URL(string: "catpawm://conversation/" + attributes.conversationID) ?? URL(string: "catpawm://proactive")!
    }

    static func color(_ status: CatpawWorkAttributes.ContentState.Status) -> Color {
        switch status {
        case .needsUser, .reminder: attention
        case .done: success
        case .failed: failure
        case .working: accent
        }
    }

    static func label(_ status: CatpawWorkAttributes.ContentState.Status) -> String {
        switch status {
        case .working: s("进行中", "Working")
        case .needsUser: s("需要决定", "Decision needed")
        case .reminder: s("提醒", "Reminder")
        case .done: s("已完成", "Completed")
        case .failed: s("需要核对", "Review needed")
        }
    }

    static func symbol(_ status: CatpawWorkAttributes.ContentState.Status) -> String {
        switch status {
        case .working: "arrow.triangle.2.circlepath"
        case .needsUser: "hand.raised.fill"
        case .reminder: "bell.fill"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        }
    }
}

struct LAStatusMark: View {
    let state: CatpawWorkAttributes.ContentState
    let onDark: Bool

    var body: some View {
        let color = LA.color(state.status)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(onDark ? 0.28 : 0.12))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(onDark ? 0.62 : 0.28), lineWidth: 1)
            Image(systemName: LA.symbol(state.status))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(onDark ? Color.white : color)
        }
        .accessibilityLabel(LA.label(state.status))
    }
}

struct LAStatusText: View {
    let state: CatpawWorkAttributes.ContentState
    let onDark: Bool

    var body: some View {
        Text(LA.label(state.status))
            .foregroundStyle(onDark ? Color.white.opacity(0.86) : LA.color(state.status))
    }
}

struct LACompactStatus: View {
    let state: CatpawWorkAttributes.ContentState

    var body: some View {
        Image(systemName: LA.symbol(state.status))
            .font(.caption.weight(.bold))
            .foregroundStyle(LA.color(state.status))
            .accessibilityLabel(LA.label(state.status))
    }
}

struct LockScreenWorkView: View {
    let attributes: CatpawWorkAttributes
    let state: CatpawWorkAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LA.color(state.status))
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 11) {
                    LAStatusMark(state: state, onDark: false)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.title.isEmpty ? attributes.title : state.title)
                            .font(.headline)
                            .foregroundStyle(LA.ink)
                            .lineLimit(1)
                        Text(state.body)
                            .font(.subheadline)
                            .foregroundStyle(LA.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    LAStatusText(state: state, onDark: false)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }

                if state.status == .working {
                    LAProgressTrack(pose: state.pose, onDark: false)
                } else if state.status == .needsUser || state.status == .reminder {
                    Link(destination: LA.url(attributes)) {
                        HStack {
                            Text(LA.s("查看详情", "Open details"))
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LA.accent)
                        .frame(minHeight: 38)
                        .padding(.horizontal, 12)
                        .background(LA.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(.leading, 12)
        }
        .padding(16)
    }
}

/// A restrained three-phase indicator for thinking, tool work, and writing. The adjacent status text and
/// accessibility value keep the state understandable without relying on color alone.
struct LAProgressTrack: View {
    let pose: CatpawWorkAttributes.ContentState.Pose
    let onDark: Bool

    private var reached: Int {
        switch pose {
        case .writing: 3
        case .tool: 2
        default: 1
        }
    }

    private var phase: String {
        switch reached {
        case 3: LA.s("整理回答", "Writing response")
        case 2: LA.s("使用工具", "Using tools")
        default: LA.s("分析任务", "Analyzing")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index < reached ? LA.accent : (onDark ? Color.white.opacity(0.18) : LA.ink.opacity(0.10)))
                        .frame(height: 4)
                }
            }
            Text(phase)
                .font(.caption2.weight(.medium))
                .foregroundStyle(onDark ? Color.white.opacity(0.62) : LA.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LA.s("工作进度", "Work progress"))
        .accessibilityValue(phase)
    }
}

#if DEBUG
#Preview("Lock", as: .content, using: CatpawWorkAttributes(taskID: "t1", conversationID: "c1", title: "一页带来源的报告")) {
    CatpawWorkLiveActivity()
} contentStates: {
    CatpawWorkAttributes.ContentState(title: "一页带来源的报告", body: "读取第 2 份资料", kind: "tool", taskID: "t1")
    CatpawWorkAttributes.ContentState(title: "喝水提醒", body: "该起来喝杯水了", kind: "reminder_due", taskID: "t2")
    CatpawWorkAttributes.ContentState(title: "一页带来源的报告", body: "报告已生成", kind: "done", taskID: "t1")
}
#endif
