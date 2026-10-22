import SwiftUI

/// 今天: the child's day as a schedule. Only server-confirmed items appear as 日程;
/// extracted items wait as confirm cards above it.
struct FamilyTodayView: View {
    @ObservedObject var store: FamilyStore
    @State private var showCapture = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let p = store.projection {
                    ForEach(p.today.pending_confirmations) { item in FamilyConfirmCardView(store: store, item: item) }
                    scheduleSection(p)
                    if !p.today.reminders.isEmpty { remindersSection(p.today.reminders) }
                } else if store.phase == .unavailable {
                    FamilyCard { Text("家庭功能还没有开放").font(.body).foregroundStyle(catColors.secondary) }
                } else if case .failed(let msg) = store.phase {
                    FamilyCard { Text(msg).foregroundStyle(catColors.secondary); FamilySecondaryButton(title: "重试") { Task { await store.load() } } }
                } else { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(catColors.calmPage.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { captureBar }
        .sheet(isPresented: $showCapture) { FamilyCaptureView(store: store) }
        .task { await store.load() }
        .refreshable { await store.load(date: store.projection?.local_date) }
        .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) { Button("好") {} }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("今天").font(.largeTitle.bold()).foregroundStyle(catColors.ink)
            if let p = store.projection { Text(p.local_date).font(.subheadline).foregroundStyle(catColors.secondary) }
        }
    }
    @ViewBuilder private func scheduleSection(_ p: FamilyProjection) -> some View {
        if p.today.schedule.isEmpty {
            FamilyCard {
                Text("还没有安排，也没关系").font(.headline).foregroundStyle(catColors.ink)
                Text("从今天想说的一件小事开始。").font(.subheadline).foregroundStyle(catColors.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(p.today.schedule) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Text(e.local_time ?? "全天").font(.subheadline.monospacedDigit()).foregroundStyle(catColors.secondary).frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.title).font(.body.weight(.semibold)).foregroundStyle(catColors.ink)
                            let meta = [e.child_display_name, e.place].compactMap { $0 }.joined(separator: " · ")
                            if !meta.isEmpty { Text(meta).font(.footnote).foregroundStyle(catColors.secondary) }
                            if !e.bring.isEmpty { Label("带：" + e.bring.joined(separator: "、"), systemImage: "bag").font(.footnote).foregroundStyle(catColors.actionText) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12).accessibilityElement(children: .combine)
                    if e.id != p.today.schedule.last?.id { Divider().overlay(catColors.separator) }
                }
            }
            .padding(.horizontal, 16).background(RoundedRectangle(cornerRadius: FamilyWarm.corner, style: .continuous).fill(catColors.card))
        }
    }
    private func remindersSection(_ rs: [FamilyReminder]) -> some View {
        FamilyCard {
            Label("提醒", systemImage: "bell").font(.headline).foregroundStyle(catColors.ink)
            ForEach(rs) { r in Text(r.why_now).font(.subheadline).foregroundStyle(catColors.secondary) }
        }
    }
    private var captureBar: some View {
        Button { showCapture = true } label: {
            HStack { Text("和 cat 说说今天的事").foregroundStyle(catColors.secondary); Spacer(); Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(catColors.send) }
                .padding(.horizontal, 16).frame(minHeight: 52).background(Capsule().fill(catColors.card)).overlay(Capsule().stroke(catColors.hairline))
        }
        .padding(.horizontal, 16).padding(.bottom, 8).accessibilityLabel("记一件事")
    }
}
