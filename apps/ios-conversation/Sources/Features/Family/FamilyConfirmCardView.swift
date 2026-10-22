import SwiftUI

/// 确认卡: an extracted item that is NOT on the schedule yet. Confirm binds the exact item revision + proposal.
struct FamilyConfirmCardView: View {
    @ObservedObject var store: FamilyStore
    let item: FamilyPendingConfirmation
    @State private var editing = false
    @State private var title = ""
    @State private var bring = ""
    var body: some View {
        FamilyCard {
            HStack(alignment: .top, spacing: 12) {
                FamilyIconWell(symbol: item.source_kind == "notification_extract" ? "doc.text.image" : "calendar")
                VStack(alignment: .leading, spacing: 4) {
                    Text("建议安排").font(.footnote).foregroundStyle(catColors.secondary)
                    Text(item.title).font(.headline).foregroundStyle(catColors.ink)
                    Text(whenText).font(.subheadline).foregroundStyle(catColors.secondary)
                    if !item.bring.isEmpty { Text("带：" + item.bring.joined(separator: "、")).font(.footnote).foregroundStyle(catColors.secondary) }
                    FamilyStatusLine(kind: .pending).font(.footnote)
                }
            }
            if editing {
                TextField("标题", text: $title).textFieldStyle(.roundedBorder)
                TextField("要带的东西（用、分隔）", text: $bring).textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    FamilyPrimaryButton(title: "保存") { Task { await store.correct(item, title: title, bring: bring.split(whereSeparator: { "、,，".contains($0) }).map(String.init)); editing = false } }
                    FamilySecondaryButton(title: "取消") { editing = false }
                }
            } else {
                HStack(spacing: 12) {
                    FamilyPrimaryButton(title: "确认安排") { Task { await store.confirm(item) } }
                    FamilySecondaryButton(title: "改一下") { title = item.title; bring = item.bring.joined(separator: "、"); editing = true }
                }
                Button("不需要") { Task { await store.dismiss(item) } }.font(.footnote).foregroundStyle(catColors.secondary).frame(maxWidth: .infinity)
            }
        }
        .disabled(store.busyItem == item.item_id)
        .opacity(store.busyItem == item.item_id ? 0.6 : 1)
    }
    private var whenText: String {
        var parts: [String] = []
        parts.append(item.local_date ?? "日期待定")
        parts.append(item.local_time ?? "时间待定")
        if let c = item.child_display_name { parts.append(c) }
        if let pl = item.place { parts.append(pl) }
        return parts.joined(separator: " · ")
    }
}
