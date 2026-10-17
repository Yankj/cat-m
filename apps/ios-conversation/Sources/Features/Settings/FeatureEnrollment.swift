import SwiftUI

/// catpaw.feature-enrollment.v1 (services/edge/docs/feature-enrollment.md) on catpaw-api.
/// The invite code is never logged or stored: it lives only in the text field and the request body.
@MainActor @Observable final class FeatureEnrollment {
    static let shared = FeatureEnrollment()
    struct Features: Equatable { var agentMemory = false, taskTools = false, generativeUI = false, deviceTools = false, proactive = false }
    enum Phase: Equatable { case idle, submitting, done, invalid, rateLimited(until: Date), signedOut, failed }
    private(set) var enrolled: Bool?
    private(set) var features = Features()
    var phase: Phase = .idle
    /// Set when catpaw-proactive answers 403 feature_disabled: UI shows the enroll prompt instead of an error.
    var proactiveDisabled = false

    private var base: URL? {
        (Bundle.main.infoDictionary?["CatpawBackendOrigin"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }?.appendingPathComponent("catpaw/features/v1")
    }
    private func request(_ path: String, method: String, body: [String: Any]? = nil) async -> (Int, [String: Any], HTTPURLResponse?)? {
        guard let base, let bearer = try? await CatpawPushTokenUploader.shared.bearer() else { return nil }
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 10)
        r.httpMethod = method; r.setValue(bearer, forHTTPHeaderField: "Authorization")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        guard let (data, response) = try? await URLSession.shared.data(for: r), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:], http)
    }
    private func apply(_ json: [String: Any]) {
        if let e = json["enrolled"] as? Bool { enrolled = e }
        if let f = json["features"] as? [String: Any] {
            features = .init(agentMemory: f["agent_memory"] as? Bool ?? false, taskTools: f["task_tools"] as? Bool ?? false,
                             generativeUI: f["generative_ui"] as? Bool ?? false, deviceTools: f["device_tools"] as? Bool ?? false, proactive: f["proactive"] as? Bool ?? false)
            if features.proactive { proactiveDisabled = false }
        }
    }
    /// After login and on foreground.
    func refresh() async {
        guard let (status, json, _) = await request("me", method: "GET") else { return }
        if status == 200 { apply(json) }
    }
    func submit(_ code: String) async {
        if case .rateLimited(let until) = phase, until > .now { return }
        phase = .submitting
        guard let (status, json, http) = await request("enroll", method: "POST", body: ["invite_code": code]) else { phase = .failed; return }
        switch status {
        case 200: apply(json); phase = .done
        case 422: phase = .invalid
        case 429:
            let seconds = (json["error"] as? [String: Any])?["retry_after_sec"] as? Double ?? http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 900
            phase = .rateLimited(until: .now.addingTimeInterval(seconds))
        case 401: phase = .signedOut
        default: phase = .failed
        }
    }
}

/// Settings row → sheet with one field + 提交. Shown while `enrolled == false` (or the proactive gate is off).
@MainActor struct FeatureEnrollmentSection: View {
    @State private var enrollment = FeatureEnrollment.shared
    @State private var presented = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        Group {
            if enrollment.enrolled == false || enrollment.proactiveDisabled {
                Section {
                    Button { presented = true } label: {
                        Label(ui("邀请码"), systemImage: "ticket").foregroundStyle(CatpawColors.ink)
                    }.accessibilityIdentifier("settings.invite")
                } footer: { Text(ui("输入邀请码开启主动提醒、记忆和设备工具。")) }
            }
        }
        .task { await enrollment.refresh() }
        .sheet(isPresented: $presented) { FeatureEnrollmentSheet().presentationDetents([.medium]) }
    }
}

@MainActor struct FeatureEnrollmentSheet: View {
    @State private var enrollment = FeatureEnrollment.shared
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private var valid: Bool {
        let s = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let body = s.hasPrefix("CP") ? String(s.dropFirst(2)) : s
        return body.count == 12
    }
    private var locked: Bool { if case .rateLimited(let until) = enrollment.phase { return until > .now }; return false }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField(ui("输入邀请码"), text: $code, prompt: Text(verbatim: "CP-XXXX-XXXX-XXXX"))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().privacySensitive()
                    .font(CatpawTypography.Role.body.font.monospaced())
                    .padding(14).background(CatpawColors.input, in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused).submitLabel(.done).onSubmit(submit)
                    .accessibilityIdentifier("invite.field")
                if let message { Text(message).font(CatpawTypography.Role.secondary.font).foregroundStyle(messageIsError ? CatpawColors.destructive : CatpawColors.secondary).transition(.opacity) }
                Button(action: submit) {
                    HStack { if enrollment.phase == .submitting { ProgressView().tint(CatpawColors.onInk) }; Text(ui("提交")) }.frame(maxWidth: .infinity)
                }
                .buttonStyle(CatpawPrimaryButtonStyle())
                .disabled(!valid || locked || enrollment.phase == .submitting)
                .accessibilityIdentifier("invite.submit")
                Spacer()
            }
            .padding(20)
            .navigationTitle(ui("邀请码")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ui("关闭")) { dismiss() } } }
            .animation(.snappy, value: enrollment.phase)
            .onAppear { focused = true; if enrollment.phase == .done || enrollment.phase == .invalid { enrollment.phase = .idle } }
            .onChange(of: enrollment.phase) { _, p in if p == .done { code = ""; Task { try? await Task.sleep(nanoseconds: 900_000_000); dismiss() } } }
        }
    }
    private var messageIsError: Bool { switch enrollment.phase { case .invalid, .rateLimited, .signedOut, .failed: true; default: false } }
    private var message: String? {
        switch enrollment.phase {
        case .done: return ui("已开启新功能")
        case .invalid: return ui("邀请码无效或已过期")
        case .rateLimited(let until): return AppLanguage(locale: locale).ui("尝试次数过多，请 {0} 分钟后再试", arguments: [String(max(1, Int(ceil(until.timeIntervalSinceNow / 60))))])
        case .signedOut: return ui("登录已过期，请重新登录后再试")
        case .failed: return ui("暂时连不上服务，请稍后重试")
        default: return nil
        }
    }
    private func submit() { guard valid, !locked else { return }; let c = code; Task { await enrollment.submit(c) } }
}
