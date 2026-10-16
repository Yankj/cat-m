import SwiftUI

/// Interaction-polish motion tokens. Press-down must answer within the touch frame;
/// release springs back carrying a little energy. Kept apart from CatpawMotion
/// (launch/brand motion) so the two evolve independently.
enum CatpawInteractionMotion {
    static let pressIn = Animation.spring(response: 0.16, dampingFraction: 0.9)
    static let pressOut = Animation.spring(response: 0.32, dampingFraction: 0.62)
    /// Message bubble rising from the composer into the transcript.
    static let sendRise = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let controlPressScale: CGFloat = 0.94
    static let primaryPressScale: CGFloat = 0.97
    static let messagePressScale: CGFloat = 0.97
}

/// Scale + optional haptic for a pressed state. Reduce Motion keeps the haptic and
/// an opacity cue but drops the scale.
struct CatpawPressEffect: ViewModifier {
    let pressed: Bool
    var scale: CGFloat = CatpawInteractionMotion.controlPressScale
    var dimmed: Double = 1
    var haptic: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(pressed ? dimmed : 1)
            .animation(pressed ? CatpawInteractionMotion.pressIn : CatpawInteractionMotion.pressOut, value: pressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: pressed) { _, now in haptic && now }
    }
}

/// The sent bubble enters from the composer edge: up from below, growing from its
/// trailing-bottom corner, so it reads as the draft moving into the transcript.
struct CatpawSendRiseModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.9 : 1, anchor: .bottomTrailing)
            .offset(y: active ? 36 : 0)
            .opacity(active ? 0 : 1)
    }
}
extension AnyTransition {
    static var catpawSendRise: AnyTransition {
        .asymmetric(insertion: .modifier(active: CatpawSendRiseModifier(active: true), identity: CatpawSendRiseModifier(active: false)),
                    removal: .opacity)
    }
}
