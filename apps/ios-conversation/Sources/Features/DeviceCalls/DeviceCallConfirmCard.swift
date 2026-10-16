import SwiftUI

/// Per-tool presentation: icon, title, which args to show (in order) and which the user may edit.
struct DeviceCallSpec: Sendable {
    struct Field: Sendable { let key: String; let labelKey: String; var editable = true; var kind: Kind = .text
        enum Kind: Sendable { case text, date, multiline, phone } }
    let symbol: String
    let titleKey: String
    let confirmKey: String
    let fields: [Field]
    /// Footnote for tools the system must confirm again (compose sheets, tel prompt).
    var noteKey: String?

    static func of(_ tool: String) -> DeviceCallSpec {
        switch tool {
        case "calendar_create": .init(symbol: "calendar.badge.plus", titleKey: "加入日历", confirmKey: "加入", fields: [
            .init(key: "title", labelKey: "标题"), .init(key: "start", labelKey: "开始", kind: .date), .init(key: "end", labelKey: "结束", kind: .date),
            .init(key: "location", labelKey: "地点"), .init(key: "notes", labelKey: "备注", kind: .multiline), .init(key: "alarms", labelKey: "提前提醒（分钟）", editable: false)])
        case "reminder_create": .init(symbol: "checklist", titleKey: "新建提醒", confirmKey: "创建", fields: [
            .init(key: "title", labelKey: "内容"), .init(key: "due", labelKey: "时间", kind: .date), .init(key: "list", labelKey: "列表")])
        case "sms_compose": .init(symbol: "message", titleKey: "发短信", confirmKey: "去发送", fields: [
            .init(key: "to", labelKey: "收件人", kind: .phone), .init(key: "body", labelKey: "内容", kind: .multiline)], noteKey: "会打开系统短信页，由你点发送。")
        case "mail_compose": .init(symbol: "envelope", titleKey: "写邮件", confirmKey: "去发送", fields: [
            .init(key: "to", labelKey: "收件人"), .init(key: "cc", labelKey: "抄送"), .init(key: "subject", labelKey: "主题"), .init(key: "body", labelKey: "内容", kind: .multiline)],
            noteKey: "会打开系统邮件页，由你点发送。")
        case "phone_call": .init(symbol: "phone", titleKey: "打电话", confirmKey: "呼叫", fields: [
            .init(key: "name", labelKey: "联系人", editable: false), .init(key: "number", labelKey: "号码", kind: .phone)], noteKey: "系统还会再确认一次。")
        case "maps_open": .init(symbol: "map", titleKey: "打开地图", confirmKey: "打开", fields: [
            .init(key: "query", labelKey: "地点"), .init(key: "mode", labelKey: "出行方式", editable: false)])
        case "shop_open": .init(symbol: "bag", titleKey: "去购物 App", confirmKey: "打开", fields: [
            .init(key: "platform", labelKey: "平台", editable: false), .init(key: "query", labelKey: "搜索")], noteKey: "只帮你打开，不会代下单。")
        case "alarm_set": .init(symbol: "alarm", titleKey: "设闹钟", confirmKey: "设置", fields: [
            .init(key: "time", labelKey: "时间", kind: .date), .init(key: "label", labelKey: "标签")])
        case "shortcut_run": .init(symbol: "square.stack.3d.up", titleKey: "运行快捷指令", confirmKey: "运行", fields: [
            .init(key: "name", labelKey: "快捷指令", editable: false), .init(key: "input", labelKey: "输入")])
        case "contacts_search": .init(symbol: "person.crop.circle", titleKey: "查联系人", confirmKey: "查找", fields: [
            .init(key: "query", labelKey: "找谁")], noteKey: "点「查找」后，匹配到的姓名和电话才会发给小猫。")
        case "places_search": .init(symbol: "mappin.and.ellipse", titleKey: "查附近", confirmKey: "查找", fields: [
            .init(key: "query", labelKey: "找什么"), .init(key: "mode", labelKey: "出行方式", editable: false)])
        default: .init(symbol: "iphone", titleKey: "在这台 iPhone 上执行", confirmKey: "执行", fields: [])
        }
    }
    var doneKey: String {
        switch confirmKey { case "加入": "已加入日历"; case "创建": "已创建提醒"; case "去发送": "已打开发送页"; case "呼叫": "已发起呼叫"; case "设置": "已设置"; case "运行": "已运行"; default: "已完成" }
    }
}

/// Wave 2 · V3 device-capability confirm card (plan §3.1 steps 2 and 5): icon + summary + editable fields,
/// [执行] [编辑] [取消], then a receipt row ("✓ 已加入日历 · 打开"). Low-risk calls (`confirm: none`) run without asking.
@MainActor struct DeviceCallConfirmCard: View {
    let call: DeviceCall
    @ObservedObject private var store = DeviceCallStore.shared
    @ObservedObject private var blockStore = GenerativeBlockStore.shared
    @State private var editing = false
    @ObservedObject private var ledger = DeviceLedger.shared
    @State private var undoFailed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var spec: DeviceCallSpec { .of(call.tool) }
    private var args: [String: DeviceCallValue] { call.args.merging(store.edited[call.id] ?? [:]) { _, new in new } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let phase: DeviceCallStore.Phase = expired(at: context.date) && store.phase(call.id) == .confirming ? .expired : store.phase(call.id)
            VStack(alignment: .leading, spacing: 12) {
                header
                switch phase {
                case .confirming:
                    fields
                    if let note = spec.noteKey { Text(ui(note)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true) }
                    actions
                case .running:
                    fields
                    HStack(spacing: 8) { ProgressView(); Text(ui("正在执行…")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary) }
                        .frame(minHeight: 44).accessibilityIdentifier("chat.deviceCall.running")
                case .done(let result): receipt(result, reportFailed: false)
                case .reportFailed(let result): receipt(result, reportFailed: true)
                case .expired:
                    Label(ui("已过期，需要的话再跟小猫说一次"), systemImage: "clock").font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CatpawColors.ink.opacity(0.08), lineWidth: 0.5))
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: phase)
        }
        .onAppear {
            _ = store.firstSeen(call.id)
            if store.isInterrupted(call.id) { Task { await store.resumeInterrupted(call.id) } }   // NoBug P0-3: killed mid-run
            else if DeviceToolContract.runsWithoutTap(tool: call.tool, confirm: call.confirm) { Task { await store.run(call) } }
        }
        .sheet(isPresented: $editing) { DeviceCallEditSheet(call: call, spec: spec, values: args) { store.edited[call.id] = $0 } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.deviceCall." + call.id)
    }

    private func expired(at date: Date) -> Bool {
        guard let deadline = call.deadline(firstSeen: store.firstSeen(call.id)) else { return false }
        return date > deadline
    }

    private var header: some View {
        HStack(spacing: 10) {
            CircleIcon(systemName: spec.symbol, diameter: 34)
                .overlay(alignment: .bottomTrailing) { CategoryPaw(category: .forTool(call.tool)).offset(x: 4, y: 3) }
                .accessibilityHidden(true)
            Text(ui(spec.titleKey)).font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var fields: some View {
        let shown = spec.fields.filter { !(args[$0.key]?.text ?? "").isEmpty }
        if shown.isEmpty && spec.fields.isEmpty {
            // Unknown tool: show its raw arguments read-only so the user still sees what will happen.
            ForEach(args.keys.sorted(), id: \.self) { key in row(label: key, value: args[key]?.text ?? "") }
        } else {
            ForEach(shown, id: \.key) { field in row(label: ui(field.labelKey), value: display(args[field.key], kind: field.kind)) }
        }
    }

    private func row(label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).frame(minWidth: 56, alignment: .leading)
                Text(value).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {   // large Dynamic Type sizes stack label over value
                Text(label).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                Text(value).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func display(_ value: DeviceCallValue?, kind: DeviceCallSpec.Field.Kind) -> String {
        guard let value else { return "" }
        if kind == .date, case .string(let raw) = value, let date = DeviceCallDates.parse(raw) {
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        }
        return value.text
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { primary; if hasEditable { editButton }; cancelButton }
            VStack(spacing: 6) { primary; if hasEditable { editButton }; cancelButton }
        }
    }
    private var hasEditable: Bool { spec.fields.contains { $0.editable } }
    private var primary: some View {
        Button(ui(spec.confirmKey)) { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); Task { await store.run(call) } }
            .buttonStyle(CatpawPrimaryButtonStyle()).accessibilityIdentifier("chat.deviceCall.run")
    }
    private var editButton: some View {
        Button(ui("编辑")) { editing = true }.font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).touchTarget()
            .accessibilityIdentifier("chat.deviceCall.edit")
    }
    private var cancelButton: some View {
        Button(ui("取消")) { Task { await store.cancel(call) } }.font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary).touchTarget()
            .accessibilityIdentifier("chat.deviceCall.cancel")
    }

    @ViewBuilder private func receipt(_ result: DeviceCallResult, reportFailed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.status == .ok ? "checkmark.circle.fill" : result.status == .cancelled ? "xmark.circle" : "exclamationmark.circle")
                .foregroundStyle(result.status == .ok ? CatpawBrand.paw : CatpawColors.secondary).accessibilityHidden(true)
            Text(receiptText(result.status)).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
            if result.status == .ok, let raw = result.openURL, let url = URL(string: raw) {
                Text("·").foregroundStyle(CatpawColors.tertiary).accessibilityHidden(true)
                Button(ui("打开")) { openURL(url) }.font(CatpawTypography.Role.body.font.weight(.medium)).foregroundStyle(CatpawColors.ink).underline()
                    .accessibilityIdentifier("chat.deviceCall.open")
            }
            Spacer(minLength: 0)
            if ledger.isUndone(callID: call.call_id) {
                Text(ui("已撤销")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.deviceCall.undone")
            } else if DeviceUndoRules.canUndo(tool: call.tool, status: result.status.rawValue, alreadyUndone: false), ledger.entry(callID: call.call_id) != nil {
                Button(ui("撤销")) { Task { await undo() } }.font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary).touchTarget()
                    .accessibilityLabel(ui("撤销")).accessibilityIdentifier("chat.deviceCall.undo")
            }
        }
        .frame(minHeight: 44).accessibilityElement(children: .contain).accessibilityIdentifier("chat.deviceCall.receipt")
        if undoFailed { Text(ui("没能撤销，请到日历或提醒事项里删除")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
        // The place card (server ui.block, kind:place) is the primary nearby view; this list is the fallback for an older server.
        if call.tool == "places_search", blockStore.blocks[NearbyRules.placeBlockID(callID: call.call_id)] == nil { placesList(result) }
        if reportFailed {
            HStack {
                Text(ui("结果还没告诉小猫")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)
                Button(ui("重试")) { Task { await store.retryReport(call.id) } }.font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink).touchTarget()
            }
        }
    }
    /// 附近 POI rows: name · ETA · distance, with 导航 / 打电话 per row, plus the honest Why (memories + origin).
    @ViewBuilder private func placesList(_ result: DeviceCallResult) -> some View {
        if case .array(let rows)? = result.data?["places"] {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if case .object(let p) = row {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p["name"]?.text ?? "").font(CatpawTypography.Role.body.font.weight(.medium)).foregroundStyle(CatpawColors.ink)
                                Text([p["eta_min"].map { "约 \($0.text) 分钟" }, p["distance_m"].map { "\($0.text) 米" }, p["address"]?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if let u = p["maps_url"]?.text, let url = URL(string: u) {
                                Button(ui("导航")) { openURL(url) }.font(CatpawTypography.Role.caption.font.weight(.medium)).foregroundStyle(CatpawColors.ink).touchTarget()
                                    .accessibilityIdentifier("chat.places.nav.\(i)")
                            }
                            if let t = p["tel_url"]?.text, let url = URL(string: t) {
                                Button(ui("打电话")) { openURL(url) }.font(CatpawTypography.Role.caption.font.weight(.medium)).foregroundStyle(CatpawColors.ink).touchTarget()
                                    .accessibilityIdentifier("chat.places.call.\(i)")
                            }
                        }
                    }
                }
                if let why = result.data?["why"]?.text, !why.isEmpty {
                    Text(why).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.places.why")
                }
            }
        } else if let message = result.data?["message"]?.text, result.status == .error {
            Text(message).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Chat-UX #6: delete by call_id (same ledger/EventKit path as 任务's 撤销), then queue the report for the turn (retried on launch/foreground until acknowledged).
    private func undo() async {
        let outcome = ledger.undo(callID: call.call_id)
        undoFailed = !outcome.removed
        await store.reportUndo(callID: call.call_id, outcome: outcome)
    }
    private func receiptText(_ status: DeviceCallStatus) -> String {
        switch status {
        case .ok: ui(spec.doneKey)
        case .cancelled: ui("已取消")
        case .denied: ui("没有权限，未执行")
        case .error: ui("没有完成，请稍后重试")
        }
    }
}

@MainActor struct DeviceCallEditSheet: View {
    let call: DeviceCall
    let spec: DeviceCallSpec
    let save: ([String: DeviceCallValue]) -> Void
    @State private var values: [String: DeviceCallValue]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    init(call: DeviceCall, spec: DeviceCallSpec, values: [String: DeviceCallValue], save: @escaping ([String: DeviceCallValue]) -> Void) {
        self.call = call; self.spec = spec; self.save = save; _values = State(initialValue: values)
    }
    var body: some View {
        NavigationStack {
            Form {
                ForEach(spec.fields.filter(\.editable), id: \.key) { field in
                    Section(ui(field.labelKey)) { editor(field) }
                }
            }
            .navigationTitle(ui(spec.titleKey)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { save(changes); dismiss() } }
            }
        }
    }
    private var changes: [String: DeviceCallValue] { values.filter { call.args[$0.key] != $0.value } }

    @ViewBuilder private func editor(_ field: DeviceCallSpec.Field) -> some View {
        switch field.kind {
        case .date:
            DatePicker(ui(field.labelKey), selection: Binding(
                get: { if case .string(let raw) = values[field.key], let d = DeviceCallDates.parse(raw) { d } else { Date() } },
                set: { values[field.key] = .string(DeviceCallDates.format($0)) }), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        default:
            TextField(ui(field.labelKey), text: Binding(
                get: { values[field.key]?.text ?? "" },
                set: { new in
                    if case .list = call.args[field.key] {
                        values[field.key] = .list(new.split(whereSeparator: { "、,，;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    } else { values[field.key] = .string(new) }
                }), axis: field.kind == .multiline ? .vertical : .horizontal)
                .font(CatpawTypography.Role.body.font)
                .keyboardType(field.kind == .phone ? .phonePad : .default)
                .lineLimit(field.kind == .multiline ? 3...8 : 1...1)
        }
    }
}

/// Registers `device_call` with `MarkdownCustomBlockRegistry` (#34) until 三角 surfaces the SSE event; the same view
/// renders the event later. Called from `CatpawMApp.init`.
@MainActor enum DeviceCallCardAdapter {
    private static var registered = false
    static func register() {
        guard !registered else { return }; registered = true
        MarkdownCustomBlockRegistry.shared.register(kind: "device_call") { payload, closed in
            if closed, let call = try? JSONDecoder().decode(DeviceCall.self, from: payload) { DeviceCallConfirmCard(call: call) } else { EmptyView() }
        }
    }
}

#Preview("本机能力确认卡") {
    ScrollView {
        VStack(spacing: 12) {
            DeviceCallConfirmCard(call: .init(call_id: "c1", tool: "calendar_create", args: ["title": .string("与张三开会"), "start": .string("2026-10-17T15:00:00+08:00"), "end": .string("2026-10-17T16:00:00+08:00"), "location": .string("望京 SOHO")], confirm: .card, ttl_sec: 600))
            DeviceCallConfirmCard(call: .init(call_id: "c2", tool: "sms_compose", args: ["to": .list(["13800000000"]), "body": .string("下午三点在望京 SOHO 见")], confirm: .card, ttl_sec: 600))
        }.padding()
    }
}
