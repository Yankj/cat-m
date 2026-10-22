import SwiftUI

/// Shared green / red / gray connection status presentation (Settings + chat header).
/// Source of truth remains `ConnectionMonitor` / `ConversationConnection`; this only maps to a dot + short label.
extension ConnectionStatusKind {
    var color: Color {
        switch self {
        case .online: return ConnectionStatusKind.liveGreen
        case .offline: return catColors.tertiary
        case .error: return catColors.failure
        }
    }
}

extension ConnectionStatusKind {
    /// Brighter, more saturated "live" green for the selected-route / connection dot (settings, menu, header).
    static let liveGreen = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.28, green: 0.90, blue: 0.47, alpha: 1)
        : UIColor(red: 0.10, green: 0.78, blue: 0.33, alpha: 1) })
    static let neutralDot = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.74, alpha: 1) })
}

/// Non-template dot image for `Menu` rows (menus re-tint SF Symbols; this keeps the real colour).
enum StatusDotImage {
    static func image(_ color: Color, size: CGFloat = 10) -> Image {
        let ui = UIColor(color)
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            ui.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
        }
        return Image(uiImage: img.withRenderingMode(.alwaysOriginal))
    }
}

struct ConnectionStatusDot: View {
    let kind: ConnectionStatusKind
    var size: CGFloat = 8
    var animated: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle()
            .fill(kind.color)
            .frame(width: size, height: size)
            .animation(animated && !reduceMotion ? .easeInOut(duration: 0.25) : nil, value: kind)
            .accessibilityHidden(true)
    }
}

struct ConnectionStatusRow: View {
    let kind: ConnectionStatusKind
    var detail: String? = nil
    var refreshing: Bool = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        HStack(spacing: 8) {
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                ConnectionStatusDot(kind: kind)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ui(kind.labelKey)).font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
