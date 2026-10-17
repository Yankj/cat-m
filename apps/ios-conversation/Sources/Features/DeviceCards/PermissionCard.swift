import SwiftUI
import UIKit

/// Wave 2 · V3 permission explainer (plan §0.3): our own card with the cat illustration comes first, the system
/// prompt only after the user taps 继续; after a denial the card offers 去设置.
///
/// Fence payload (```catpaw-card, kind `permission`):
/// `{"kind":"permission","id":"…","capability":"calendar","reason":"把会议加入你的日历"}`
enum DevicePermissionKind: String, Codable, Sendable, CaseIterable {
    case calendar, reminders, contacts, notifications, location, photos, microphone, speech
    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .notifications: "bell"
        case .location: "location"
        case .photos: "photo.on.rectangle"
        case .microphone: "mic"
        case .speech: "waveform"
        }
    }
    var titleKey: String {
        switch self {
        case .calendar: "允许小猫使用日历"
        case .reminders: "允许小猫使用提醒事项"
        case .contacts: "允许小猫查找联系人"
        case .notifications: "允许小猫给你发通知"
        case .location: "允许小猫使用你的位置"
        case .photos: "允许小猫访问照片"
        case .microphone: "允许小猫使用麦克风"
        case .speech: "允许小猫识别语音"
        }
    }
    /// Default purpose text; App Review 5.1.1 wants specific copy, so the agent's `reason` wins when present.
    var defaultReasonKey: String {
        switch self {
        case .calendar: "用来查看空闲时间、把你确认的日程加进日历。"
        case .reminders: "用来把你确认的待办加进提醒事项。"
        case .contacts: "用来找到你要联系的人。只在这次请求里用到，不会保存。"
        case .notifications: "任务完成或需要你确认时及时告诉你。"
        case .location: "用来查找你附近的地点。"
        case .photos: "用来挑选你要发给小猫的照片。"
        case .microphone: "用来听你说话，转成文字。"
        case .speech: "在本机把你的语音转成文字。"
        }
    }
}

enum DevicePermissionStatus: String, Sendable { case notDetermined, authorized, limited, denied, restricted, unavailable }

/// Seam: the real EventKit / Contacts / UNUserNotificationCenter checks live with the Mac worker's DeviceToolRouter (M1),
/// which also owns the Info.plist usage strings. Without it the stub keeps Previews and demo mode working.
@MainActor protocol DevicePermissionProviding: AnyObject {
    func status(_ kind: DevicePermissionKind) async -> DevicePermissionStatus
    func request(_ kind: DevicePermissionKind) async -> DevicePermissionStatus
}

@MainActor final class DevicePermissionStub: DevicePermissionProviding {
    var states: [DevicePermissionKind: DevicePermissionStatus]
    var answer: DevicePermissionStatus
    init(states: [DevicePermissionKind: DevicePermissionStatus] = [:], answer: DevicePermissionStatus = .authorized) { self.states = states; self.answer = answer }
    func status(_ kind: DevicePermissionKind) async -> DevicePermissionStatus { states[kind] ?? .notDetermined }
    func request(_ kind: DevicePermissionKind) async -> DevicePermissionStatus { states[kind] = answer; return answer }
}

/// Injection point for M1 (`DevicePermissionHub.provider = DeviceToolRouter.shared`).
@MainActor enum DevicePermissionHub {
    static var provider: any DevicePermissionProviding = DevicePermissionStub()
}

struct PermissionCardPayload: Codable, Sendable, Equatable {
    let id: String
    let capability: DevicePermissionKind
    var reason: String?
}

@MainActor struct PermissionCard: View {
    let payload: PermissionCardPayload
    var providerOverride: (any DevicePermissionProviding)? = nil
    var onResult: ((DevicePermissionStatus) -> Void)? = nil
    @State private var status: DevicePermissionStatus?
    @State private var asking = false
    @State private var dismissed = false
    @ScaledMetric(relativeTo: .title) private var artSize: CGFloat = 44
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private var provider: any DevicePermissionProviding { providerOverride ?? DevicePermissionHub.provider }
    private var kind: DevicePermissionKind { payload.capability }

    var body: some View {
        DeviceCardShell(identifier: "chat.permission." + payload.id) {
            switch status {
            case .authorized?, .limited?:
                Label(ui("已允许，可以继续了"), systemImage: "checkmark.circle.fill").labelStyle(PermissionIconLabelStyle())
                    .font(CatpawTypography.Role.body.font).frame(minHeight: 44, alignment: .leading)
            case .denied?, .restricted?:
                header
                Text(ui("你之前没有允许。可以在系统设置里打开，回来后小猫会继续。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
                Button(ui("去设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    .buttonStyle(CatpawPrimaryButtonStyle()).accessibilityIdentifier("chat.permission.settings")
            case .unavailable?:
                header
                Text(ui("这台设备暂不支持这项功能。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
            default:
                if dismissed {
                    Label(ui("暂不允许"), systemImage: "minus.circle").font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary).frame(minHeight: 44, alignment: .leading)
                } else {
                    header
                    HStack(spacing: 10) {
                        Button(ui("继续")) { Task { await ask() } }
                            .buttonStyle(CatpawPrimaryButtonStyle()).disabled(asking || status == nil).accessibilityIdentifier("chat.permission.continue")
                        Button(ui("暂不")) { dismissed = true; onResult?(.denied) }
                            .font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary).touchTarget().accessibilityIdentifier("chat.permission.later")
                    }
                }
            }
        }
        .task { status = await provider.status(kind) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { status = await provider.status(kind) } } }   // back from Settings
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                BrandMark(size: artSize, style: .fill).frame(width: artSize, height: artSize)
                Image(systemName: kind.symbol).font(.footnote.weight(.semibold)).foregroundStyle(CatpawColors.onInk)
                    .padding(5).background(CatpawColors.ink, in: Circle()).offset(x: 6, y: 6)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(ui(kind.titleKey)).font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
                Text(payload.reason ?? ui(kind.defaultReasonKey)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ask() async {
        asking = true; defer { asking = false }
        let result = await provider.request(kind)
        status = result; onResult?(result)
        UINotificationFeedbackGenerator().notificationOccurred(result == .authorized || result == .limited ? .success : .warning)
    }
}

private struct PermissionIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon.foregroundStyle(CatpawBrand.paw); configuration.title.foregroundStyle(CatpawColors.ink) }
    }
}

/// Registers `receipt` and `permission` with `MarkdownCustomBlockRegistry` (#34). Called from `CatpawMApp.init`.
@MainActor enum DeviceStatusCardAdapter {
    private static var registered = false
    static func register() {
        guard !registered else { return }; registered = true
        let decoder = JSONDecoder()
        MarkdownCustomBlockRegistry.shared.register(kind: "receipt") { payload, closed in
            if closed, let value = try? decoder.decode(ReceiptCardPayload.self, from: payload) { ReceiptCard(payload: value) } else { EmptyView() }
        }
        MarkdownCustomBlockRegistry.shared.register(kind: "permission") { payload, closed in
            if closed, let value = try? decoder.decode(PermissionCardPayload.self, from: payload) { PermissionCard(payload: value) } else { EmptyView() }
        }
    }
}

#Preview("权限说明卡") {
    VStack(spacing: 12) {
        PermissionCard(payload: .init(id: "p1", capability: .calendar, reason: nil), providerOverride: DevicePermissionStub())
        PermissionCard(payload: .init(id: "p2", capability: .contacts, reason: nil), providerOverride: DevicePermissionStub(states: [.contacts: .denied]))
    }.padding()
}
