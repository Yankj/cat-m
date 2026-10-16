import SwiftUI

@MainActor struct VoiceInputSheet: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    let accept: (String) -> Void
    let acceptSubmission: ((FrozenTranscriptSubmission) -> Void)?
    @ObservedObject private var voice = NativeVoiceController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    init(accept: @escaping (String) -> Void, acceptSubmission: ((FrozenTranscriptSubmission) -> Void)? = nil) { self.accept = accept; self.acceptSubmission = acceptSubmission }
    var body: some View {
        NavigationStack { Page {
            Text(ui("说给助理听")).font(.largeTitle.bold())
            Text(ui("结束后先检查转写，再放入当前会话输入。你仍需主动点击发送。")).foregroundStyle(.secondary)
            StatusLabel(text: voice.stateText)
            Button { Task { if voice.capturing { voice.finishInput() } else { await voice.startFromUserAction() } } } label: { Image(systemName: voice.capturing ? "stop.fill" : "mic.fill").font(.largeTitle).frame(width: 96, height: 96).background(CatpawColors.green.opacity(0.2), in: Circle()) }.accessibilityLabel(voice.capturing ? ui("结束本句") : ui("启用本地识别并开始说话"))
            Text(ui("本地中文识别能力：{0}", arguments: [String(describing: (voice.onDeviceSupported ? ui("设备报告支持，尚需实际验收") : ui("不可用")))])).font(.footnote)
            Text(voice.permissionDescription).font(.caption).foregroundStyle(.secondary)
            if let message = voice.messageText { Text(message).foregroundStyle(.secondary) }
            TextEditor(text: Binding(get: { voice.transcript }, set: { voice.editTranscript($0) })).frame(minHeight: 160).accessibilityLabel(ui("可编辑转写"))
            Button(ui("将检查后的文字放入输入")) { do { let submission = try voice.freezeSubmission(); if let acceptSubmission { acceptSubmission(submission) } else { accept(submission.submittedText) }; dismiss() } catch { voice.message = error.localizedDescription } }.primaryAction().disabled(voice.transcript.isEmpty || voice.capturing || voice.state == "transcribing")
            Button(ui("打断本轮")) { voice.interrupt() }.touchTarget()
            Text(ui("原音只在内存处理，最长 45 秒。仅创建 requiresOnDeviceRecognition 请求；不可用时回文字，不转云端识别。")).font(.footnote).foregroundStyle(.secondary)
        }.toolbar { Button(ui("改用文字")) { dismiss() } } }
        .onAppear { voice.language = AppLanguage(locale: uiLocale) }
        .onChange(of: uiLocale.identifier) { _, _ in voice.language = AppLanguage(locale: uiLocale) }
        .onDisappear { voice.interrupt() }
        .onChange(of: scene) { _, value in if value != .active { voice.interrupt() } }
    }
}
@MainActor struct ReadoutSheet: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    let text: String; let reference: DocumentReference; let sourceKind: String
    @ObservedObject private var voice = NativeVoiceController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var mode: ReadoutMode = .full
    @State private var selection = 0
    @State private var speed = 1.0
    private var plan: ReadoutPlan? { try? ReadoutRouter.make(reference: reference, text: text, sourceKind: sourceKind, mode: mode, selectionIndex: selection, rateMultiplier: speed) }
    var body: some View {
        NavigationStack { Page {
            Text(ui("朗读 · v{0}", arguments: [String(describing: (reference.version))])).font(.title.bold())
            Text(ui("只在你主动播放时朗读固定版本。停止声音不会取消文字任务。")).foregroundStyle(.secondary)
            Picker(ui("系统中文音色"), selection: $voice.voiceID) { Text(ui("请主动选择")).tag(""); ForEach(voice.voiceOptions, id: \.0) { item in Text(item.1).tag(item.0) } }
            Picker(ui("朗读范围"), selection: $mode) { Text(ui("全文")).tag(ReadoutMode.full); Text(ui("提取摘要 · 首个非空段落")).tag(ReadoutMode.summary); Text(ui("选中段落")).tag(ReadoutMode.selection) }
            if mode == .selection { Picker(ui("段落"), selection: $selection) { ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { index, paragraph in Text("\(index + 1)：\(String(paragraph.prefix(40)))").tag(index) } } }
            Picker(ui("语速 · 待设备校准"), selection: $speed) { ForEach(ReadoutRouter.rates, id: \.self) { Text("\($0.formatted())×").tag($0) } }
            Text(ui("当前段落 {0}", arguments: [String(describing: (voice.paragraphIndex + 1))])).font(.caption)
            if let plan { DisclosureGroup(ui("本次朗读文本 · 完整原文仍在阅读器")) { Text(plan.speechText).textSelection(.enabled) } }
            StatusLabel(text: voice.stateText)
            if let message = voice.messageText { Text(message).foregroundStyle(.secondary) }
            HStack { Button(ui("播放")) { if let plan { voice.play(plan: plan) } }.disabled(plan?.allowsPublicTTS != true); Button(ui("暂停")) { voice.pause() }; Button(ui("继续")) { voice.resume() }; Button(ui("停读")) { voice.stopPlayback() } }.buttonStyle(.bordered)
            Text(ui(PublicReadoutSample.restriction)).font(.footnote).foregroundStyle(.secondary)
            Text(ui("当前选择来自系统可用声音列表，不申请 Personal Voice，不下载音色。音频输出与离线表现需真机验证。")).font(.footnote).foregroundStyle(.secondary)
        }.toolbar { Button(ui("完成")) { dismiss() } } }
        .onChange(of: voice.voiceID) { _, _ in voice.stopPlayback() }
        .onChange(of: speed) { _, value in voice.changeRateMultiplier(value) }
        .onChange(of: mode) { _, _ in voice.stopPlayback() }
        .onChange(of: selection) { _, _ in voice.stopPlayback() }
        .onChange(of: scene) { _, value in if value != .active { voice.stopPlayback() } }
        .onAppear { voice.language = AppLanguage(locale: uiLocale) }
        .onChange(of: uiLocale.identifier) { _, _ in voice.language = AppLanguage(locale: uiLocale) }
        .onDisappear { voice.stopPlayback() }
    }
}
