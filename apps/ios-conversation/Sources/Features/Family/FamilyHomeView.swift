import SwiftUI

/// 我们家: household profile and what cat remembers. Every memory shows its source and can be corrected or deleted;
/// memory and reminders can be paused separately.
struct FamilyHomeView: View {
    @ObservedObject var store: FamilyStore
    @State private var editingMemory: FamilyMemory?
    @State private var memoryText = ""
    @State private var editingChild: FamilyChild?
    @State private var addingChild = false
    var body: some View {
        List {
            if let home = store.projection?.home {
                Section("孩子") {
                    ForEach(home.children) { c in
                        Button { editingChild = c } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.display_name).font(.headline).foregroundStyle(catColors.ink)
                                let meta = [c.school_label, c.class_label, c.teacher_label].compactMap { $0 }.joined(separator: " · ")
                                if !meta.isEmpty { Text(meta).font(.footnote).foregroundStyle(catColors.secondary) }
                            }
                        }
                        .swipeActions { Button("删除", role: .destructive) { Task { await store.deleteChild(c) } } }
                    }
                    Button { addingChild = true } label: { Label("添加孩子", systemImage: "plus") }
                }
                Section("cat 记得的事") {
                    if (home.memories ?? []).isEmpty { Text("还没有记住什么").foregroundStyle(catColors.secondary) }
                    ForEach(home.memories ?? []) { m in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.text).foregroundStyle(catColors.ink)
                            Text(sourceText(m)).font(.footnote).foregroundStyle(catColors.secondary)
                            HStack(spacing: 24) {
                                Button("更正") { memoryText = m.text; editingMemory = m }.foregroundStyle(catColors.actionText)
                                Button("删除", role: .destructive) { Task { await store.deleteMemory(m) } }
                            }
                            .buttonStyle(.borderless).font(.subheadline)
                        }
                    }
                }
                if let s = home.settings {
                    Section("边界") {
                        Toggle("暂停记忆", isOn: Binding(get: { s.memory_paused }, set: { v in Task { await store.setPaused(memory: v) } }))
                        Toggle("暂停提醒", isOn: Binding(get: { s.reminders_paused }, set: { v in Task { await store.setPaused(reminders: v) } }))
                        Text("提醒每天最多 2 条，21:00–08:00 不打扰。").font(.footnote).foregroundStyle(catColors.secondary)
                    }
                }
            } else { ProgressView() }
        }
        .scrollContentBackground(.hidden).background(catColors.calmPage.ignoresSafeArea())
        .navigationTitle(store.projection?.home.household?.name ?? "我们家")
        .task { if store.projection == nil { await store.load() } }
        .sheet(item: $editingMemory) { m in
            NavigationStack {
                Form { TextField("内容", text: $memoryText, axis: .vertical) }
                    .navigationTitle("更正").toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await store.correctMemory(m, text: memoryText); editingMemory = nil } } }
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editingMemory = nil } }
                    }
            }
        }
        .sheet(item: $editingChild) { c in FamilyChildEditor(store: store, child: c) }
        .sheet(isPresented: $addingChild) { FamilyChildEditor(store: store, child: nil) }
    }
    private func sourceText(_ m: FamilyMemory) -> String {
        switch m.source?.source_kind {
        case "user_text": return "你告诉我的"
        case "user_voice_transcript": return "你说的"
        case "notification_extract": return "来自通知"
        case "user_confirm": return "你确认过"
        default: return "来源未知"
        }
    }
}

struct FamilyChildEditor: View {
    @ObservedObject var store: FamilyStore
    let child: FamilyChild?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var school = ""; @State private var klass = ""; @State private var teacher = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("名字", text: $name); TextField("学校", text: $school); TextField("班级", text: $klass); TextField("老师", text: $teacher)
            }
            .navigationTitle(child == nil ? "添加孩子" : "编辑")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await store.saveChild(child, name: name, school: school.isEmpty ? nil : school, klass: klass.isEmpty ? nil : klass, teacher: teacher.isEmpty ? nil : teacher); dismiss() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear { name = child?.display_name ?? ""; school = child?.school_label ?? ""; klass = child?.class_label ?? ""; teacher = child?.teacher_label ?? "" }
        }
    }
}
