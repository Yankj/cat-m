import SwiftUI

/// Wave 2 · V3 ReceiptCard (plan §3.1 step 5, §6 render_ui `ReceiptCard`): the closing state of an action,
/// e.g. "✓ 已加入日历 · 打开". Status is always spelled out in text (not color alone).
///
/// Fence payload (```catpaw-card, kind `receipt`):
/// `{"kind":"receipt","id":"…","status":"ok|cancelled|denied|error|pending","title":"已加入日历",
///   "detail":"明天 15:00 · 与张三开会","symbol":"calendar","action":{"label":"打开","url":"calshow:"}}`
struct ReceiptCardPayload: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case ok, cancelled, denied, error, pending }
    struct Action: Codable, Sendable, Equatable { let label: String; let url: String }
    let id: String
    let status: Status
    let title: String
    var detail: String?
    var symbol: String?
    var action: Action?

    /// Only system / app deep links we expect from device tools; never arbitrary schemes from model output.
    static let allowedSchemes: Set<String> = ["https", "calshow", "x-apple-reminderkit", "maps", "iosamap", "baidumap", "shortcuts", "tel", "sms", "mailto", "taobao", "openapp.jdmobile", "imeituan"]
    var safeURL: URL? {
        guard let raw = action?.url, let url = URL(string: raw), let scheme = url.scheme?.lowercased(), Self.allowedSchemes.contains(scheme) else { return nil }
        return url
    }
}

/// Shared r10 card chrome for the device cards (radius 16, panel fill, hairline stroke, padding 16).
@MainActor struct DeviceCardShell<Content: View>: View {
    let identifier: String
    @ViewBuilder var content: Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(catColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(catColors.ink.opacity(0.08), lineWidth: 0.5))
            .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { appeared = true } }
            .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}

@MainActor struct ReceiptCard: View {
    let payload: ReceiptCardPayload
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        DeviceCardShell(identifier: "chat.receipt." + payload.id) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(badgeFill).frame(width: 36, height: 36)
                    Image(systemName: statusSymbol).font(.body.weight(.semibold)).foregroundStyle(badgeIcon)
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.title).font(catTypography.Role.heading.font).foregroundStyle(catColors.ink).fixedSize(horizontal: false, vertical: true)
                    Text(statusText).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                    if let detail = payload.detail, !detail.isEmpty {
                        Text(detail).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if payload.status == .ok, let url = payload.safeURL, let label = payload.action?.label {
                Button { openURL(url) } label: {
                    HStack(spacing: 4) { Text(label); Image(systemName: "arrow.up.right").accessibilityHidden(true) }
                        .font(catTypography.Role.body.font.weight(.medium)).foregroundStyle(catColors.ink)
                }
                .buttonStyle(catPressButtonStyle()).touchTarget()
                .accessibilityIdentifier("chat.receipt.open")
            }
        }
        .accessibilityLabel(Text(payload.title + "，" + statusText))
    }

    private var statusText: String {
        switch payload.status {
        case .ok: ui("已完成")
        case .cancelled: ui("已取消")
        case .denied: ui("未获授权")
        case .error: ui("没有完成，请稍后重试")
        case .pending: ui("等待你回到 App 后继续")
        }
    }
    private var statusSymbol: String {
        switch payload.status {
        case .ok: payload.symbol ?? "checkmark"
        case .cancelled: "xmark"
        case .denied: "lock"
        case .error: "exclamationmark"
        case .pending: "clock"
        }
    }
    // Orange only as a fill / icon color: success uses the paw fill, everything else stays neutral.
    private var badgeFill: Color { payload.status == .ok ? catBrand.paw.opacity(0.16) : catColors.ink.opacity(0.06) }
    private var badgeIcon: Color { payload.status == .ok ? catBrand.paw : catColors.secondary }
}

#Preview("回执") {
    VStack(spacing: 12) {
        ReceiptCard(payload: .init(id: "r1", status: .ok, title: "已加入日历", detail: "明天 15:00 · 与张三开会", symbol: "calendar", action: .init(label: "打开", url: "calshow:")))
        ReceiptCard(payload: .init(id: "r2", status: .cancelled, title: "短信未发送"))
        ReceiptCard(payload: .init(id: "r3", status: .denied, title: "无法读取通讯录"))
    }.padding()
}
