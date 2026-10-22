import SwiftUI

// MARK: choices

@MainActor struct GenerativeChoicesView: View {
    let block: GenerativeBlock
    let response: GenerativeBlockResponse?
    let locked: Bool
    let expired: Bool
    let respond: (GenerativeBlockResponse) -> Void
    let reopen: () -> Void
    @State private var selected: Set<String> = []
    @State private var otherOpen = false
    @State private var other = ""
    @State private var submitting = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var multiple: Bool { block.effectiveSelection == .multiple }
    private var autoSubmit: Bool { !multiple && (block.actions ?? []).isEmpty }
    private var canSubmit: Bool { !selected.isEmpty || !other.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let response {
                let labels = response.selected.compactMap { id in block.items?.first { $0.id == id }?.label } + [response.other].compactMap { $0 }.filter { !$0.isEmpty }
                GenerativeResolvedRow(text: ui("你选择了：{0}", [labels.joined(separator: "、")]), edit: locked || expired ? nil : reopen)
            } else {
                GenerativeBlockHeader(block: block)
                VStack(spacing: 6) {
                    ForEach(block.items ?? []) { item in row(item) }
                    if block.allowOther == true { otherRow }
                }
                if expired { GenerativeExpiredLabel() }
                else if !autoSubmit {
                    let actions = (block.actions ?? []).isEmpty ? [GenerativeBlock.Action(id: "submit", label: ui("提交"), style: .primary)] : (block.actions ?? [])
                    GenerativeActionRow(actions: actions, disabled: !canSubmit && actions.contains { $0.style == .primary }) { submit(action: $0.id) }
                }
            }
        }
        .disabled(expired || submitting)
    }

    private func row(_ item: GenerativeBlock.Item) -> some View {
        let on = selected.contains(item.id)
        return Button { toggle(item.id) } label: {
            HStack(spacing: 12) {
                if let icon = item.icon { Image(systemName: icon).foregroundStyle(catColors.ink).frame(width: 24).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                    if let detail = item.detail { Text(detail).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: multiple ? (on ? "checkmark.circle.fill" : "circle") : "checkmark")
                    .foregroundStyle(on ? catBrand.paw : catColors.tertiary).opacity(multiple || on ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(on ? catBrand.paw.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? catBrand.paw : catColors.ink.opacity(0.08), lineWidth: on ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("chat.block.item." + item.id)
    }

    @ViewBuilder private var otherRow: some View {
        if otherOpen {
            HStack {
                TextField(ui("其他…"), text: $other).textFieldStyle(.roundedBorder).submitLabel(.done)
                    .onSubmit { if autoSubmit, canSubmit { submit(action: nil) } }.accessibilityIdentifier("chat.block.other.field")
                if autoSubmit { Button(ui("提交")) { submit(action: nil) }.disabled(!canSubmit).touchTarget().accessibilityIdentifier("chat.block.other.submit") }
            }
        } else {
            Button { otherOpen = true; if !multiple { selected = [] } } label: {
                Label(ui("其他…"), systemImage: "ellipsis.circle").font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("chat.block.other")
        }
    }

    private func toggle(_ id: String) {
        if multiple { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }; return }
        selected = [id]; otherOpen = false; other = ""
        // Single + no actions: submit after showing the selection for 0.25 s.
        if autoSubmit { submitting = true; Task { try? await Task.sleep(nanoseconds: 250_000_000); submit(action: nil) } }
    }
    private func submit(action: String?) {
        let order = (block.items ?? []).map(\.id).filter(selected.contains)
        respond(GenerativeBlockResponse(blockId: block.id, actionId: action, selected: order, other: otherOpen ? other.trimmingCharacters(in: .whitespacesAndNewlines) : nil))
        submitting = false
    }
}

// MARK: confirm (HITL; same visual language as the #30 approval card)

@MainActor struct GenerativeConfirmView: View {
    let block: GenerativeBlock
    let response: GenerativeBlockResponse?
    let expired: Bool
    let respond: (GenerativeBlockResponse) -> Void
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var destructive: Bool { block.actions?.contains { $0.style == .destructive } == true }
    /// Model-supplied labels when given; otherwise 拒绝 / 批准. Action ids "approve"/"deny" by default.
    /// Contract: confirm answers always carry `actionId` ("approve"/"deny" or one of `actions[].id`).
    private var approve: GenerativeBlock.Action {
        block.actions?.first { $0.id == "approve" } ?? block.actions?.first { $0.style == .primary || $0.style == .destructive } ?? .init(id: "approve", label: ui("批准"), style: .primary)
    }
    private var deny: GenerativeBlock.Action {
        block.actions?.first { $0.id == "deny" } ?? block.actions?.first { $0.id != approve.id && ($0.style ?? .secondary) == .secondary } ?? .init(id: "deny", label: ui("拒绝"), style: .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let response {
                let approved = response.actionId == approve.id
                GenerativeResolvedRow(text: approved ? ui("已批准 · {0}", [generativeTime(response.respondedAt)]) : ui("已拒绝 · {0}", [generativeTime(response.respondedAt)]), icon: approved ? "checkmark.circle.fill" : "xmark.circle")
            } else {
                GenerativeBlockHeader(block: block, icon: "hand.raised")
                if expired { GenerativeExpiredLabel() }
                HStack(spacing: 10) {
                    Button { respond(.init(blockId: block.id, actionId: deny.id)) } label: { Text(deny.label).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered).tint(catColors.ink).accessibilityIdentifier("chat.block.confirm.deny")
                    Button { respond(.init(blockId: block.id, actionId: approve.id)) } label: { Text(approve.label).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).tint(destructive ? Color.red : catBrand.paw).accessibilityIdentifier("chat.block.confirm.approve")
                }
                .disabled(expired)
            }
        }
    }
}

// MARK: form

@MainActor struct GenerativeFormView: View {
    let block: GenerativeBlock
    let response: GenerativeBlockResponse?
    let expired: Bool
    let respond: (GenerativeBlockResponse) -> Void
    @State private var text: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var numbers: [String: Double] = [:]
    @State private var seeded = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var fields: [GenerativeBlock.Field] { block.fields ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if response != nil {
                GenerativeResolvedRow(text: ui("已提交"))
            } else {
                GenerativeBlockHeader(block: block)
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label + (field.required == true ? " *" : "")).font(catTypography.Role.caption.font).foregroundStyle(catColors.ink.opacity(0.55))
                        control(field)
                    }.accessibilityIdentifier("chat.block.field." + field.id)
                }
                if expired { GenerativeExpiredLabel() }
                let actions = (block.actions ?? []).isEmpty ? [GenerativeBlock.Action(id: "submit", label: ui("提交"), style: .primary)] : (block.actions ?? [])
                GenerativeActionRow(actions: actions, disabled: expired || !requiredFilled) { action in
                    respond(.init(blockId: block.id, actionId: action.id, values: values))
                }
            }
        }
        .onAppear(perform: seed)
    }

    @ViewBuilder private func control(_ f: GenerativeBlock.Field) -> some View {
        switch f.type {
        case .text: TextField(f.placeholder ?? "", text: bind(f.id)).textFieldStyle(.roundedBorder)
        case .multiline: TextField(f.placeholder ?? "", text: bind(f.id), axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
        case .number: TextField(f.placeholder ?? "", text: bind(f.id)).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
        case .toggle: Toggle(f.placeholder ?? f.label, isOn: Binding(get: { flags[f.id] ?? false }, set: { flags[f.id] = $0 })).labelsHidden()
        case .select:
            Picker(f.label, selection: bind(f.id)) {
                Text(f.placeholder ?? ui("请选择")).tag("")
                ForEach(f.options ?? [], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).tint(catColors.ink)
        case .stepper:
            Stepper(value: Binding(get: { numbers[f.id] ?? 0 }, set: { numbers[f.id] = $0 })) { Text(GenerativeValue.number(numbers[f.id] ?? 0).text).font(catTypography.Role.body.font) }
        case .date, .time, .datetime:
            DatePicker(f.label, selection: Binding(get: { dates[f.id] ?? .now }, set: { dates[f.id] = $0 }),
                       displayedComponents: f.type == .date ? [.date] : f.type == .time ? [.hourAndMinute] : [.date, .hourAndMinute])
                .datePickerStyle(.compact).labelsHidden()
        }
    }
    private func bind(_ id: String) -> Binding<String> { Binding(get: { text[id] ?? "" }, set: { text[id] = $0 }) }
    private func seed() {
        guard !seeded else { return }; seeded = true
        for f in fields { guard let d = f.default else { continue }
            switch (f.type, d) {
            case (.toggle, .bool(let b)): flags[f.id] = b
            case (.stepper, .number(let n)): numbers[f.id] = n
            case (.date, .string(let s)), (.time, .string(let s)), (.datetime, .string(let s)): if let date = Self.parse(s, f.type) { dates[f.id] = date }
            default: text[f.id] = d.text
            }
        }
    }
    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; return f.string(from: date)
    }
    private static func parse(_ text: String, _ type: GenerativeBlock.Field.FieldType) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        switch type {
        case .date: f.dateFormat = "yyyy-MM-dd"; return f.date(from: text)
        case .time:
            f.dateFormat = "HH:mm"; guard let t = f.date(from: text) else { return nil }
            let c = Calendar.current.dateComponents([.hour, .minute], from: t); return Calendar.current.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: .now)
        default: return ISO8601DateFormatter().date(from: text)
        }
    }
    private var requiredFilled: Bool {
        fields.filter { $0.required == true }.allSatisfy { f in
            switch f.type {
            case .toggle, .stepper, .date, .time, .datetime: true
            case .number: Double((text[f.id] ?? "").replacingOccurrences(of: ",", with: ".")) != nil
            default: !(text[f.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }
    private var values: [String: GenerativeValue] {
        var out: [String: GenerativeValue] = [:]
        for f in fields {
            switch f.type {
            case .toggle: out[f.id] = .bool(flags[f.id] ?? false)
            case .stepper: out[f.id] = .number((numbers[f.id] ?? 0).rounded())
            case .number: if let v = Double((text[f.id] ?? "").replacingOccurrences(of: ",", with: ".")) { out[f.id] = .number(v) }
            case .date: out[f.id] = .string(Self.format(dates[f.id] ?? .now, "yyyy-MM-dd"))
            case .time: out[f.id] = .string(Self.format(dates[f.id] ?? .now, "HH:mm"))
            case .datetime: out[f.id] = .string(ISO8601DateFormatter().string(from: dates[f.id] ?? .now))
            default: if let v = text[f.id], !v.isEmpty { out[f.id] = .string(v) }
            }
        }
        return out
    }
}

// MARK: card / list / progress

@MainActor struct GenerativeCardView: View {
    let block: GenerativeBlock
    let response: GenerativeBlockResponse?
    let expired: Bool
    let respond: (GenerativeBlockResponse) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = block.image {
                GenerativeRemoteImage(url: url)
                    .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
            }
            GenerativeBlockHeader(block: block)
            if expired, !(block.actions ?? []).isEmpty { GenerativeExpiredLabel() }
            if let response, let label = block.actions?.first(where: { $0.id == response.actionId })?.label {
                GenerativeResolvedRow(text: label + " · " + generativeTime(response.respondedAt))
            } else if let actions = block.actions, !actions.isEmpty {
                GenerativeActionRow(actions: actions, disabled: expired) { respond(.init(blockId: block.id, actionId: $0.id)) }
            }
        }
    }
}

@MainActor struct GenerativeListView: View {
    let block: GenerativeBlock
    let expired: Bool
    let respond: (GenerativeBlockResponse) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GenerativeBlockHeader(block: block)
            ForEach(block.items ?? []) { item in
                let tappable = !(block.actions ?? []).isEmpty && !expired
                Button { respond(.init(blockId: block.id, actionId: block.actions?.first?.id, selected: [item.id])) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon ?? "circle.fill").foregroundStyle(catColors.secondary).frame(width: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                            if let detail = item.detail { Text(detail).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary) }
                        }
                        Spacer()
                        if tappable { Image(systemName: "chevron.right").foregroundStyle(catColors.tertiary).accessibilityHidden(true) }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!tappable).accessibilityIdentifier("chat.block.item." + item.id)
            }
        }
    }
}

@MainActor struct GenerativeProgressView: View {
    let block: GenerativeBlock
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GenerativeBlockHeader(block: block)
            ForEach(block.steps ?? []) { step in
                HStack(spacing: 10) {
                    Group {
                        switch step.state {
                        case .running: ProgressView()
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(catBrand.paw)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(catColors.attention)
                        case .pending: Image(systemName: "circle").foregroundStyle(catColors.tertiary)
                        }
                    }.frame(width: 24).accessibilityHidden(true)
                    Text(step.label).font(catTypography.Role.body.font).foregroundStyle(step.state == .pending ? catColors.secondary : catColors.ink)
                }
                .frame(minHeight: 32)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.block.step." + step.id)
            }
        }
    }
}

// MARK: place / event (grounded: server-filled from tool results; deep links open locally)

@MainActor struct GenerativeDeepLinkButtons: View {
    let links: [GenerativeBlock.DeepLink]
    let idPrefix: String
    @Environment(\.openURL) private var openURL
    var body: some View {
        ForEach(links.filter(\.isAllowed)) { link in
            if let url = URL(string: link.url) {
                Button(link.label) { openURL(url) }
                    .font(catTypography.Role.caption.font.weight(.medium)).foregroundStyle(catColors.ink).touchTarget()
                    .accessibilityLabel(link.label).accessibilityIdentifier(idPrefix + link.id)
            }
        }
    }
}

@MainActor struct GenerativePlaceView: View {
    let block: GenerativeBlock
    static func detail(_ p: GenerativeBlock.Place) -> String {
        [p.etaMin.map { "约 \(Int($0)) 分钟" }, p.distanceM.map { $0 >= 1000 ? String(format: "%.1f 公里", $0 / 1000) : "\(Int($0)) 米" }, p.address]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GenerativeBlockHeader(block: block)
            ForEach(block.places ?? []) { p in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(catColors.secondary).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(catTypography.Role.body.font.weight(.medium)).foregroundStyle(catColors.ink)
                        Text(Self.detail(p)).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    GenerativeDeepLinkButtons(links: p.actions, idPrefix: "chat.place.\(p.id).")
                }
                .frame(minHeight: 44).accessibilityIdentifier("chat.place." + p.id)
            }
            if let caption = block.caption, !caption.isEmpty {
                Text(caption).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.places.why")
            }
        }
    }
}

@MainActor struct GenerativeEventView: View {
    let block: GenerativeBlock
    static func when(_ e: GenerativeBlock.Event) -> String {
        let iso = ISO8601DateFormatter()
        guard let start = iso.date(from: e.start) else { return e.start }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = e.allDay == true ? "M月d日 全天" : "M月d日 HH:mm"
        var out = f.string(from: start)
        if e.allDay != true, let raw = e.end, let end = iso.date(from: raw) { let t = DateFormatter(); t.dateFormat = "HH:mm"; out += "–" + t.string(from: end) }
        return out
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GenerativeBlockHeader(block: block)
            ForEach(block.events ?? []) { e in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(catColors.secondary).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title.isEmpty ? "（无标题）" : e.title).font(catTypography.Role.body.font.weight(.medium)).foregroundStyle(catColors.ink)
                        Text([Self.when(e), e.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    GenerativeDeepLinkButtons(links: e.actions, idPrefix: "chat.event.\(e.id).")
                }
                .frame(minHeight: 44).accessibilityIdentifier("chat.event." + e.id)
            }
        }
    }
}
