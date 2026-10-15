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
                if let icon = item.icon { Image(systemName: icon).foregroundStyle(CatpawColors.ink).frame(width: 24).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                    if let detail = item.detail { Text(detail).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: multiple ? (on ? "checkmark.circle.fill" : "circle") : "checkmark")
                    .foregroundStyle(on ? CatpawBrand.paw : CatpawColors.tertiary).opacity(multiple || on ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(on ? CatpawBrand.paw.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? CatpawBrand.paw : CatpawColors.ink.opacity(0.08), lineWidth: on ? 1 : 0.5))
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
                Label(ui("其他…"), systemImage: "ellipsis.circle").font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
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
    private var approve: GenerativeBlock.Action { block.actions?.first { $0.style == .primary || $0.style == .destructive } ?? .init(id: "approve", label: ui("批准"), style: .primary) }
    private var deny: GenerativeBlock.Action { block.actions?.first { ($0.style ?? .secondary) == .secondary } ?? .init(id: "deny", label: ui("拒绝"), style: .secondary) }

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
                        .buttonStyle(.bordered).tint(CatpawColors.ink).accessibilityIdentifier("chat.block.confirm.deny")
                    Button { respond(.init(blockId: block.id, actionId: approve.id)) } label: { Text(approve.label).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).tint(destructive ? Color.red : CatpawBrand.paw).accessibilityIdentifier("chat.block.confirm.approve")
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
                        Text(field.label + (field.required == true ? " *" : "")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink.opacity(0.55))
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
            }.pickerStyle(.menu).tint(CatpawColors.ink)
        case .stepper:
            Stepper(value: Binding(get: { numbers[f.id] ?? 0 }, set: { numbers[f.id] = $0 })) { Text(GenerativeValue.number(numbers[f.id] ?? 0).text).font(CatpawTypography.Role.body.font) }
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
            case (.date, .string(let s)), (.time, .string(let s)), (.datetime, .string(let s)): if let date = ISO8601DateFormatter().date(from: s) { dates[f.id] = date }
            default: text[f.id] = d.text
            }
        }
    }
    private var requiredFilled: Bool {
        fields.filter { $0.required == true }.allSatisfy { f in
            switch f.type { case .toggle, .stepper, .date, .time, .datetime: true; default: !(text[f.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }
    private var values: [String: GenerativeValue] {
        var out: [String: GenerativeValue] = [:]
        for f in fields {
            switch f.type {
            case .toggle: out[f.id] = .bool(flags[f.id] ?? false)
            case .stepper: out[f.id] = .number(numbers[f.id] ?? 0)
            case .number: if let v = Double(text[f.id] ?? "") { out[f.id] = .number(v) }
            case .date, .time, .datetime: out[f.id] = .string(ISO8601DateFormatter().string(from: dates[f.id] ?? .now))
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
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { CatpawColors.ink.opacity(0.05) }
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
                        Image(systemName: item.icon ?? "circle.fill").foregroundStyle(CatpawColors.secondary).frame(width: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                            if let detail = item.detail { Text(detail).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
                        }
                        Spacer()
                        if tappable { Image(systemName: "chevron.right").foregroundStyle(CatpawColors.tertiary).accessibilityHidden(true) }
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
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(CatpawBrand.paw)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(CatpawColors.attention)
                        case .pending: Image(systemName: "circle").foregroundStyle(CatpawColors.tertiary)
                        }
                    }.frame(width: 24).accessibilityHidden(true)
                    Text(step.label).font(CatpawTypography.Role.body.font).foregroundStyle(step.state == .pending ? CatpawColors.secondary : CatpawColors.ink)
                }
                .frame(minHeight: 32)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.block.step." + step.id)
            }
        }
    }
}
