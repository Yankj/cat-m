import SwiftUI

/// Slow animated brand background for first run. Continues the launch mark's background colour,
/// then drifts a warm paw-tinted mesh (iOS 18+) or gradient (iOS 17). Reduce Motion → static.
@MainActor struct OnboardingBackgroundView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                catColors.background
                if #available(iOS 18.0, *) {
                    MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colors)
                        .opacity(0.55)
                } else {
                    LinearGradient(colors: [catBrand.paw.opacity(0.35), catColors.background, catBrand.paw.opacity(0.18)],
                                   startPoint: UnitPoint(x: 0.5 + 0.4 * cos(t / 6), y: 0), endPoint: UnitPoint(x: 0.5 - 0.4 * cos(t / 6), y: 1))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
    private static let colors: [Color] = [
        catBrand.paw.opacity(0.55), catColors.background, catBrand.paw.opacity(0.25),
        catColors.background, catBrand.paw.opacity(0.35), catColors.background,
        catBrand.paw.opacity(0.2), catColors.background, catBrand.paw.opacity(0.5),
    ]
    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ a: Double, _ speed: Double) -> Float { Float(0.5 + 0.18 * sin(t / speed + a)) }
        return [
            [0, 0], [0.5, 0], [1, 0],
            [0, w(0, 7)], [w(1, 9), w(2, 8)], [1, w(3, 6)],
            [0, 1], [0.5, 1], [1, 1],
        ]
    }
}
