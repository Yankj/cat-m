import SwiftUI

struct MemoryView: View {
    @Environment(AppStore.self) private var store
    @State private var newMemory = ""
    @State private var selectedKind: MemoryItem.Kind = .profile

    var body: some View {
        NavigationStack {
            List {
                Section("添加记忆") {
                    TextField("记住……", text: $newMemory)
                    Picker("类型", selection: $selectedKind) {
                        ForEach(MemoryItem.Kind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button("记住") {
                        guard !newMemory.isEmpty else { return }
                        store.addMemory(newMemory, kind: selectedKind)
                        newMemory = ""
                    }
                    .disabled(newMemory.isEmpty)
                }

                Section("已记住") {
                    ForEach(store.memories) { memory in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memory.content)
                            HStack {
                                Text(memory.kind.rawValue)
                                Text("·")
                                Text(memory.source)
                                Spacer()
                                Text(memory.confidence, format: .percent.precision(.fractionLength(0)))
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.removeMemory(memory.id)
                            } label: {
                                Label("遗忘", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("记忆")
        }
    }
}
