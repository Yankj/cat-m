import SwiftUI

/// Hook rendered once below the transcript: approval cards for the turn awaiting approval, plus receipts.
@MainActor struct ConversationApprovalHost: View {
    @ObservedObject var model: ConversationFirstModel
    let session: ConversationSession
    @StateObject private var controller = ConversationApprovalController()
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var turn: ConversationTurnRecord? { session.turns.last }
    private var pending: [ConversationApprovalRequest] { turn?.awaitingApproval == true ? (turn?.pendingApprovals ?? []) : [] }
    /// catpaw.device.v1: the SSE `device_call` lands in `turn.pendingDeviceCalls`; render its confirm card here
    /// (previously only the markdown fallback block rendered one, so a real device call never showed a card).
    /// Calls stay listed after the server resolves them so the receipt row remains visible.
    @State private var deviceCalls: [DeviceCall] = []
    @ObservedObject private var deviceStore = DeviceCallStore.shared
    private var doneSummaries: [String] {
        deviceCalls.compactMap { call in
            guard case .done(let r) = deviceStore.phase(call.id), r.status == .ok else { return nil }
            return DeviceCallSummary.line(call, ui)
        }
    }
    private func syncDeviceCalls() {
        let live = (turn?.awaitingApproval == true ? (turn?.pendingDeviceCalls ?? []) : []).compactMap(DeviceCall.init)
        for call in live where !deviceCalls.contains(where: { $0.id == call.id }) { deviceCalls.append(call) }   // display only — grants come from the SSE boundary (DeviceCallGate.installLifecycle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !deviceCalls.isEmpty || !pending.isEmpty { Color.clear.frame(height: 0).id(StatusLineCardAnchor.id) }   // status-line tap target
            ForEach(deviceCalls, id: \.id) { call in DeviceCallConfirmCard(call: call) }
            // Server follow-up after device_result can fail (e.g. provider_timeout). Never leave a dangling turn:
            // state what happened on the phone and offer to continue (a follow-up, not a regenerate that would redo the action).
            if turn?.state == .failed, !doneSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(doneSummaries, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle.fill").font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                    }
                    HStack(spacing: 12) {
                        Text(ui("小猫的回复没有完成")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                        Button(ui("继续回复")) { model.draft = ui("继续"); model.send() }
                            .font(CatpawTypography.Role.caption.font.weight(.semibold)).accessibilityIdentifier("chat.deviceCall.followupRetry")
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("chat.deviceCall.finalLine")
            }
            ForEach(pending) { approval in
                ConversationApprovalCardView(approval: approval, working: controller.working.contains(approval.interruptID),
                                             error: controller.errors[approval.interruptID].map { ui($0) },
                                             decide: { controller.decide(approval, $0, model: model) })
            }
            ForEach(controller.outcomes.keys.sorted().filter { id in !pending.contains { $0.interruptID == id } }, id: \.self) { id in
                if let item = controller.outcomes[id] { receipt(item.tool, item.outcome).accessibilityIdentifier("chat.approval.resolved." + id) }
            }
        }
        .padding(.top, pending.isEmpty && controller.outcomes.isEmpty && deviceCalls.isEmpty ? 0 : 12)
        .onAppear { controller.observe(model, turn: turn); syncDeviceCalls() }
        .onChange(of: turn?.pendingDeviceCalls) { _, _ in syncDeviceCalls() }
        .onChange(of: turn?.state) { _, _ in syncDeviceCalls() }
        .onChange(of: turn?.id) { _, _ in controller.observe(model, turn: turn) }
        .onChange(of: turn?.pendingApprovals) { _, _ in controller.observe(model, turn: turn) }
    }

    private func receipt(_ tool: String, _ outcome: ConversationApprovalController.Outcome) -> some View {
        let name = ConversationApprovalCardView.toolTitle(tool, ui)
        let (text, icon): (String, String) = switch outcome {
        case .approved: (ui("已允许：{0}", [name]), "checkmark.circle.fill")
        case .denied: (ui("已拒绝：{0}", [name]), "xmark.circle")
        case .expired: (ui("确认已超时，未执行：{0}", [name]), "clock.badge.exclamationmark")
        case .cancelled: (ui("已取消，未执行：{0}", [name]), "xmark.circle")
        case .failed(let message): (ui(message), "info.circle")
        }
        return Label(text, systemImage: icon).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
    }
}

@MainActor struct ConversationApprovalCardView: View {
    let approval: ConversationApprovalRequest
    let working: Bool
    let error: String?
    let decide: (ConversationApprovalDecision) -> Void
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }

    static func toolTitle(_ tool: String, _ ui: (String, [String]) -> String) -> String {
        switch tool {
        case "create_task": ui("创建任务", [])
        case "update_task": ui("更新任务", [])
        case "create_reminder", "update_reminder": ui("设置提醒", [])
        case "create_calendar_event", "update_calendar_event": ui("修改日历", [])
        default: ui("执行操作", [])
        }
    }
    private var expires: Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: approval.expiresAt) ?? ISO8601DateFormatter().date(from: approval.expiresAt)
    }
    private var riskText: String {
        switch approval.risk { case "device_write": ui("将修改此设备上的数据"); case "external_write": ui("将修改外部服务中的数据"); default: ui("将修改你的 Catpaw 数据") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(CatpawBrand.paw).accessibilityHidden(true)
                Text(ui("需要你的确认")).font(CatpawTypography.Role.caption.font.weight(.semibold)).foregroundStyle(CatpawColors.secondary)
                Spacer()
                if let expires {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(expires > context.date ? ui("{0} 后过期", [expires.formatted(.relative(presentation: .numeric))]) : ui("已过期"))
                            .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }.accessibilityIdentifier("chat.approval.expiry")
                }
            }
            Text(Self.toolTitle(approval.tool, ui)).font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.ink)
            if !approval.summary.isEmpty {
                Text(approval.summary).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.approval.summary")
            }
            Text(riskText).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            HStack(spacing: 10) {
                Button { decide(.approve) } label: { Text(ui("允许")).frame(maxWidth: .infinity) }
                    .primaryAction().accessibilityIdentifier("chat.approval.approve")
                Button { decide(.deny) } label: { Text(ui("拒绝")).frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityIdentifier("chat.approval.deny")
            }
            .disabled(working)
            if approval.rememberAllowed {
                Button { decide(.approveAlways) } label: { Text(ui("始终允许此类操作")).frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(working).accessibilityIdentifier("chat.approval.approveAlways")
            }
            if working { ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("chat.approval.working") }
            if let error { Text(error).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.approval.error") }
        }
        .padding(14)
        .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.approval." + approval.interruptID)
    }
}

/// One-line, user-facing receipt for a finished device call: "已创建提醒：交周报 · 明天 9:00".
@MainActor enum DeviceCallSummary {
    static func line(_ call: DeviceCall, _ ui: (String, [String]) -> String) -> String {
        let a = call.args
        let title = a["title"]?.text ?? a["label"]?.text ?? ""
        let when = DeviceLedger.date(a["due"]?.text ?? a["start"]?.text ?? a["time"]?.text).map { relative($0, ui) } ?? ""
        let head: String = switch call.tool {
        case "reminder_create", "alarm_set": ui("已创建提醒：{0}", [title])
        case "calendar_create": ui("已加入日历：{0}", [title])
        case "sms_compose": ui("已打开短信", [])
        case "mail_compose": ui("已打开邮件", [])
        case "phone_call": ui("已发起呼叫", [])
        default: ui("已完成", [])
        }
        return when.isEmpty ? head : head + " · " + when
    }
    private static func relative(_ d: Date, _ ui: (String, [String]) -> String) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return ui("今天", []) + " " + time }
        if cal.isDateInTomorrow(d) { return ui("明天", []) + " " + time }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
