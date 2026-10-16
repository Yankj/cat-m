import SwiftUI

/// Shared green / red / gray connection status presentation (Settings + chat header).
/// Source of truth remains `ConnectionMonitor` / `ConversationConnection`; this only maps to a dot + short label.
extension ConnectionStatusKind {
    var color: Color {
        switch self {
        case .online: return CatpawColors.success
        case .offline: return CatpawColors.tertiary
        case .error: return CatpawColors.failure
        }
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
                Text(ui(kind.labelKey)).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
