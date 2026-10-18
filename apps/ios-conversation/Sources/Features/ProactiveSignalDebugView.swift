import SwiftUI

/// Settings › 调试 › 主动信号模拟. Simulate time / calendar / location and watch the pipeline.
@MainActor struct ProactiveSignalDebugView: View {
    @State private var model = ProactiveSignalDebugModel()
    @State private var meetingTitle = ""
    @State private var meetingPlace = ""
    @State private var meetingIn: Double = 45
    @State private var emitted = false
    @State private var leadMinutes: Double = 15
    @State private var leadResult = ""
    @State private var locAuthResult = ""
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }

    var body: some View {
        Form {
            Section(ui("构建")) {
                LabeledContent("git", value: Self.gitSHA)
                LabeledContent(ui("版本"), value: Self.bundleVersion)
            }
            .accessibilityIdentifier("proactive.debug.build")
            Section(ui("会前提前量（记忆）")) {
                Stepper(ui("提前 {0} 分钟", [String(Int(leadMinutes))]), value: $leadMinutes, in: 5...60, step: 5)
                    .accessibilityIdentifier("proactive.debug.leadMinutes")
                Button(ui("写入记忆并生效")) {
                    Task { leadResult = await ProactiveEngine.shared.setLeadMinutes(Int(leadMinutes)) }
                }.accessibilityIdentifier("proactive.debug.setLead")
                Button(ui("删除该记忆"), role: .destructive) {
                    Task { await ProactiveEngine.shared.clearLeadMinutes() }
                }.accessibilityIdentifier("proactive.debug.clearLead")
                if !leadResult.isEmpty { Text(leadResult).font(.footnote).accessibilityIdentifier("proactive.debug.leadResult") }
                LabeledContent(ui("记忆库"), value: MemoryLibraryHub.backend.map { String(describing: type(of: $0)) } ?? "—")
                NavigationLink(ui("打开 设置 › 记忆")) { MemoryLibraryView(backend: MemoryLibraryHub.pageBackend) }
                    .accessibilityIdentifier("proactive.debug.openMemory")
            }
            Section(ui("一键注入")) {
                Button(ui("注入 {0} 分钟后·望京 SOHO 的会", [String(Int(meetingIn))])) {
                    let mins = Int(meetingIn)
                    model.addFakeMeeting(title: "产品评审会", inMinutes: mins, place: "北京市朝阳区望京 SOHO T1",
                                         latitude: 39.9961, longitude: 116.4806)
                    Task {
                        ProactiveEngine.shared.resetLedger()
                        let id = "inject-" + UUID().uuidString
                        // Optional 「模拟起点」: when debug location is set, pass it explicitly (Why: 从模拟起点 X).
                        // When unset, travelETA uses real CLLocation / fails → 未用到 ETA (no Shanghai fallback).
                        let loc = model.location
                        _ = await ProactiveEngine.shared.handle(
                            .init(source: .simulated, eventID: id, title: "产品评审会",
                                  start: Date.now.addingTimeInterval(Double(mins) * 60),
                                  place: "北京市朝阳区望京 SOHO T1",
                                  simulatedOriginLabel: loc.map(\.name),
                                  simulatedOriginLat: loc?.latitude,
                                  simulatedOriginLon: loc?.longitude)
                        )
                    }
                }
                .accessibilityIdentifier("proactive.debug.injectMeeting")
            }

            Section(ui("引擎")) {
                Button(ui("扫描真实日历")) { Task { await ProactiveEngine.shared.scanCalendar(ask: true) } }.accessibilityIdentifier("proactive.engine.scan")
                Button(ui("清空去重账本")) { ProactiveEngine.shared.resetLedger() }.accessibilityIdentifier("proactive.engine.resetLedger")
                ForEach(ProactiveEngine.shared.log.prefix(12)) { e in
                    Text(e.at.formatted(date: .omitted, time: .standard) + "  " + e.text).font(.footnote.monospaced()).foregroundStyle(e.text.contains("SUPPRESSED") ? CatpawColors.attention : CatpawColors.ink)
                }
            }
            Section(ui("模拟时间")) {
                LabeledContent(ui("当前模拟时间"), value: model.now.formatted(date: .omitted, time: .shortened))
                Stepper(ui("时间偏移 {0} 分钟", [String(Int(model.clockOffsetMinutes))]), value: $model.clockOffsetMinutes, in: -240...720, step: 15)
                    .accessibilityIdentifier("debug.signal.clock")
            }
            Section(ui("日历事件")) {
                ForEach(model.meetings) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).foregroundStyle(CatpawColors.ink)
                        Text(m.start.formatted(date: .omitted, time: .shortened) + " · " + m.place).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                }.onDelete { model.meetings.remove(atOffsets: $0) }
                TextField(ui("会议标题"), text: $meetingTitle)
                TextField(ui("地点"), text: $meetingPlace)
                Stepper(ui("{0} 分钟后开始", [String(Int(meetingIn))]), value: $meetingIn, in: 5...240, step: 5)
                Button(ui("添加模拟会议")) {
                    model.addFakeMeeting(title: meetingTitle.isEmpty ? ui("产品评审会") : meetingTitle, inMinutes: Int(meetingIn), place: meetingPlace.isEmpty ? ui("公司 3 楼会议室") : meetingPlace)
                    meetingTitle = ""; meetingPlace = ""
                }.foregroundStyle(CatpawColors.ink).accessibilityIdentifier("debug.signal.addMeeting")
                Toggle(ui("日历权限已允许"), isOn: $model.calendarAuthorized)
            }
            Section(ui("模拟起点（可选）")) {
                Button(ui("请求定位权限（When-In-Use）")) {
                    Task { locAuthResult = await ProactiveEngine.shared.requestLocationAccess() }
                }.accessibilityIdentifier("proactive.debug.requestLocation")
                if !locAuthResult.isEmpty { Text(locAuthResult).font(.footnote) }
                Picker(ui("模拟起点"), selection: Binding(get: { model.location?.name ?? "" }, set: { n in model.location = ProactiveSignalDebugModel.presets.first { $0.name == n } })) {
                    Text(ui("无位置")).tag("")
                    ForEach(ProactiveSignalDebugModel.presets) { p in Text(ui(p.name)).tag(p.name) }
                }.accessibilityIdentifier("debug.signal.location")
                if let l = model.location {
                    Text(String(format: "%.4f, %.4f", l.latitude, l.longitude)).font(CatpawTypography.Role.caption.font.monospacedDigit()).foregroundStyle(CatpawColors.secondary)
                }
            }
            Section(ui("决策流水线")) {
                Button(model.running ? ui("运行中…") : ui("运行流水线")) { model.run() }
                    .disabled(model.running).foregroundStyle(CatpawColors.ink).accessibilityIdentifier("debug.signal.run")
                ForEach(model.stages) { s in stageRow(s) }
            }
            Section(ui("主动建议")) {
                if let s = model.suggestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title).font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink)
                        if let leave = s.leaveAt { Text(ui("建议 {0} 出发", [leave.formatted(date: .omitted, time: .shortened)])).foregroundStyle(CatpawColors.ink) }
                        Text(s.kind + " · " + s.channel.rawValue).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                    Button(emitted ? ui("已发出") : ui("发出主动建议")) { ProactiveSignalHub.emit(s); emitted = true }
                        .buttonStyle(CatpawPrimaryButtonStyle()).accessibilityIdentifier("debug.signal.emit")
                } else {
                    Text(ui("运行流水线后生成建议")).foregroundStyle(CatpawColors.secondary)
                }
            }
        }
        .font(CatpawTypography.Role.body.font)
        .navigationTitle(ui("主动信号模拟"))
        .onChange(of: model.suggestion) { _, _ in emitted = false }
    }


    // Stamped at build time (Scripts/app-version.py stamp); "?" only for an unstamped preview/CI build.
    private static var gitSHA: String { AppBuildInfo.current.commitLabel ?? "?" }
    private static var bundleVersion: String {
        let info = AppBuildInfo.current
        return "\(info.version ?? "?") (\(info.build ?? "?"))"
    }

    private func stageRow(_ s: ProactiveStageResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol(s.status)).foregroundStyle(s.status == .failed ? CatpawColors.attention : CatpawBrand.paw)
                    .symbolEffect(.pulse, isActive: s.status == .running).accessibilityHidden(true)
                Text(title(s.stage)).font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.ink)
                Spacer()
                Text(statusText(s.status)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            }
            ForEach(s.details, id: \.self) { d in
                Text(d).font(CatpawTypography.Role.caption.font.monospaced()).foregroundStyle(CatpawColors.secondary).textSelection(.enabled)
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("debug.signal.stage." + s.stage.rawValue)
    }
    private func title(_ s: ProactivePipelineStage) -> String {
        switch s { case .collect: ui("采集"); case .filter: ui("过滤"); case .merge: ui("合并"); case .decide: ui("决策"); case .intervene: ui("介入方式") }
    }
    private func statusText(_ s: ProactiveStageStatus) -> String {
        switch s { case .idle: ui("等待"); case .running: ui("进行中"); case .passed: ui("通过"); case .skipped: ui("跳过"); case .failed: ui("失败") }
    }
    private func symbol(_ s: ProactiveStageStatus) -> String {
        switch s { case .idle: "circle"; case .running: "circle.dotted"; case .passed: "checkmark.circle.fill"; case .skipped: "minus.circle"; case .failed: "exclamationmark.circle.fill" }
    }
}
