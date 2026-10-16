import SwiftUI
import UIKit

/// First-run flow: launch mark → ONE calm page (serif headline, glowing orb, orbit rings) → swipe-to-start pill
/// that runs anonymous sign-in. Developer configuration problems are never shown to end users (DEBUG banner only).
/// Shown while `auth.needsOnboarding` (gate owned by NativeAuthApplicationModel / `CatpawOnboarding`).
/// Accessibility identifiers `auth.*` are kept for existing UI tests.
@MainActor struct NativeLoginView: View {
    @ObservedObject var auth: NativeAuthApplicationModel

    @Environment(\.locale) private var uiLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}
    @State private var email = ""
    @State private var password = ""
    @State private var startTapped = false
    @Environment(\.scenePhase) private var scene

    private var busy: Bool { auth.onboarding == .entering || auth.actionBusy || auth.state.phase == .restoring || auth.state.phase == .signingIn }
    private var gateFailure: String? { if case .failed(let message) = auth.onboarding { return message }; return nil }
    private static let configurationMessages: Set<String> = [NativeAuthError.notConfigured.localizedDescription, NativeAuthError.invalidConfiguration.localizedDescription, "登录连接尚未配置。", "登录公开配置未通过校验。"]
    /// Configuration errors are a build problem, never the user's.
    private var isConfigurationError: Bool {
        guard let e = gateFailure ?? auth.error else { return false }
        return Self.configurationMessages.contains(e)
    }
    private var friendlyError: String? {
        if let e = gateFailure ?? auth.error ?? auth.state.message, !isConfigurationError { return ui(e) }
        if startTapped, !busy, isConfigurationError || !auth.canStartExperience { return ui("暂时连不上服务，请稍后重试。") }
        return nil
    }

    @State private var shown = false
    @ObservedObject private var serif = EditorialSerif.shared

    var body: some View {
        ZStack {
            CalmGlowBackground()
            // Orb sits at the exact screen centre (ignoring safe areas) so the launch paw→orb morph lands on it pixel-for-pixel.
            ZStack {
                ZStack {
                    OrbitText(text: ui("onboarding.ring.outer"), radius: 130, speed: 1, fontSize: 12)
                    OrbitText(text: ui("onboarding.ring.inner"), radius: 92, speed: -1.4, fontSize: 10).opacity(0.8)
                }
                .opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.92)
                CalmOrb(size: 100) // already on screen from the launch morph; no entrance animation
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                #if DEBUG
                debugBanner.padding(.top, 8)
                #endif
                Text(ui("解放双手，\n让工作\n自己向前走"))
                    .font(serif.font(size: 40))
                    .lineSpacing(4).foregroundStyle(CatpawColors.ink)
                    .padding(.top, 36)
                    .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboarding.headline")
                Spacer()
                footer.frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
        .foregroundStyle(CatpawColors.ink)
        .onAppear { serif.ensure(); withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { shown = true } }
        .accessibilityIdentifier("onboarding.pages")
        .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { CatpawColors.background.ignoresSafeArea() } }
    }

    private func start() {
        startTapped = true
        Task { if auth.needsOnboarding { await auth.completeOnboarding() } else { await auth.startExperience() } }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if auth.state.phase == .restoring { Text(ui("正在复核登录…")).font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("auth.restoring") }
            if let message = friendlyError {
                Text(message).font(.footnote).foregroundStyle(CatpawColors.attention).multilineTextAlignment(.center).accessibilityIdentifier("auth.error")
            }
            SwipeToStart(title: busy ? ui("正在开启…") : (friendlyError != nil ? ui("再试一次") : ui("右滑开始")), busy: busy, action: start)
                .accessibilityIdentifier("auth.startExperience")
            Text(ui("无需注册。此设备会安全保存你的体验身份。")).font(.footnote).foregroundStyle(CatpawColors.secondary).multilineTextAlignment(.center)
            if auth.error == NativeAuthError.sessionRecoveryRequired.localizedDescription { Button(ui("退出未恢复的会话")) { Task { await auth.signOut() } }.accessibilityIdentifier("auth.closeUnrestoredSession") }
            if auth.state.phase == .signingIn { Button(ui("取消登录")) { password = ""; Task { await auth.cancelLogin() } }.accessibilityIdentifier("auth.cancel") }
            if auth.state.phase == .storageBlocked { Button(ui("重试安全保存")) { Task { await auth.retryStorage() } }.accessibilityIdentifier("auth.retryStorage") }
            #if DEBUG
            if auth.isFixture { fixtureLogin }
            #endif
        }
    }

    #if DEBUG
    /// Developer-only: real cause of a disabled sign-in (e.g. Local.xcconfig missing). Never in Release.
    @ViewBuilder private var debugBanner: some View {
        if isConfigurationError, let e = gateFailure ?? auth.error {
            Text(verbatim: "DEBUG · \(e) Configuration/Local.xcconfig → CATPAW_SUPABASE_* / CATPAW_BACKEND_ORIGIN")
                .font(.footnote).foregroundStyle(CatpawColors.secondary).padding(8)
                .background(CatpawColors.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
                .accessibilityIdentifier("auth.debugConfiguration")
        }
    }
    private var fixtureLogin: some View {
        VStack(spacing: 12) {
            Text(ui("合成登录测试 · 无真实 Auth 或模型调用")).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("auth.fixture")
            TextField(ui("邮箱"),text:$email,prompt:Text(ui("邮箱")).foregroundStyle(CatpawColors.secondary)).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("auth.email")
            SecureField(ui("密码"),text:$password,prompt:Text(ui("密码")).foregroundStyle(CatpawColors.secondary)).textContentType(.password).accessibilityIdentifier("auth.password")
            Button(ui("登录")) { let submitted = password;password = "";Task { await auth.signIn(email:email,password:submitted) } }.disabled(!auth.canSignIn || email.isEmpty || password.isEmpty).accessibilityIdentifier("auth.signIn")
        }.padding(14).background(CatpawColors.panel,in:RoundedRectangle(cornerRadius:18)).disabled(auth.actionBusy || auth.state.phase == .restoring)
    }
    #endif

}

