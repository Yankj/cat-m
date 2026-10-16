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
    private var friendlyError: String? {
        if let e = gateFailure ?? auth.error, !isConfigurationError { return ui(e) }
        if startTapped, !busy, isConfigurationError || !auth.canStartExperience { return ui("暂时连不上服务，请稍后重试。") }
        return nil
    }

    @State private var shown = false
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
        .onAppear {
            serif.ensure()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) { shown = true }
        }
        .accessibilityIdentifier("onboarding.pages")
        .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { CatpawColors.background.ignoresSafeArea() } }
    }

    private var landingBackground: some View {
        ZStack {
            CatpawColors.calmPage
            RadialGradient(
                colors: [
                    CatpawColors.orbLight.opacity(0.28),
                    CatpawColors.calmPeach.opacity(0.12),
                    CatpawColors.calmPage.opacity(0),
                ],
                center: .center,
                startRadius: 20,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var brandAndCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui("Catpaw-m"))
                .font(CatpawTypography.Role.secondary.font.weight(.semibold))
                .foregroundStyle(CatpawColors.ink.opacity(0.72))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.brand")
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
                    .offset(
                        x: CGFloat(cos(angle.radians)) * radius,
                        y: CGFloat(sin(angle.radians)) * radius
                    )
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.48).delay(0.12 + Double(index) * 0.05),
                        value: shown
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
        // Hook for Grok Bot / auth gate: completes onboarding then enters main chat.
        Task { if auth.needsOnboarding { await auth.completeOnboarding() } else { await auth.startExperience() } }
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
                title: busy ? ui("正在开启…") : (friendlyError != nil ? ui("再试一次") : ui("开始使用")),
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
        .background(CatpawColors.calmSurface, in: Capsule())
        .shadow(color: CatpawColors.calmShadow.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
