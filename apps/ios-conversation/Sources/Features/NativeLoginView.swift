import SwiftUI
import UIKit

@MainActor struct NativeLoginView: View {
    @ObservedObject var auth: NativeAuthApplicationModel

    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}
    @State private var email = ""
    @State private var password = ""
    @Environment(\.scenePhase) private var scene
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:24) {
            Text("Catpaw").font(.largeTitle.weight(.semibold))
            Text(ui("你的个人助理")).font(.title2.weight(.medium))
            Text(ui("点击即可开始。此设备会安全保存体验身份，回来时继续你的对话。")).font(.body).foregroundStyle(CatpawColors.secondary)
            #if DEBUG
            if auth.isFixture {
            Text(ui("合成登录测试 · 无真实 Auth 或模型调用")).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("auth.fixture")
            VStack(spacing:16) {
                TextField(ui("邮箱"),text:$email,prompt:Text(ui("邮箱")).foregroundStyle(CatpawColors.secondary)).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("auth.email")
                SecureField(ui("密码"),text:$password,prompt:Text(ui("密码")).foregroundStyle(CatpawColors.secondary)).textContentType(.password).accessibilityIdentifier("auth.password")
            }.padding(18).background(CatpawColors.panel,in:RoundedRectangle(cornerRadius:18)).disabled(auth.actionBusy || auth.state.phase == .restoring)
            Button(ui("登录")) { let submitted = password;password = "";Task { await auth.signIn(email:email,password:submitted) } }.disabled(!auth.canSignIn || email.isEmpty || password.isEmpty).accessibilityIdentifier("auth.signIn")
            }
            #endif
            if auth.state.phase == .restoring { Text(ui("正在复核登录…")).font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("auth.restoring") }
            if let error = auth.error ?? auth.state.message { Text(ui(error)).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("auth.error") }
            Button {
                Task { await auth.startExperience() }
            } label: {
                HStack { Spacer(); if auth.actionBusy || auth.state.phase == .restoring { ProgressView().tint(CatpawColors.onInk) }; Text(ui("开始体验")); Spacer() }
            }.primaryAction()
                .disabled(!auth.canStartExperience).accessibilityIdentifier("auth.startExperience")
            Text(ui("请保留此设备的登录状态。退出或更换设备后，暂时无法找回体验身份。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
            if auth.error == NativeAuthError.sessionRecoveryRequired.localizedDescription { Button(ui("退出未恢复的会话")) { Task { await auth.signOut() } }.accessibilityIdentifier("auth.closeUnrestoredSession") }
            if auth.state.phase == .signingIn { Button(ui("取消登录")) { password = ""; Task { await auth.cancelLogin() } }.accessibilityIdentifier("auth.cancel") }
            if auth.state.phase == .storageBlocked { Button(ui("重试安全保存")) { Task { await auth.retryStorage() } }.accessibilityIdentifier("auth.retryStorage") }
        }.fixedSize(horizontal:false,vertical:true).padding(24).padding(.top,48)
            .frame(maxWidth:520).frame(maxWidth:.infinity,alignment:.leading)
        }.background(CatpawColors.background).foregroundStyle(CatpawColors.ink)
            .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { CatpawColors.background.ignoresSafeArea() } }
    }
}
