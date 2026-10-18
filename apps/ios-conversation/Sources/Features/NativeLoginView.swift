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
        if busy { return nil }   // SPEC-E §1: never show auth errors while busy
        let raw = gateFailure ?? auth.error
        guard let e = raw, !isConfigurationError else { return nil }
        if NativeAuthApplicationModel.isTransientConnectFailure(e) { return nil }
        return ui(e)
    }


    @State private var shown = false
    /// The failure capsule currently shown (auto-dismissed).
    @State private var toast: String?
    // SPEC-E §2.2 (FirstRunTransitionOverlay.swift / FirstRunAppearance.handoff).
    // Splash/login P0: one generation-checked handoff state. The +0.12/+0.14 s timers used to land after a fast
    // failure's reset and hid the CTA and the cat for good (21:41 iPhone 13 screenshot: copy back, no CTA, no cat).
    @State private var handoff = FirstRunHandoffState()
    @State private var handoffTimers: Task<Void, Never>?
    private var leaving: Bool { handoff.leaving }        // tap: chips fold, copy fades, glow fades
    private var heroFlown: Bool { handoff.heroFlown }    // +0.14: the overlay's flying cat has taken over
    private var ctaHidden: Bool { handoff.ctaHidden }    // +0.12: the overlay's morph has taken over
    @State private var ctaReady = false         // hit-testable once the CTA is past 50 % opacity (§2.1)
    @State private var driftOn = false          // chip drift joins at 1.4 s
    @ObservedObject private var serif = EditorialSerif.shared
    @ObservedObject private var transition = FirstRunTransition.shared

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

    /// Splash/login P0: any entry failure (also the transient ones whose text stays hidden) leaves a small retry capsule;
    /// never a full-screen state. The CTA is back as well (「再试一次」 when the session needs a restart).
    private var entryRetryVisible: Bool {
        if case .failed = auth.onboarding, !busy, !leaving { return true }
        return false
    }
    /// After the ≤1.15 s handoff the landing is empty while an attempt still runs (bounded by entryDeadline): a small
    /// floating capsule says so.
    private var entryWaitVisible: Bool { leaving && auth.onboarding == .entering && transition.phase == .done }
    private var ctaTitle: String { busy ? ui("正在开启…") : (auth.requiresSessionRestart ? ui("再试一次") : ui("开始使用")) }

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
                }
                .padding(.horizontal, 24)
            }
        }
        .foregroundStyle(CatpawColors.ink)
        .tint(CatpawColors.ink)                      // text buttons: ink, never orange text
        // Reduce Motion (§3): the whole landing fades out 0.10–0.30 s; no flight, no morph.
        .opacity(leaving && reduceMotion ? 0 : 1)
        .overlay(alignment: .top) {
            if let toast, !leaving { FirstRunToast(message: toast) { self.toast = nil }.padding(.top, 8) }
            else if entryRetryVisible { FirstRunEntryCapsule(message: ui("暂时没能进入"), action: ui("重试"), onAction: start).padding(.top, 8) }
            else if entryWaitVisible { FirstRunEntryCapsule(message: ui("正在进入…"), action: nil, onAction: {}).padding(.top, 8) }
        }
        // Unhosted (today's root): this view draws the flight/morph itself; hosted, FirstRunTransitionHost does.
        .overlay { if !transition.isHosted { FirstRunTransitionOverlay(ctaTitle: ctaTitle, placeholder: ui("问问 Catpaw")) } }
        .onChange(of: friendlyError, initial: true) { _, message in withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.9)) { toast = message } }
        .onAppear {
            // Wait for the launch mark to hand off (it is still overlaid by the root), so the entrance never competes for frames.
            if !LaunchMarkView.isRunning { reveal() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchMarkView.didFinish)) { _ in reveal() }
        .onDisappear { if transition.phase == .leaving, !transition.isHosted { transition.finish() } }
        .accessibilityIdentifier("onboarding.pages")
        // Same policy as the chat: `.inactive` (the Google sign-in sheet, Control Center) no longer blanks the landing.
        .modifier(CatpawPrivacyShield(lockedText: nil, identifier: "onboarding.privacyShield"))
    }

    /// §2.1 entrance; t = 0 when the landing becomes visible.
    private func reveal() {
        guard !shown else { return }
        shown = true   // each element carries its own SPEC-E delay/spring (`entry(_:)`)
        let cta = FirstRunAppearance.entranceStart("cta", reduceMotion: reduceMotion)
        let drift = FirstRunAppearance.entranceStart("drift", reduceMotion: false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((cta + 0.10) * 1_000_000_000))
            ctaReady = true
            try? await Task.sleep(nanoseconds: UInt64(max(0, drift - cta - 0.10) * 1_000_000_000))
            // §7: nothing heavy mid-entrance. The serif request (and its re-render) waits until 1.4 s.
            serif.ensure()
            if !reduceMotion, !leaving { driftOn = true }
        }
    }

    /// Entrance animation for an element on the §2.1 track `id` (Reduce Motion: fade 0.15–0.35 s).
    private func entry(_ id: String, response: Double = 0.50, damping: Double = 0.90) -> Animation {
        let start = FirstRunAppearance.entranceStart(id, reduceMotion: reduceMotion)
        return reduceMotion ? .easeOut(duration: 0.2).delay(start) : .spring(response: response, dampingFraction: damping).delay(start)
    }
    /// §2.2 copy fade: opacity → 0, y → −10, easeOut 0.20 from +0.06 s.
    private var copyOut: Animation {
        let tr = FirstRunAppearance.handoffTrack("copy.fade")
        return .easeOut(duration: tr.end - tr.start).delay(tr.start)
    }

    /// `calmPage` == chat canvas in each mode (FirstRunAppearance). Hosted, it clears before chat rises (+0.20–0.38 s).
    private var landingBackground: some View {
        CatpawColors.calmPage
            .ignoresSafeArea()
            .opacity(leaving && transition.isHosted ? 0 : 1)
            .animation(.linear(duration: 0.18).delay(0.20), value: leaving)
            .accessibilityHidden(true)
    }

    private func rise<V: View>(_ view: V, _ id: String, by dy: CGFloat = 12) -> some View {
        view
            .opacity(shown && !leaving ? 1 : 0)
            .offset(y: leaving ? -10 : (shown || reduceMotion ? 0 : dy))
            .animation(leaving ? copyOut : entry(id), value: shown)
            .animation(copyOut, value: leaving)
    }

    private var brandAndCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            rise(Text(ui("Catpaw-m"))
                .font(CatpawTypography.Role.secondary.font.weight(.semibold))
                .foregroundStyle(CatpawColors.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.brand"), "brand")
            rise(Text(ui("先你一步，把事办妥"))
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.calmSecondary)
                .accessibilityIdentifier("onboarding.brandSubtitle"), "brandSubtitle")
            rise(Text(ui("解放双手，\n让工作自己向前走"))
                .font(serif.headline)
                .lineSpacing(4)
                .foregroundStyle(CatpawColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.headline"), "headline")
            rise(Text(ui("从一句话开始，把事情交给我。"))
                .font(CatpawTypography.Role.secondary.font)
                .foregroundStyle(CatpawColors.calmSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.subtitle"), "subtitle")
        }
        .padding(.top, 28)
    }

    private var heroPhase: FirstRunPlushHero.Phase { !shown ? .hidden : (heroFlown ? .flown : (leaving ? .leaving : .shown)) }

    /// Plush hero + dotted ring + 8 chips (§2.1 stagger; §2.2 fold toward the cat).
    private func capabilityRing(radius: CGFloat) -> some View {
        ZStack {
            // Static warm wash confined to the ring (never an animated blur).
            Circle()
                .fill(RadialGradient(colors: [CatpawColors.orbLight.opacity(FirstRunAppearance.washPeak), CatpawColors.orbLight.opacity(0)], center: .center, startRadius: 20, endRadius: radius * 1.3))
                .frame(width: radius * 2.6, height: radius * 2.6)
                .allowsHitTesting(false)
                .opacity(shown && !leaving ? 1 : 0)
                .animation(leaving ? .linear(duration: 0.40).delay(0.05) : entry("glow", response: 0.6, damping: 0.95), value: shown && !leaving)
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [3, 7]))
                .foregroundStyle(CatpawColors.ink.opacity(0.12))
                .frame(width: radius * 2, height: radius * 2)
                .opacity(shown && !leaving ? 1 : 0)
                .animation(leaving ? copyOut : entry("ring", response: 0.55, damping: 0.88), value: shown && !leaving)
            ForEach(Array(Self.capabilities.enumerated()), id: \.offset) { index, item in
                let angle = Angle.degrees(Double(index) / Double(Self.capabilities.count) * 360 - 90)
                let fold = FirstRunAppearance.handoffTrack("chips.fold\(index)")
                // radius: entrance 0.86R → R; fold R → 0.35R (Reduce Motion: R throughout, fades only).
                let k: CGFloat = reduceMotion ? 1 : (leaving ? 0.35 : (shown ? 1 : 0.86))
                CapabilityChip(icon: item.icon, title: ui(item.key))
                    .modifier(CapabilityFloat(index: index, enabled: driftOn && !leaving && !reduceMotion))
                    .scaleEffect(reduceMotion ? 1 : (leaving ? 0.60 : (shown ? 1 : 0.85)))
                    .opacity(shown && !leaving ? 1 : 0)
                    .offset(x: CGFloat(cos(angle.radians)) * radius * k, y: CGFloat(sin(angle.radians)) * radius * k)
                    .animation(entry("chip\(index)", response: 0.45, damping: 0.80), value: shown)
                    .animation(reduceMotion ? copyOut : .timingCurve(0.32, 0, 0.67, 0, duration: fold.end - fold.start).delay(fold.start), value: leaving)   // easeIn cubic
            }
            FirstRunPlushHero(phase: heroPhase)   // above the chips so they fold under it
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.capabilityRing")
    }

    private var accessibilityCapabilityGrid: some View {
        VStack(spacing: 16) {
            FirstRunPlushHero(phase: heroPhase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(Array(Self.capabilities.enumerated()), id: \.offset) { index, item in
                    CapabilityChip(icon: item.icon, title: ui(item.key))
                        .opacity(shown && !leaving ? 1 : 0)
                        .animation(entry("chip\(index)", response: 0.45, damping: 0.80), value: shown)
                        .animation(copyOut, value: leaving)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("onboarding.capabilityGrid")
    }

    private func start() {
        guard !leaving else { return }
        startTapped = true
        toast = nil
        let generation = handoff.begin(); driftOn = false
        transition.begin(reduceMotion: reduceMotion)
        handoffTimers?.cancel(); handoffTimers = nil
        if !reduceMotion {
            let morph = FirstRunAppearance.handoffTrack("cta.morph").start, flight = FirstRunAppearance.handoffTrack("cat.flight").start
            handoffTimers = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(morph * 1_000_000_000))
                guard !Task.isCancelled else { return }; handoff.hideCTA(generation)
                try? await Task.sleep(nanoseconds: UInt64((flight - morph) * 1_000_000_000))
                guard !Task.isCancelled else { return }; handoff.flyHero(generation)
            }
        }
        Task { @MainActor in
            if !transition.isHosted {
                // Unhosted: the root swaps the instant onboarding completes, so land first (composer handed off at +0.62 s;
                // Reduce Motion: once the landing has faded at +0.30 s), then let the gate in.
                let land = reduceMotion ? FirstRunAppearance.handoffTrack("landing.fade", reduceMotion: true).end : FirstRunAppearance.handoffTrack("composer.handoff").start
                try? await Task.sleep(nanoseconds: UInt64(land * 1_000_000_000))
                transition.handOffAll()
            }
            if auth.needsOnboarding { await auth.completeOnboarding() } else { await auth.startExperience() }
            // Entry did not happen (the gate keeps the landing): come back so the toast / retry is usable.
            if auth.needsOnboarding {
                transition.cancel()
                handoffTimers?.cancel(); handoffTimers = nil   // a late +0.12/+0.14 s timer can no longer hide the CTA/cat
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.9)) {
                    handoff.reset()
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if auth.state.phase == .restoring {
                Text(ui("正在复核登录…"))
                    .font(CatpawTypography.Role.caption.font)
                    .foregroundStyle(CatpawColors.calmSecondary)
                    .accessibilityIdentifier("auth.restoring")
            }
            StartUsingCTA(
                title: ctaTitle,
                busy: busy && !leaving,
                animated: driftOn && !leaving,
                action: start
            )
            .firstRunAnchor(.cta)
            .opacity(shown && !ctaHidden ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 20)
            .animation(ctaHidden ? nil : entry("cta"), value: shown)
            .transaction { if ctaHidden { $0.animation = nil } }
            .allowsHitTesting(ctaReady && !leaving)
            .accessibilityIdentifier("auth.startExperience")
            rise(Text(ui("无需注册，即刻开始"))
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.calmSecondary)
                .multilineTextAlignment(.center), "footer", by: 10)
                .accessibilityIdentifier("onboarding.footer")
            NativeOAuthLandingEntry()
            if auth.requiresSessionRestart, !busy {
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
                .foregroundStyle(CatpawColors.calmSecondary)
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
            TextField(ui("邮箱"), text: $email, prompt: Text(ui("邮箱")).foregroundStyle(CatpawColors.calmSecondary))
                .textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("auth.email")
            SecureField(ui("密码"), text: $password, prompt: Text(ui("密码")).foregroundStyle(CatpawColors.calmSecondary))
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
                .foregroundStyle(CatpawColors.calmChipIcon)   // SPEC-E §1: icon only, 4.79:1 / 7.36:1
                .accessibilityHidden(true)
            Text(title)
                .font(CatpawTypography.Role.caption.font.weight(.medium))
                .foregroundStyle(CatpawColors.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CatpawColors.calmSurface, in: Capsule())    // white / #1F1B18
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
    /// SPEC-E §2.1: drift at 45 % of the old amplitude (≤ 3.2 pt), easing in from rest over 0.8 s (1.4 → 2.2 s).
    private static let scale = CGFloat(FirstRunAppearance.chipDriftScale)
    @State private var up = false
    @State private var moving = false
    // first-run-polish: a repeatForever implicit animation per chip (interpolated by SwiftUI's animation system, no view
    // re-evaluation per frame) replaces eight 30 fps TimelineViews that re-ran the chip body every frame.
    func body(content: Content) -> some View {
        let i = index % Self.periods.count
        content
            .offset(y: enabled && moving ? (up ? Self.amplitudes[i] : -Self.amplitudes[i]) * Self.scale : 0)
            .onAppear { if enabled { start(i) } }
            .onChange(of: enabled) { _, on in if on { start(i) } else { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { up = false; moving = false } } }
    }
    private func start(_ i: Int) {
        let ramp = FirstRunAppearance.entrance(reduceMotion: false).first { $0.id == "drift" }.map { $0.end - $0.start } ?? 0.8
        withAnimation(.easeInOut(duration: ramp)) { moving = true }   // rest → −a, then the loop
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ramp * 1_000_000_000))
            guard moving else { return }
            withAnimation(.easeInOut(duration: Self.periods[i] / 2).repeatForever(autoreverses: true).delay(Self.phases[i] / 6)) { up = true }
        }
    }
}

/// Small floating capsule for a splash failure (replaces the amber footer line): neutral surface, ink text, an auxiliary
/// grey icon, announced to VoiceOver, dismissed by tap or after 4 s (8 s with VoiceOver).
/// Small floating capsule on the landing: 「暂时没能进入 · 重试」 or 「正在进入…」 (spinner). Never full screen.
struct FirstRunEntryCapsule: View {
    let message: String
    let action: String?
    let onAction: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if action == nil { ProgressView().controlSize(.small) }
            Text(message).font(CatpawTypography.Role.caption.font.weight(.medium)).foregroundStyle(CatpawColors.ink)
            if let action {
                Button(action, action: onAction)
                    .font(CatpawTypography.Role.caption.font.weight(.semibold))
                    .accessibilityIdentifier("onboarding.entryRetry")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(CatpawColors.calmSurface, in: Capsule())
        .overlay(Capsule().stroke(CatpawColors.hairline))
        .shadow(color: CatpawColors.calmShadow.opacity(0.12), radius: 12, y: 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.entryCapsule")
    }
}

struct FirstRunToast: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(CatpawTypography.Role.caption.font.weight(.semibold))
                .foregroundStyle(CatpawColors.calmIcon)
                .accessibilityHidden(true)
            Text(message)
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(CatpawColors.calmSurface, in: Capsule())
        .overlay(Capsule().stroke(CatpawColors.hairline))
        .shadow(color: CatpawColors.calmShadow.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 24)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("auth.error")
        .task(id: message) {
            UIAccessibility.post(notification: .announcement, argument: message)
            try? await Task.sleep(nanoseconds: (voiceOver ? 8 : 4) * 1_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { dismiss() }
        }
    }
}
