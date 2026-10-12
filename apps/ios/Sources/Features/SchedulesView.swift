import SwiftUI

@MainActor struct SchedulesView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    @State private var tab = 0; @State private var create = false; @State private var template = ""; @State private var editID: UUID?
    let templates = ["整理工作日志，生成日报摘要", "整理会议要点", "生成周报", "整理邮件摘要", "整理待办", "清理文档", "整理日程", "代码审查"]
    var body: some View {
        Page {
            Picker(ui("任务状态"), selection: $tab) { Text(ui("启用中")).tag(0); Text(ui("已暂停")).tag(1); Text(ui("模板")).tag(2) }.pickerStyle(.segmented)
            Text(ui("仅 App 活跃时模拟检查；关闭期间跳过，不补造历史。")).font(.footnote).foregroundStyle(.secondary)
            if tab == 2 { ForEach(templates, id: \.self) { title in Button { template = title; editID = nil; create = true } label: { Panel { Label(title, systemImage: "clock.badge.checkmark") } } } }
            else {
                let rows = model.list("schedule").filter { if case .core(.schedule(let p)) = $0.payload { return p.enabled == (tab == 0) }; return false }
                if rows.isEmpty { EmptyState(title: ui("暂无{0}任务", arguments: [String(describing: (tab == 0 ? ui("启用中") : ui("已暂停")))]), detail: ui("创建规则后会真实保存到本机。")) }
                ForEach(rows) { r in
                    if case .core(.schedule(let p)) = r.payload {
                        Panel { Text(p.title).font(.headline); Text(p.schedule.timezoneID).font(.footnote).foregroundStyle(.secondary); if let due = p.nextDueAt { Text(ui("下次机会：{0}", arguments: [String(describing: (due.formatted()))])).font(.footnote) }; HStack { Button(ui("编辑")) { editID = r.id; create = true }; Button(p.enabled ? ui("暂停") : ui("恢复")) { model.perform { try await model.service.toggleSchedule(scope: model.scope, id: r.id) } }; Spacer(); Button(ui("删除"), role: .destructive) { model.delete(r) } } }
                    }
                }
            }
        }.navigationTitle(ui("定时任务")).toolbar { Button(ui("创建")) { template = ""; editID = nil; create = true } }
        .sheet(isPresented: $create) { ScheduleForm(model: model, template: template, editID: editID).presentationDetents([.large]) }
    }
}
struct ScheduleDraft: Codable, Equatable {
    var title = ""; var prompt = ""; var project: UUID?; var safety = true; var model = "Auto"
    var cadence = "daily"; var hour = 8; var minute = 0; var weekdays = Array(1...7); var timezone = TimeZone.current.identifier
    var intervalHours = 24
    var intervalInput: String?
}
@MainActor struct ScheduleForm: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let template: String; let editID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ScheduleDraft(); @State private var loaded = false; @State private var saving = false; @State private var baseRevision: Int?
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField(ui("任务名称"), text: $draft.title)
                    Picker(ui("工作空间"), selection: $draft.project) { Text(ui("请选择工作区")).tag(UUID?.none); ForEach(model.projects) { Text($0.title).tag(Optional($0.id)) } }
                    Toggle(ui("安全屋模式 · 配置"), isOn: $draft.safety)
                    Picker(ui("模型选择 · 配置"), selection: $draft.model) { ForEach(["Auto", "Lite", "Pro", "Max", "LongCat-2.0", "deepseek-v4-flash"], id: \.self) { Text($0).tag($0) } }
                    TextEditor(text: $draft.prompt).frame(minHeight: 140).accessibilityLabel(ui("提示词"))
                }
                Section(ui("执行频率")) {
                    Picker(ui("频率"), selection: $draft.cadence) { Text(ui("每日")).tag("daily"); Text(ui("每周")).tag("weekly"); Text(ui("间隔")).tag("interval") }.pickerStyle(.segmented)
                    if draft.cadence == "interval" { TextField(ui("间隔小时 · 正整数"), text: Binding(get: { draft.intervalInput ?? String(draft.intervalHours) }, set: { draft.intervalInput = $0; draft.intervalHours = Int($0) ?? 0 })) }
                    else { Stepper(ui("小时 {0}", arguments: [String(describing: (draft.hour))]), value: $draft.hour, in: 0...23); Stepper(ui("分钟 {0}", arguments: [String(describing: (draft.minute))]), value: $draft.minute, in: 0...59) }
                    if draft.cadence == "weekly" { ForEach(1...7, id: \.self) { day in Toggle(["", ui("星期一"), ui("星期二"), ui("星期三"), ui("星期四"), ui("星期五"), ui("星期六"), ui("星期日")][day], isOn: Binding(get: { draft.weekdays.contains(day) }, set: { if $0 { draft.weekdays.append(day) } else { draft.weekdays.removeAll { $0 == day } } })) } }
                    TextField(ui("时区"), text: $draft.timezone)
                    Text(ui("local_session_only · 真实云调度未连接。安全屋只是配置，尚不代表已启用执行沙箱。")).font(.footnote)
                }
            }.navigationTitle(ui("创建定时任务")).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(ui("创建")) { save() }.disabled(saving) }
            }
        }.task {
            if !loaded {
                if let editID, let r = model.record(editID), case .core(.schedule(let p)) = r.payload, let config = try? JSONDecoder().decode(ScheduleTemplate.self, from: p.taskTemplateJSON) {
                    draft.title = p.title; draft.prompt = config.prompt; draft.project = config.projectID; draft.safety = config.configuration.safety; draft.model = config.configuration.model
                    draft.cadence = p.schedule.cadence; draft.hour = p.schedule.localHour; draft.minute = p.schedule.localMinute; draft.weekdays = ScheduleInput.isoWeekdays(p.schedule); draft.timezone = p.schedule.timezoneID; baseRevision = r.header.revision
                    if p.schedule.cadence.hasPrefix("interval_") { draft.cadence = "interval"; draft.intervalHours = Int(p.schedule.cadence.dropFirst(9).dropLast()) ?? 24 }
                } else if template.isEmpty, let data = model.preference("schedule_form_draft").data(using: .utf8), let old = try? JSONDecoder().decode(ScheduleDraft.self, from: data) { draft = old }
                else { draft.title = template; draft.prompt = template }
                loaded = true
            }
        }.onChange(of: draft) { _, value in if loaded { if let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) { model.setPreference("schedule_form_draft", json) } } }
    }
    private func save() {
        guard let project = draft.project else { model.error = ui("请选择工作空间。"); return }
        saving = true
        model.perform {
            defer { saving = false }
            let cadence = draft.cadence == "interval" ? try ScheduleInput.intervalCadence(draft.intervalInput ?? String(draft.intervalHours)) : draft.cadence
            let spec = ScheduleSpec(timezoneID: draft.timezone, cadence: cadence, localHour: draft.hour, localMinute: draft.minute, weekdays: Array(Set(draft.weekdays)), missedRunPolicy: "skip")
            let config = ConversationConfiguration(model: draft.model, safety: draft.safety, subagents: model.configuration.subagents)
            try await model.service.saveSchedule(scope: model.scope, id: editID, revision: baseRevision, title: draft.title, spec: spec, template: ScheduleTemplate(prompt: draft.prompt, projectID: project, environmentID: model.environmentID, configuration: config))
            try await model.service.preference(scope: model.scope, key: "schedule_form_draft", value: ""); dismiss()
        }
    }
}
