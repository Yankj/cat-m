import SwiftUI

enum Theme {
    static let primary = Color(red: 1.0, green: 0.48, blue: 0.24)
    static let proactive = Color(red: 0.65, green: 0.55, blue: 0.98)
    static let memory = Color(red: 0.22, green: 0.74, blue: 0.97)
    static let success = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let warning = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let danger = Color(red: 0.97, green: 0.44, blue: 0.44)

    static let background = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let surfaceElevated = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let textSecondary = Color(red: 0.63, green: 0.63, blue: 0.66)
}

struct ProactiveCard: View {
    let item: ProactiveItem
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Theme.proactive)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.headline)
                Text(item.reason)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Button("确认", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary)
                    Button("忽略", action: onDismiss)
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
