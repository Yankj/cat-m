import SwiftUI

struct AssistantView: View {
    @State private var input = ""
    @State private var messages: [String] = ["你好，我是猫伴。有什么需要我帮忙的？"]

    var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
                            Text(msg)
                                .padding(12)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
                HStack {
                    TextField("说点什么…", text: $input)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") {
                        guard !input.isEmpty else { return }
                        messages.append(input)
                        messages.append("（已记录，如需长期记住请到记忆页确认）")
                        input = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("对话")
        }
    }
}
