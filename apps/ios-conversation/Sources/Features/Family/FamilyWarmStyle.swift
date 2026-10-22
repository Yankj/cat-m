import SwiftUI

/// Warm family surfaces built only from existing catColors / catBrandTokens roles
/// (docs/design/family-companion/assets/warm-ui-details-v1-review.png): rounded cards, soft tinted icon wells,
/// state told by text + symbol, never by color alone.
enum FamilyWarm {
    static let corner: CGFloat = 20
    static let iconWell = Color(familyHex: catBrandTokens.peach).opacity(0.22)
}

private extension Color {
    init(familyHex hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

struct FamilyCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: FamilyWarm.corner, style: .continuous).fill(catColors.card))
            .overlay(RoundedRectangle(cornerRadius: FamilyWarm.corner, style: .continuous).stroke(catColors.hairline, lineWidth: 1))
    }
}

struct FamilyIconWell: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(catColors.actionText)
            .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FamilyWarm.iconWell))
            .accessibilityHidden(true)
    }
}

struct FamilyStatusLine: View {
    enum Kind { case pending, scheduled, listening }
    let kind: Kind
    var body: some View {
        switch kind {
        case .pending: Label("尚未加入日程", systemImage: "clock").foregroundStyle(catColors.attention)
        case .scheduled: Label("已加入日程", systemImage: "checkmark.circle.fill").foregroundStyle(catColors.success)
        case .listening: Label("正在听", systemImage: "waveform").foregroundStyle(catColors.actionText)
        }
    }
}

struct FamilyPrimaryButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44) }
            .foregroundStyle(catColors.onInk).background(Capsule().fill(catColors.ink))
    }
}
struct FamilySecondaryButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44) }
            .foregroundStyle(catColors.ink).background(Capsule().stroke(catColors.controlEdge, lineWidth: 1))
    }
}
