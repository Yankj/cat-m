import ActivityKit
import SwiftUI
import WidgetKit

/// UI only. Lock screen + Dynamic Island for `CatpawWorkAttributes`. Requires a new Widget Extension target
/// `CatpawWidgets` (iOS 17+, NSSupportsLiveActivities = YES in the app Info.plist). Strings are literal Chinese/English via
/// String(localized:) because the widget can't read the app's UIStrings.json without sharing the bundle.
@main struct CatpawWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CatpawWorkLiveActivity()
        CatpawTodayTasksWidget()
        CatpawQuickAskWidget()
        CatpawCatStatusWidget()
        CatpawLockScreenWidget()
    }
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
                    Text(ctx.state.title.isEmpty ? ctx.attributes.title : ctx.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ctx.state.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if ctx.state.status == .needsUser || ctx.state.status == .reminder {
                            Link(destination: LA.url(ctx.attributes, ctx.state)) {
                                Text(LA.s("查看", "Open")).font(.caption.weight(.semibold))
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
    /// query other than `version`).
    static func url(_ a: CatpawWorkAttributes, _ st: CatpawWorkAttributes.ContentState) -> URL {
        URL(string: "catpawm://conversation/" + a.conversationID) ?? URL(string: "catpawm://")!
    }
    static func color(_ s: CatpawWorkAttributes.ContentState.Status) -> Color {
        switch s {
        case .needsUser, .reminder: attention
        case .done: success
        case .failed: failure
        case .working: paw
        }
    }
    static func label(_ s: CatpawWorkAttributes.ContentState.Status) -> String {
        switch s {
        case .working: s_("进行中", "Working")
        case .needsUser: s_("需要你", "Needs you")
        case .reminder: s_("提醒", "Reminder")
        case .done: s_("已完成", "Done")
        case .failed: s_("需核对", "Check result")
        }
    }
    private static func s_(_ zh: String, _ en: String) -> String { s(zh, en) }
    static func badge(_ s: CatpawWorkAttributes.ContentState.Status) -> String? {
        switch s {
        case .needsUser: "hand.raised.fill"
        case .reminder: "bell.fill"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .working: nil
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
    var body: some View { Text(LA.label(state.status)).foregroundStyle(LA.color(state.status)) }
}

struct LACompactTrailing: View {
    let state: CatpawWorkAttributes.ContentState
    var body: some View {
        switch state.status {
        case .working: ProgressView().progressViewStyle(.circular).tint(LA.paw).frame(width: 18, height: 18)
        case .needsUser: Image(systemName: "hand.raised.fill").foregroundStyle(LA.attention)
        case .reminder: Image(systemName: "bell.fill").foregroundStyle(LA.attention)
        case .done: Image(systemName: "checkmark").foregroundStyle(LA.success)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(LA.failure)
        }
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
                    Text(state.title.isEmpty ? attributes.title : state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(state.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                LAStatusText(state: state).font(.caption.weight(.semibold))
            }
            if state.status == .needsUser || state.status == .reminder {
                Link(destination: LA.url(attributes, state)) {
                    Text(LA.s("查看", "Open")).font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36).background(LA.attention.opacity(0.22), in: Capsule())
                }
            }
        }
        .padding(16)
    }
}

#if DEBUG
#Preview("Lock", as: .content, using: CatpawWorkAttributes(taskID: "t1", conversationID: "c1", title: "一页带来源的报告")) {
    CatpawWorkLiveActivity()
} contentStates: {
    CatpawWorkAttributes.ContentState(title: "一页带来源的报告", body: "读取第 2 份资料", kind: "working", taskID: "t1")
    CatpawWorkAttributes.ContentState(title: "喝水提醒", body: "该起来喝杯水了", kind: "reminder_due", taskID: "t2")
    CatpawWorkAttributes.ContentState(title: "一页带来源的报告", body: "报告已生成", kind: "done", taskID: "t1")
}
#endif
