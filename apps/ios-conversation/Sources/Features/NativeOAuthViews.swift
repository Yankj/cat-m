import SwiftUI

/// GitHub / Google entry points. Text is ink/secondary only (no orange text); errors and cancel are a capsule.
@MainActor struct NativeOAuthNoticeCapsule: View {
    let notice: NativeOAuthCoordinator.Notice
    @Environment(\.locale) private var uiLocale
    var body: some View {
        Label(AppLanguage(locale: uiLocale).ui(notice.text), systemImage: notice.isError ? "exclamationmark.circle" : "info.circle")
            .font(CatpawTypography.Role.caption.font)
            .foregroundStyle(CatpawColors.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(CatpawColors.calmSurface.opacity(0.9)))
            .overlay(Capsule().stroke(CatpawColors.secondary.opacity(0.25)))
            .accessibilityIdentifier("oauth.notice")
    }
}

@MainActor struct NativeOAuthProviderButtons: View {
    @ObservedObject var oauth: NativeOAuthCoordinator
    var intent: NativeAccountEntryPlan.Intent = .attach
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String) -> String { AppLanguage(locale: uiLocale).ui(key) }
    var body: some View {
        VStack(spacing: 10) {
            ForEach(NativeOAuthProvider.allCases, id: \.self) { p in
                Button { Task { await oauth.continueWith(p, intent: intent) } } label: {
                    HStack(spacing: 8) {
                        if oauth.busy == p { ProgressView().tint(CatpawColors.ink) }
                        else { Image(systemName: p == .github ? "chevron.left.forwardslash.chevron.right" : "g.circle") }
                        Text(p == .github ? ui("使用 GitHub 继续") : ui("使用 Google 继续"))
                    }
                    .font(CatpawTypography.Role.body.font)
                    .foregroundStyle(CatpawColors.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(CatpawColors.calmSurface))
                    .overlay(Capsule().stroke(CatpawColors.secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .disabled(oauth.busy != nil)
                .accessibilityIdentifier("oauth.\(p.rawValue)")
            }
        }
    }
}

/// Switch confirmation (signing in to a *different* account). Anonymous trial data cannot be recovered after.
extension View {
    func nativeOAuthSwitchConfirmation(_ oauth: NativeOAuthCoordinator) -> some View { modifier(NativeOAuthSwitchModifier(oauth: oauth)) }
}
private struct NativeOAuthSwitchModifier: ViewModifier {
    @ObservedObject var oauth: NativeOAuthCoordinator
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String) -> String { AppLanguage(locale: uiLocale).ui(key) }
    func body(content: Content) -> some View {
        content.confirmationDialog(ui("该账号已存在，切换过去？"), isPresented: Binding(get: { oauth.pendingSwitch != nil }, set: { if !$0 { oauth.pendingSwitch = nil } }), titleVisibility: .visible) {
            Button(ui("退出当前账号并切换")) { Task { await oauth.confirmSwitch() } }
            Button(ui("取消"), role: .cancel) { oauth.pendingSwitch = nil }
        } message: {
            Text(oauth.pendingSwitch?.discardsTrial == true ? ui("体验身份的对话会留在本机但无法再访问；你创建的系统日历/提醒事项会逐项询问是否撤销。") : ui("当前账号的数据会安全停放，再次登录时自动恢复；你创建的系统日历/提醒事项会逐项询问是否撤销。"))
        }
    }
}

/// Landing: keeps「开始使用」(trial) as the primary CTA; third-party login opens a small sheet.
@MainActor struct NativeOAuthLandingEntry: View {
    @Environment(\.catpawOAuth) private var oauth
    @Environment(\.locale) private var uiLocale
    @State private var presented = false
    var body: some View {
        if let oauth, oauth.isAvailable {
            Button(AppLanguage(locale: uiLocale).ui("已有账号？使用 GitHub / Google 登录")) { presented = true }
                .font(CatpawTypography.Role.caption.font)
                .foregroundStyle(CatpawColors.ink)
                .accessibilityIdentifier("oauth.landingEntry")
                .sheet(isPresented: $presented) { NativeOAuthSignInSheet(oauth: oauth).presentationDetents([.height(300)]) }
        }
    }
}
@MainActor struct NativeOAuthSignInSheet: View {
    @ObservedObject var oauth: NativeOAuthCoordinator
    @Environment(\.locale) private var uiLocale
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text(AppLanguage(locale: uiLocale).ui("登录 Catpaw")).font(CatpawTypography.Role.title.font).foregroundStyle(CatpawColors.ink)
            NativeOAuthProviderButtons(oauth: oauth)
            if let n = oauth.notice { NativeOAuthNoticeCapsule(notice: n) }
            Text(AppLanguage(locale: uiLocale).ui("登录凭据只保存在本机钥匙串，可随时退出。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
        }
        .padding(24)
        .onChange(of: oauth.identities) { _, ids in if !ids.isEmpty { dismiss() } }
    }
}

/// Floating OAuth notice for the sidebar account menu (the old settings account panel showed it inline). Auto-clears.
@MainActor struct NativeOAuthNoticeOverlay: View {
    @ObservedObject var oauth: NativeOAuthCoordinator
    var body: some View {
        if let n = oauth.notice {
            NativeOAuthNoticeCapsule(notice: n)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .onTapGesture { oauth.notice = nil }
                .task(id: n.text) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if oauth.notice?.text == n.text { withAnimation(.easeOut(duration: 0.2)) { oauth.notice = nil } }
                }
        }
    }
}

/// Former settings → account panel (linked identities + link buttons). No longer mounted in settings (22:00 IA change);
/// kept for reuse.
@MainActor struct NativeOAuthAccountSection: View {
    @Environment(\.catpawOAuth) private var oauth
    var body: some View { if let oauth, oauth.isAvailable { Inner(oauth: oauth) } }
    private struct Inner: View {
        @ObservedObject var oauth: NativeOAuthCoordinator
        @Environment(\.locale) private var uiLocale
        private func ui(_ key: String) -> String { AppLanguage(locale: uiLocale).ui(key) }
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(ui("登录方式")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                let providers = oauth.identities.filter { $0.provider != "anonymous" }
                if providers.isEmpty { Text(ui("体验账号 · 绑定后可在其他设备登录，对话不丢失")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink) }
                ForEach(providers, id: \.self) { i in
                    Label((i.provider == "github" ? "GitHub" : i.provider == "google" ? "Google" : i.provider) + (i.label.map { " · " + $0 } ?? ""), systemImage: "checkmark.seal")
                        .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink)
                }
                NativeOAuthProviderButtons(oauth: oauth, intent: .attach)
                if let n = oauth.notice { NativeOAuthNoticeCapsule(notice: n) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("oauth.accountSection")
            .task { await oauth.refreshIdentities() }
        }
    }
}
