import SwiftUI

/// Three ink dots that shimmer in sequence. Reduce Motion → static "…".
/// Used for in-progress / streaming reply affordances (no status-text pile).
struct StreamShimmerEllipsis: View {
    var active: Bool
    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        let center = (Double(i) + 0.5) / 3.0
                        let dist = min(abs(t - center), abs(t - center - 1), abs(t - center + 1))
                        let lit = max(0, 1 - dist * 4)
                        Circle()
                            .fill(CatpawColors.ink.opacity(0.28 + 0.72 * lit))
                            .frame(width: 5, height: 5)
                            .scaleEffect(0.85 + 0.25 * lit)
                    }
                }
            }
            .accessibilityHidden(true)
        } else {
            Text("…").font(CatpawTypography.Role.secondary.font.weight(.semibold)).foregroundStyle(CatpawColors.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Soft ink highlight that sweeps across a streaming bubble. Brand orange stays off text.
struct BubbleShimmerSweep: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0) / 2.0
            LinearGradient(
                stops: [
                    .init(color: .clear, location: max(0, t - 0.18)),
                    .init(color: CatpawColors.ink.opacity(0.07), location: t),
                    .init(color: .clear, location: min(1, t + 0.18))
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .mask(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// chat-ux-1505 #3: continuous left→right highlight sweep across text (Grok-style 「… 正在工作」). No dots, no spinner.
/// Reduce Motion: gentle opacity pulse instead of motion.
struct WorkingShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var period: Double = 1.6
    func body(content: Content) -> some View {
        if reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.2)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 1.2) % 2 == 0
                content.opacity(on ? 1 : 0.55).animation(.easeInOut(duration: 1.2), value: on)
            }
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                content.overlay {
                    GeometryReader { g in
                        let w = g.size.width, band = max(40, w * 0.45)
                        LinearGradient(colors: [.clear, CatpawColors.ink.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band).offset(x: -band + (w + band) * t)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
extension View { func workingShimmer() -> some View { modifier(WorkingShimmer()) } }
