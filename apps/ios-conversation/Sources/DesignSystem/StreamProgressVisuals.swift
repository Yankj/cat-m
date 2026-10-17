import SwiftUI
import UIKit

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
    var active = true
    func body(content: Content) -> some View {
        if reduceMotion || !active || ProcessInfo.processInfo.isLowPowerModeEnabled {
            content   // status-line v1.0: Reduce Motion / waiting / Low Power → fully static, no shimmer
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
extension View { func workingShimmer(_ active: Bool = true) -> some View { modifier(WorkingShimmer(active: active)) } }

// MARK: - status-line v1.0 visual SPEC (/workspace/codex-review/status-line/visual/SPEC.md §1–§11). Deployment target is iOS 17.

/// Low Power Mode as an observable flag (SPEC §10: same path as Reduce Motion).
@MainActor final class LowPowerObserver: ObservableObject {
    static let shared = LowPowerObserver()
    @Published private(set) var enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var token: NSObjectProtocol?
    private init() {
        token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in LowPowerObserver.shared.enabled = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }
}

/// SPEC §5. Text-only sweep: the same text overlaid in `ink`, masked by a soft band tilted 20°.
/// 1.3 s eased sweep + 0.7 s pause; band clamp(0.35w, 44, 120); peak 0.9; 30 fps; clock does not reset on text change.
@MainActor struct StatusShimmer: ViewModifier {
    var active: Bool
    var start: Date
    var highlight: Color = CatpawColors.ink
    static let sweep: Double = 1.3, pause: Double = 0.7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lowPower = LowPowerObserver.shared

    func body(content: Content) -> some View {
        if !active || reduceMotion || lowPower.enabled || scenePhase != .active {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.sweep + Self.pause)
                let p = t < Self.sweep ? Self.ease(t / Self.sweep) : 1.0
                content.overlay {
                    GeometryReader { g in
                        let w = g.size.width
                        let band = min(120, max(44, w * 0.35))
                        let x = -band + (w + 2 * band) * p
                        content
                            .foregroundStyle(highlight)
                            .mask(alignment: .leading) {
                                LinearGradient(stops: [.init(color: .clear, location: 0),
                                                       .init(color: .black.opacity(0.9), location: 0.5),
                                                       .init(color: .clear, location: 1)],
                                               startPoint: UnitPoint(x: 0, y: 0.32), endPoint: UnitPoint(x: 1, y: 0.68))
                                    .frame(width: band, height: g.size.height)
                                    .offset(x: x - band / 2)
                            }
                            .opacity(t < Self.sweep ? 1 : 0)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
    }
    /// cubic-bezier(0.4, 0, 0.2, 1)
    static func ease(_ x: Double) -> Double {
        UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1)).value(at: min(1, max(0, x)))
    }
}

/// SPEC §1–§4, §6–§8, §10–§11: icon slot + one line, crossfade with ±3pt drift, static waiting / failed / stopped.
@MainActor struct StatusLineRow<Trailing: View>: View {
    let phase: StatusLinePhase
    var en = false
    /// Turn start, for the shimmer clock and the Reduce Motion / Low Power elapsed time.
    var startedAt: Date
    /// e.g. 「 · 已完成 2 步」 on stopped rows.
    var suffix: String? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    @ScaledMetric(relativeTo: .subheadline) private var nudgeY: CGFloat = 5
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dts
    @ObservedObject private var lowPower = LowPowerObserver.shared
    @State private var nudge = 0
    @State private var announcer = StatusLineAnnouncementThrottle()
    @State private var lastCategory: String?
    @State private var replay: Task<Void, Never>?

    private var calm: Bool { reduceMotion || lowPower.enabled }
    private var kind: StatusLinePhase.Kind { phase.kind }
    private var title: String { phase.title(en: en) + (suffix ?? "") }
    private var textColor: Color { kind == .waiting ? CatpawColors.ink : CatpawColors.calmSecondary }

    var body: some View {
        // Swift 6: the alignment-guide closure is @Sendable; read the main-actor @ScaledMetric here and capture the value.
        let lineOneCentre = nudgeY
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Visual SPEC v2 §1–§2: static kitten 22pt in a 24pt slot + 12pt tool badge; centred on line 1.
            StatusKitten(pose: phase.pose, badge: phase.badge?.symbol, tone: phase.badge?.tone ?? .neutral,
                         breathe: kind == .working && !calm && onScreen, nudge: nudge, calm: calm)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + lineOneCentre }
            ZStack(alignment: .leading) {
                Text(title)
                    .font(CatpawTypography.Role.secondary.font.weight(kind == .waiting ? .medium : .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(dts.isAccessibilitySize ? 2 : 1).truncationMode(.tail)
                    .modifier(StatusShimmer(active: kind == .working, start: startedAt))
                    .accessibilityLabel(phase.accessibilityTitle(en: en) + (suffix ?? ""))
                    .accessibilityValue(kind == .working ? "\(max(0, Int(Date().timeIntervalSince(startedAt))))s" : "")
                    .accessibilityAddTraits(kind == .working ? .updatesFrequently : [])
                    .id(title)
                    .transition(calm ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 3)),
                                                              removal: .opacity.combined(with: .offset(y: -3))))
            }
            if calm && kind == .working {
                // SPEC §10: liveness without motion — static elapsed time after 3 s, 1 Hz.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = Int(ctx.date.timeIntervalSince(startedAt))
                    if secs >= 3 {
                        Text("· \(secs)s").font(CatpawTypography.Role.secondary.font).monospacedDigit()
                            .foregroundStyle(CatpawColors.calmSecondary).accessibilityHidden(true)
                    }
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .animation(calm ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22), value: title)
        .task(id: kind) {
            // SPEC §7: one nudge 0.35 s after waiting appears; never in Reduce Motion / Low Power.
            guard kind == .waiting, !calm else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { nudge += 1 }
        }
        .onAppear { onScreen = true; announce() }
        .onDisappear { onScreen = false; replay?.cancel() }
        .onChange(of: phase) { _, _ in announce() }
        .accessibilityElement(children: .contain)
    }

    /// SPEC §11: announce only on a category change, ≤ 1 per 2 s; waiting / failed always, high priority; working low.
    private func announce() {
        guard UIAccessibility.isVoiceOverRunning else { lastCategory = phase.category; return }
        let category = phase.category
        guard category != lastCategory else { return }
        lastCategory = category
        replay?.cancel(); replay = nil
        // P1-3: stopped counts as attention too; throttled working states are replayed (latest wins), never dropped.
        let attention = kind != .working
        if let delay = announcer.request(attention: attention, at: Date()) {
            replay = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, lastCategory == category, announcer.request(attention: false, at: Date()) == nil else { return }
                post(attention: false)
            }
            return
        }
        post(attention: attention)
    }
    private func post(attention: Bool) {
        var text = AttributedString(phase.accessibilityTitle(en: en))
        text.accessibilitySpeechAnnouncementPriority = attention ? .high : .low
        AccessibilityNotification.Announcement(text).post()
    }
}

// MARK: - status-line visual SPEC v2: plush kitten + tool badge

/// Badge colours (SPEC v2 §2.2), with the dark-glyph contrast fix on amber and on dark-mode red.
enum StatusBadgeColors {
    private static func c(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        func v(_ h: UInt32, _ a: CGFloat) -> UIColor {
            UIColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? v(dark, da) : v(light, la) })
    }
    static let neutralFill = c(0xF6F4F1, 0x2E2C2A)
    static let amber = c(0xD98A1A, 0xE9A23B)
    static let red = c(0xE0483E, 0xF0605A)
    static let onAmber = c(0x1C1A18, 0x161412)
    static let onRed = c(0xFFFFFF, 0x161412)
    static let hairline = c(0x292622, 0xFFFFFF, 0.14, 0.14)
    static func fill(_ t: StatusLinePhase.BadgeTone) -> Color {
        switch t { case .waiting: return amber; case .failed: return red; case .neutral, .stopped: return neutralFill }
    }
    static func glyph(_ t: StatusLinePhase.BadgeTone) -> Color {
        switch t { case .waiting: return onAmber; case .failed: return onRed; case .stopped: return CatpawColors.calmSecondary; case .neutral: return CatpawColors.ink }
    }
}

/// 12pt circle, 7.5pt semibold glyph, 1pt page-colour ring, 0.5pt hairline on neutral/stopped. Decorative (VO hidden).
@MainActor struct StatusBadge: View {
    let symbol: String
    let tone: StatusLinePhase.BadgeTone
    var nudge = 0
    var body: some View {
        ZStack {
            Circle().fill(CatpawColors.background).frame(width: 14, height: 14)
            Circle().fill(StatusBadgeColors.fill(tone)).frame(width: 12, height: 12)
                .overlay {
                    if tone == .neutral || tone == .stopped { Circle().strokeBorder(StatusBadgeColors.hairline, lineWidth: 0.5) }
                }
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(StatusBadgeColors.glyph(tone))
                // ≈1.5pt within the 12pt badge; fires only when `nudge` changes (waiting, never in RM / Low Power).
                .symbolEffect(.bounce.down, options: .nonRepeating, value: nudge)
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// Static kitten (no PlushMascot wrapper, no shimmer). Pose crossfade 220ms only on pose change; badge 180ms scale 0.6→1 + fade.
@MainActor struct StatusKitten: View {
    let pose: StatusLinePhase.KittenPose
    let badge: String?
    let tone: StatusLinePhase.BadgeTone
    var breathe = false
    var nudge = 0
    var calm = false
    @State private var inhale = false
    private var badgeKey: String { (badge ?? "") + "\(tone)" }
    var body: some View {
        ZStack {
            Image(pose.asset).resizable().interpolation(.high)
                .frame(width: 22, height: 22)
                .scaleEffect(breathe && inhale ? 1.03 : 1, anchor: .bottom)
                .id(pose)
                .transition(.opacity)
        }
        .frame(width: 24, height: 24)
        .animation(calm ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22), value: pose)
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if let badge {
                    StatusBadge(symbol: badge, tone: tone, nudge: nudge)
                        .id(badgeKey)
                        .transition(calm ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .offset(x: 3, y: 3)   // centre (21,21) in the 24pt slot; never clipped
            .animation(calm ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.18), value: badgeKey)
        }
        .onChange(of: breathe, initial: true) { _, on in
            if on { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { inhale = true } }
            else { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { inhale = false } }
        }
        .accessibilityHidden(true)
    }
}
