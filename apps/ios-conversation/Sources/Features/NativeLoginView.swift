import SwiftUI
import UIKit

/// First-run flow: launch mark → animated background → 3 auto-advancing intro pages → one "开启" button
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
    @State private var page = 0
    @State private var userPaged = false
    @State private var startTapped = false
    @Environment(\.scenePhase) private var scene

    private struct IntroPage: Identifiable { let id: Int; let symbol: String; let title: String; let body: String }
    private var pages: [IntroPage] {[
        .init(id: 0, symbol: "sparkles", title: ui("你的主动式助理"), body: ui("说一句想做的事，Catpaw 就开始帮你拆解、执行。")),
        .init(id: 1, symbol: "cloud", title: ui("在云端持续工作"), body: ui("关掉 App 也没关系，任务会在云端继续进行。")),
        .init(id: 2, symbol: "bell.badge", title: ui("到点提醒你"), body: ui("有进展、需要你确认或该行动时，会及时提醒你。")),
    ]}
    private var lastPage: Int { pages.count - 1 }
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

    var body: some View {
        ZStack {
            OnboardingBackgroundView()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < lastPage {
                        Button(ui("跳过")) { withAnimation(.easeInOut(duration: 0.3)) { userPaged = true; page = lastPage } }
                            .font(.subheadline.weight(.medium)).foregroundStyle(CatpawColors.secondary)
                            .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("onboarding.skip")
                    }
                }.padding(.horizontal, 16).frame(height: 44)
                #if DEBUG
                debugBanner
                #endif
                TabView(selection: $page) {
                    ForEach(pages) { p in pageView(p).tag(p.id) }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .simultaneousGesture(DragGesture().onChanged { _ in userPaged = true })
                .accessibilityIdentifier("onboarding.pages")
                dots.padding(.bottom, 24)
                footer.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 520)
            }
        }
        .foregroundStyle(CatpawColors.ink)
        .task { await autoAdvance() }
        .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { CatpawColors.background.ignoresSafeArea() } }
    }

    private func pageView(_ p: IntroPage) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            ZStack {
                Circle().fill(CatpawBrand.paw.opacity(0.16)).frame(width: 132, height: 132)
                if p.id == 0 { PawMark(size: 64) }
                else { Image(systemName: p.symbol).resizable().scaledToFit().frame(width: 56, height: 56).foregroundStyle(CatpawBrand.paw).symbolEffect(.pulse, isActive: !reduceMotion && page == p.id) }
            }.accessibilityHidden(true)
            if p.id == 0 { Text(verbatim: "Catpaw").font(.largeTitle.weight(.bold)) }
            Text(p.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(p.body).font(.body).foregroundStyle(CatpawColors.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 32).frame(maxWidth: 520)
        .accessibilityElement(children: .combine).accessibilityIdentifier("onboarding.page.\(p.id)")
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages) { p in
                Capsule().fill(p.id == page ? CatpawBrand.paw : CatpawColors.secondary.opacity(0.3))
                    .frame(width: p.id == page ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: page)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if auth.state.phase == .restoring { Text(ui("正在复核登录…")).font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("auth.restoring") }
            if let message = friendlyError {
                Text(message).font(.footnote).foregroundStyle(CatpawColors.attention).multilineTextAlignment(.center).accessibilityIdentifier("auth.error")
            }
            Button {
                startTapped = true
                // Gate open (fresh install): persist the flag + enter via the pre-warmed session.
                // Gate already completed (returning user signed out, or -CatpawSkipOnboarding): plain anonymous start.
                Task { if auth.needsOnboarding { await auth.completeOnboarding() } else { await auth.startExperience() } }
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    if busy { ProgressView().tint(CatpawColors.onInk) }
                    Text(busy ? ui("正在开启…") : (friendlyError != nil ? ui("再试一次") : ui("开启")))
                    Spacer()
                }.frame(minHeight: 30)
            }
            .primaryAction()
            .disabled(busy)
            .opacity(page == lastPage ? 1 : 0.0).allowsHitTesting(page == lastPage)
            .accessibilityHidden(page != lastPage)
            .accessibilityIdentifier("auth.startExperience")
            if page == lastPage {
                Text(ui("无需注册。此设备会安全保存你的体验身份。")).font(.footnote).foregroundStyle(CatpawColors.secondary).multilineTextAlignment(.center)
            }
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

    /// Auto-advance every 3.2 s until the user swipes or reaches the last page. Fixtures/UI tests jump to the end.
    private func autoAdvance() async {
        #if DEBUG
        if auth.isFixture { page = lastPage; return }
        #endif
        if !auth.needsOnboarding || ProcessInfo.processInfo.arguments.contains(CatpawOnboarding.skipArgument) { page = lastPage; return }
        while page < lastPage && !userPaged {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if Task.isCancelled || userPaged { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { page = min(page + 1, lastPage) }
        }
    }
}
