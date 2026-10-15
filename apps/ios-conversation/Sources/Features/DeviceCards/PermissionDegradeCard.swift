import SwiftUI
import UIKit

/// Permission-denied degrade card (proactive meeting/travel assistant demo).
/// Explains the denial, offers manual input that feeds the same suggestion flow, plus 去设置.
/// Reuses `DevicePermissionKind`, `DeviceCardShell` and `PawMark` from PermissionCard (#43).
///
/// Hook: on submit posts `PermissionDegradeCard.manualMeetingNotification` ("catpaw.proactive.manualMeeting")
/// with userInfo `["title": String, "start": Date, "place": String]`, and calls `onManualMeeting`.
/// Fence payload (```catpaw-card, kind `permission_degrade`): `{"id":"…","capability":"calendar"}`.
struct PermissionDegradePayload: Codable, Sendable, Equatable {
    let id: String
    var capability: DevicePermissionKind? = .calendar
}

@MainActor struct PermissionDegradeCard: View {
    static let manualMeetingNotification = Notification.Name("catpaw.proactive.manualMeeting")
    let payload: PermissionDegradePayload
    var onManualMeeting: ((String, Date, String) -> Void)? = nil
    @State private var showForm = false
    @State private var title = ""
    @State private var place = ""
    @State private var start = Date.now.addingTimeInterval(3600)
    @State private var submitted = false
    @ScaledMetric(relativeTo: .title) private var artSize: CGFloat = 44
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }

    var body: some View {
        DeviceCardShell(identifier: "chat.permissionDegrade." + payload.id) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    PawMark(size: artSize, shadow: false).frame(width: artSize, height: artSize)
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(CatpawColors.onInk)
                        .padding(5).background(CatpawColors.ink, in: Circle()).offset(x: 6, y: 6)
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ui("没有日历权限")).font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink)
                    Text(ui("小猫看不到你的会议，所以没法提前提醒出发。可以手动告诉小猫下一场会议，或去设置里打开日历权限。"))
                        .font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if submitted {
                Label(ui("已记下，小猫会按时提醒你"), systemImage: "checkmark.circle.fill")
                    .font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("chat.permissionDegrade.done")
            } else if showForm {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(ui("会议名称"), text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("chat.permissionDegrade.title")
                    DatePicker(ui("开始时间"), selection: $start, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .foregroundStyle(CatpawColors.ink).accessibilityIdentifier("chat.permissionDegrade.start")
                    TextField(ui("地点"), text: $place).textFieldStyle(.roundedBorder).accessibilityIdentifier("chat.permissionDegrade.place")
                    Button(ui("让小猫帮我盯着")) { submit() }
                        .buttonStyle(CatpawPrimaryButtonStyle())
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("chat.permissionDegrade.submit")
                }.font(CatpawTypography.Role.body.font)
            }
            if !submitted {
                HStack(spacing: 10) {
                    if !showForm {
                        Button(ui("手动输入")) { showForm = true }
                            .buttonStyle(CatpawPrimaryButtonStyle()).accessibilityIdentifier("chat.permissionDegrade.manual")
                    }
                    Button(ui("去设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                        .font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).touchTarget()
                        .accessibilityIdentifier("chat.permissionDegrade.settings")
                }
            }
        }
    }

    private func submit() {
        let t = title.trimmingCharacters(in: .whitespaces), p = place.trimmingCharacters(in: .whitespaces)
        onManualMeeting?(t, start, p)
        NotificationCenter.default.post(name: Self.manualMeetingNotification, object: nil, userInfo: ["title": t, "start": start, "place": p])
        submitted = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Registers `permission_degrade` with MarkdownCustomBlockRegistry. Call next to `DeviceStatusCardAdapter.register()`.
@MainActor enum PermissionDegradeCardAdapter {
    private static var registered = false
    static func register() {
        guard !registered else { return }; registered = true
        MarkdownCustomBlockRegistry.shared.register(kind: "permission_degrade") { payload, closed in
            if closed, let value = try? JSONDecoder().decode(PermissionDegradePayload.self, from: payload) { PermissionDegradeCard(payload: value) } else { EmptyView() }
        }
    }
}

#Preview("权限降级卡") { PermissionDegradeCard(payload: .init(id: "d1")).padding() }
