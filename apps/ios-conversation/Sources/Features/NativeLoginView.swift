import SwiftUI
import UIKit

/// First-run landing hub matching docs/refs/landing-capability-hub.png.
/// Cream page + soft radial wash · brand · headline/sub · center glowing paw circle ·
/// 8 capability chips on a dotted ring · tap「开始使用」CTA (no swipe) · footer.
/// Gate: `auth.needsOnboarding` → `completeOnboarding()` (owned by NativeAuthApplicationModel).
/// Accessibility identifiers `auth.*` / `onboarding.*` kept for existing UI tests.
@MainActor struct NativeLoginView: View {
    @ObservedObject var auth: NativeAuthApplicationModel

    @Environment(\.locale) private var uiLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @State private var email = ""
    @State private var password = ""
    @State private var startTapped = false
    @Environment(\.scenePhase) private var scene

    private var busy: Bool { auth.onboarding == .entering || auth.actionBusy || auth.state.phase == .restoring || auth.state.phase == .signingIn }
    private var gateFailure: String? { if case .failed(let message) = auth.onboarding { return message }; return nil }
    private static let configurationMessages: Set<String> = [NativeAuthError.notConfigured.localizedDescription, NativeAuthError.invalidConfiguration.localizedDescription, "登录连接尚未配置。", "登录公开配置未通过校验。"]
    private var isConfigurationError: Bool {
        guard let e = gateFailure ?? auth.error else { return false }
        return Self.configurationMessages.contains(e)
    }
    /// Door-lock copy is never shown here. Transient network / model-route failures belong
    /// in-chat later. Hard session-restart and non-config auth errors can still surface.
    private var friendlyError: String? {
        // first-run-polish: while「开始使用」is entering, a transient auth.error (e.g. the session-restart line set by a
        // retried restore and cleared moments later) must not flash on the splash — only a terminal gate failure shows.
        if busy || leaving { return gateFailure.flatMap { isConfigurationError ? nil : ui($0) } }
        let raw = gateFailure ?? auth.error
        guard let e = raw, !isConfigurationError else { return nil }
        if NativeAuthApplicationModel.isTransientConnectFailure(e) { return nil }
        return ui(e)
    }


    @State private var shown = false
    /// first-run-polish: splash-side exit (lift + fade) played before entering chat; reset if entry fails.
    @State private var leaving = false
    @ObservedObject private var serif = EditorialSerif.shared

    private static let capabilities: [(icon: String, key: String)] = [
        ("bell.fill", "onboarding.chip.reminder"),
        ("calendar", "onboarding.chip.schedule"),
        ("magnifyingglass", "onboarding.chip.research"),
        ("pencil", "onboarding.chip.writing"),
        ("checklist", "onboarding.chip.breakdown"),
        ("list.bullet", "onboarding.chip.organize"),
        ("doc", "onboarding.chip.files"),
        ("bookmark.fill", "onboarding.chip.memory"),
    ]

    var body: some View {
        ZStack {
            landingBackground
            GeometryReader { geo in
                let ring = min(geo.size.width, geo.size.height) * 0.38
                let useRadial = !dynamicTypeSize.isAccessibilitySize && geo.size.height > 560
                VStack(alignment: .leading, spacing: 0) {
                    #if DEBUG
                    debugBanner.padding(.top, 8)
                    #endif
                    brandAndCopy
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 12)
                    Spacer(minLength: 8)
                    if useRadial {
                        capabilityRing(radius: max(118, ring))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(260, ring * 2.35))
                    } else {
                        accessibilityCapabilityGrid
                            .padding(.vertical, 12)
                    }
                    Spacer(minLength: 8)
                    footer
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 10)
                }
                .padding(.horizontal, 24)
            }
        }
        .foregroundStyle(CatpawColors.ink)
        .tint(CatpawColors.ink)                      // text buttons: ink, never orange text
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving && !reduceMotion ? 0.98 : 1)
        .offset(y: leaving && !reduceMotion ? -10 : 0)
        .background(CatpawColors.background.ignoresSafeArea())   // = chat background: the handoff never flashes light/dark
        .onAppear {
            serif.ensure()
            // Wait for the launch mark to hand off, so both animations never compete for frames.
            if !LaunchMarkView.isRunning { reveal() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchMarkView.didFinish)) { _ in reveal() }
        .onChange(of: gateFailure) { _, failure in if failure != nil { withAnimation(FirstRunMotion.animation(reduceMotion: reduceMotion)) { leaving = false } } }
        .accessibilityIdentifier("onboarding.pages")
        .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { CatpawColors.background.ignoresSafeArea() } }
    }

    private func reveal() {
        guard !shown else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.9)) { shown = true }
    }

    /// Same adaptive page as chat (`CatpawColors.background`, system scheme). The warm wash lives in the ring only.
    private var landingBackground: some View {
        CatpawColors.background
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var brandAndCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui("Catpaw-m"))
                .font(CatpawTypography.Role.secondary.font.weight(.semibold))
                .foregroundStyle(CatpawColors.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.brand")
            Text(ui("你的个人 AI 助手"))
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.secondary)
                .accessibilityIdentifier("onboarding.brandSubtitle")
            Text(ui("解放双手，\n让工作自己向前走"))
                .font(serif.headline)
                .lineSpacing(4)
                .foregroundStyle(CatpawColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.headline")
            Text(ui("从一句话开始，把事情交给我。"))
                .font(CatpawTypography.Role.secondary.font)
                .foregroundStyle(CatpawColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.subtitle")
        }
        .padding(.top, 28)
    }

    /// Center glowing paw + dotted ring + 8 white chips (staggered entrance).
    private func capabilityRing(radius: CGFloat) -> some View {
        ZStack {
            // Warm wash confined to the ring (peak FirstRunAppearance.washPeak; copy above/below sees ≤ its tail).
            Circle()
                .fill(RadialGradient(colors: [CatpawColors.orbLight.opacity(FirstRunAppearance.washPeak), CatpawColors.orbLight.opacity(0)], center: .center, startRadius: 20, endRadius: radius * 1.3))
                .frame(width: radius * 2.6, height: radius * 2.6)
                .allowsHitTesting(false)
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [3, 7]))
                .foregroundStyle(CatpawColors.ink.opacity(0.12))
                .frame(width: radius * 2, height: radius * 2)
            CalmOrb(size: 108)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.92)
            ForEach(Array(Self.capabilities.enumerated()), id: \.offset) { index, item in
                let angle = Angle.degrees(Double(index) / Double(Self.capabilities.count) * 360 - 90)
                CapabilityChip(icon: item.icon, title: ui(item.key))
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.86)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.48).delay(0.12 + Double(index) * 0.05),
                        value: shown
                    )
                    .modifier(CapabilityFloat(index: index, enabled: !reduceMotion))
                    .offset(
                        x: CGFloat(cos(angle.radians)) * radius,
                        y: CGFloat(sin(angle.radians)) * radius
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.capabilityRing")
    }

    private var accessibilityCapabilityGrid: some View {
        VStack(spacing: 16) {
            CalmOrb(size: 96)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(Array(Self.capabilities.enumerated()), id: \.offset) { index, item in
                    CapabilityChip(icon: item.icon, title: ui(item.key))
                        .opacity(shown ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.08 + Double(index) * 0.04),
                            value: shown
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("onboarding.capabilityGrid")
    }


    private func start() {
        startTapped = true
        // first-run-polish: play the splash exit (spring lift + fade, or a plain crossfade under Reduce Motion) on the same
        // background as chat, then complete onboarding; the root then swaps to chat with no light→dark cut.
        withAnimation(FirstRunMotion.animation(reduceMotion: reduceMotion)) { leaving = true }
        Task {
            if auth.needsOnboarding { await auth.completeOnboarding() } else { await auth.startExperience() }
            // Entry did not happen (the gate keeps the splash): bring it back so the error / retry is visible.
            if auth.needsOnboarding { withAnimation(FirstRunMotion.animation(reduceMotion: reduceMotion)) { leaving = false } }
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if auth.state.phase == .restoring {
                Text(ui("正在复核登录…"))
                    .font(CatpawTypography.Role.caption.font)
                    .foregroundStyle(CatpawColors.secondary)
                    .accessibilityIdentifier("auth.restoring")
            }
            if let message = friendlyError {
                Text(message)
                    .font(CatpawTypography.Role.caption.font)
                    .foregroundStyle(CatpawColors.attention)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("auth.error")
            }
            StartUsingCTA(
                title: busy ? ui("正在开启…") : (auth.requiresSessionRestart ? ui("再试一次") : ui("开始使用")),
                busy: busy,
                action: start
            )
            .accessibilityIdentifier("auth.startExperience")
            Text(ui("无需注册，即刻开始"))
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.footer")
            if auth.requiresSessionRestart {
                Button(ui("重新开始")) { Task { await auth.signOut() } }
                    .accessibilityIdentifier("auth.closeUnrestoredSession")
            }
            if auth.state.phase == .signingIn {
                Button(ui("取消登录")) { password = ""; Task { await auth.cancelLogin() } }
                    .accessibilityIdentifier("auth.cancel")
            }
            if auth.state.phase == .storageBlocked {
                Button(ui("重试安全保存")) { Task { await auth.retryStorage() } }
                    .accessibilityIdentifier("auth.retryStorage")
            }
            #if DEBUG
            if auth.isFixture { fixtureLogin }
            #endif
        }
    }

    #if DEBUG
    @ViewBuilder private var debugBanner: some View {
        if isConfigurationError, let e = gateFailure ?? auth.error {
            Text(verbatim: "DEBUG · \(e) Configuration/Local.xcconfig → CATPAW_SUPABASE_* / CATPAW_BACKEND_ORIGIN")
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.secondary)
                .padding(8)
                .background(CatpawColors.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .accessibilityIdentifier("auth.debugConfiguration")
        }
    }
    private var fixtureLogin: some View {
        VStack(spacing: 12) {
            Text(ui("合成登录测试 · 无真实 Auth 或模型调用"))
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.attention)
                .accessibilityIdentifier("auth.fixture")
            TextField(ui("邮箱"), text: $email, prompt: Text(ui("邮箱")).foregroundStyle(CatpawColors.secondary))
                .textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("auth.email")
            SecureField(ui("密码"), text: $password, prompt: Text(ui("密码")).foregroundStyle(CatpawColors.secondary))
                .textContentType(.password)
                .accessibilityIdentifier("auth.password")
            Button(ui("登录")) {
                let submitted = password; password = ""
                Task { await auth.signIn(email: email, password: submitted) }
            }
            .disabled(!auth.canSignIn || email.isEmpty || password.isEmpty)
            .accessibilityIdentifier("auth.signIn")
        }
        .padding(14)
        .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 18))
        .disabled(auth.actionBusy || auth.state.phase == .restoring)
    }
    #endif
}

/// White pill chip: orange SF Symbol + ink label (no orange text).
struct CapabilityChip: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(CatpawTypography.Role.caption.font.weight(.semibold))
                .foregroundStyle(CatpawColors.action)
                .accessibilityHidden(true)
            Text(title)
                .font(CatpawTypography.Role.caption.font.weight(.medium))
                .foregroundStyle(CatpawColors.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CatpawColors.card, in: Capsule())    // adaptive (white / #1C1B19); calmSurface was white in dark too
        .overlay(Capsule().stroke(CatpawColors.hairline))
        .shadow(color: CatpawColors.calmShadow.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// Slow, desynchronised vertical drift per capability chip. Each chip gets its own
/// amplitude (3–7pt), period (2.8–4.5s) and phase so the ring never moves in lockstep.
/// Reduce Motion → static (no TimelineView ticks).
struct CapabilityFloat: ViewModifier {
    let index: Int
    let enabled: Bool
    private static let amplitudes: [CGFloat] = [4.0, 6.5, 3.2, 5.6, 7.0, 3.8, 5.0, 6.0]
    private static let periods: [Double] = [3.4, 4.2, 2.9, 3.9, 4.5, 3.1, 3.7, 2.8]
    private static let phases: [Double] = [0.0, 1.9, 4.1, 0.7, 3.3, 5.4, 2.6, 4.8]
    @State private var up = false
    // first-run-polish: a repeatForever implicit animation per chip (interpolated by SwiftUI's animation system, no view
    // re-evaluation per frame) replaces eight 30 fps TimelineViews that re-ran the chip body every frame.
    func body(content: Content) -> some View {
        let i = index % Self.periods.count
        content
            .offset(y: enabled ? (up ? Self.amplitudes[i] : -Self.amplitudes[i]) : 0)
            .onAppear {
                guard enabled else { return }
                withAnimation(.easeInOut(duration: Self.periods[i] / 2).repeatForever(autoreverses: true).delay(Self.phases[i] / 6)) { up = true }
            }
    }
}
