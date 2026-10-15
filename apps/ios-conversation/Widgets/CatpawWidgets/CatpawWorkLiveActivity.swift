import ActivityKit
import SwiftUI
import WidgetKit

/// UI only. Lock screen + Dynamic Island for `CatpawWorkAttributes`. Requires a new Widget Extension target
/// `CatpawWidgets` (iOS 17+, NSSupportsLiveActivities = YES in the app Info.plist). Strings are literal Chinese/English via
/// String(localized:) because the widget can't read the app's UIStrings.json without sharing the bundle.
@main struct CatpawWidgetsBundle: WidgetBundle {
    var body: some Widget { CatpawWorkLiveActivity() }
}

struct CatpawWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CatpawWorkAttributes.self) { ctx in
            LockScreenWorkView(attributes: ctx.attributes, state: ctx.state)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(LA.ink)
                .widgetURL(LA.url(ctx.attributes, ctx.state))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LAPaw(status: ctx.state.status).frame(width: 28, height: 28).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LAStatusText(state: ctx.state).font(.caption.weight(.semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ctx.state.stepTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        LAStepDots(state: ctx.state)
                        if ctx.state.needsUser {
                            Link(destination: LA.url(ctx.attributes, ctx.state)) {
                                Text(LA.s("查看并确认", "Review & confirm")).font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 34).background(LA.attention.opacity(0.22), in: Capsule())
                            }
                        }
                    }.padding(.horizontal, 4)
                }
            } compactLeading: {
                LAPaw(status: ctx.state.status).frame(width: 18, height: 18)
            } compactTrailing: {
                LACompactTrailing(state: ctx.state)
            } minimal: {
                LAPaw(status: ctx.state.status).frame(width: 16, height: 16)
            }
            .widgetURL(LA.url(ctx.attributes, ctx.state))
            .keylineTint(LA.paw)
        }
    }
}

enum LA {
    static let paw = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x85 / 255)     // brandPaw dark (DI is always dark)
    static let attention = Color(red: 0xE9 / 255, green: 0xBC / 255, blue: 0x69 / 255)
    static let success = Color(red: 0x9B / 255, green: 0xD4 / 255, blue: 0xAF / 255)
    static let failure = Color(red: 0xFF / 255, green: 0xB4 / 255, blue: 0xAB / 255)
    static let ink = Color.primary
    static func s(_ zh: String, _ en: String) -> String { Locale.current.language.languageCode?.identifier == "zh" ? zh : en }
    /// Matches DeepLinkResolver today: `catpawm://conversation/<uuid>`, no query items (the resolver rejects any
    /// query other than `version`). Focusing `needsUserCardID` needs a resolver change — see README.
    static func url(_ a: CatpawWorkAttributes, _ st: CatpawWorkAttributes.ContentState) -> URL {
        URL(string: "catpawm://conversation/" + a.conversationID) ?? URL(string: "catpawm://")!
    }
    static func color(_ s: CatpawWorkAttributes.ContentState.Status) -> Color {
        switch s {
        case .needsUser, .reconnecting: attention
        case .done: success
        case .failed: failure
        default: paw
        }
    }
    static func label(_ s: CatpawWorkAttributes.ContentState.Status) -> String {
        switch s {
        case .queued: s_("排队中", "Queued")
        case .running: s_("进行中", "Working")
        case .needsUser: s_("需要你", "Needs you")
        case .waiting: s_("等待中", "Waiting")
        case .reconnecting: s_("重连中", "Reconnecting")
        case .done: s_("已完成", "Done")
        case .failed: s_("需核对", "Check result")
        }
    }
    private static func s_(_ zh: String, _ en: String) -> String { s(zh, en) }
    static func badge(_ s: CatpawWorkAttributes.ContentState.Status) -> String? {
        switch s {
        case .needsUser: "hand.raised.fill"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .waiting, .queued: "clock"
        case .running: nil
        }
    }
}

/// Paw glyph (asset `catpaw.paw` symbol in the widget's catalog) + status badge.
struct LAPaw: View {
    let status: CatpawWorkAttributes.ContentState.Status
    var body: some View {
        Image("catpaw.paw").resizable().scaledToFit().foregroundStyle(LA.paw)
            .overlay(alignment: .bottomTrailing) {
                if let b = LA.badge(status) {
                    Image(systemName: b).font(.system(size: 7, weight: .black)).foregroundStyle(.black)
                        .frame(width: 11, height: 11).background(LA.color(status), in: Circle()).offset(x: 3, y: 3)
                }
            }
            .accessibilityLabel(LA.label(status))
    }
}

struct LAStatusText: View {
    let state: CatpawWorkAttributes.ContentState
    var body: some View {
        if state.status == .running, state.stepCount > 0 {
            Text("\(state.stepIndex)/\(state.stepCount)").monospacedDigit().foregroundStyle(LA.paw)
        } else {
            Text(LA.label(state.status)).foregroundStyle(LA.color(state.status))
        }
    }
}

struct LACompactTrailing: View {
    let state: CatpawWorkAttributes.ContentState
    var body: some View {
        switch state.status {
        case .running where state.stepCount > 0:
            ProgressView(value: Double(state.stepIndex), total: Double(state.stepCount))
                .progressViewStyle(.circular).tint(LA.paw).frame(width: 18, height: 18)
        case .needsUser: Image(systemName: "hand.raised.fill").foregroundStyle(LA.attention)
        case .done: Image(systemName: "checkmark").foregroundStyle(LA.success)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(LA.failure)
        case .reconnecting: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(LA.attention)
        default: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}

struct LAStepDots: View {
    let state: CatpawWorkAttributes.ContentState
    var body: some View {
        let n = max(1, min(state.stepCount, 8))
        HStack(spacing: 4) {
            ForEach(0..<n, id: \.self) { i in
                Capsule().fill(i < state.stepIndex ? LA.color(state.status) : Color.secondary.opacity(0.3)).frame(height: 4)
            }
        }
        .accessibilityLabel("\(state.stepIndex)/\(state.stepCount)")
    }
}

struct LockScreenWorkView: View {
    let attributes: CatpawWorkAttributes
    let state: CatpawWorkAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LAPaw(status: state.status).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(state.stepTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                LAStatusText(state: state).font(.caption.weight(.semibold))
            }
            if state.stepCount > 0 && state.status != .done { LAStepDots(state: state) }
            if state.needsUser {
                Link(destination: LA.url(attributes, state)) {
                    Text(LA.s("查看并确认", "Review & confirm")).font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36).background(LA.attention.opacity(0.22), in: Capsule())
                }
            }
            HStack {
                Spacer()
                Text(state.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

#if DEBUG
#Preview("Lock — needs user", as: .content, using: CatpawWorkAttributes(taskID: "t1", conversationID: "c1", title: "一页带来源的报告")) {
    CatpawWorkLiveActivity()
} contentStates: {
    CatpawWorkAttributes.ContentState(status: .running, stepTitle: "读取第 2 份资料", stepIndex: 2, stepCount: 5, needsUserCardID: nil, updatedAt: .now)
    CatpawWorkAttributes.ContentState(status: .needsUser, stepTitle: "确认引用来源", stepIndex: 3, stepCount: 5, needsUserCardID: "card-1", updatedAt: .now)
    CatpawWorkAttributes.ContentState(status: .done, stepTitle: "报告已生成", stepIndex: 5, stepCount: 5, needsUserCardID: nil, updatedAt: .now)
}
#endif
