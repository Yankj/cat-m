import SwiftUI
import PDFKit

@MainActor struct DocumentView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let id: UUID; let version: Int
    @State private var data: Data?
    @State private var reference: DocumentReference?
    @State private var error: String?
    @State private var editing = false
    @State private var text = ""
    @State private var exportURL: URL?
    @State private var readout = false
    @State private var receiptError: String?
    @State private var voiceEditing = false
    @State private var voiceTarget: DocumentReference?
    @State private var voiceTurn: FrozenVoiceTurn?
    @State private var voiceAdapterID = "user_text_edit"
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Page {
            if let record = model.record(id), let document = record.document {
                Text(document.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                StatusLabel(text: ui("固定版本 v{0} · {1}", arguments: [String(describing: (version)), String(describing: (["fixture", "gateway_synthetic", "gateway_synthetic_chat"].contains(document.sourceKind) ? ui("模拟成果") : ui("本机文件")))])).accessibilityIdentifier("document.version")
                if document.currentVersion > version { Text(ui("已有 v{0}，当前继续显示固定旧版。", arguments: [String(describing: (document.currentVersion))])).font(.caption).foregroundStyle(.secondary) }
                if let reference { Text(model.snapshot.isViewed(scope: model.scope, reference: reference) ? ui("此版本已读") : ui("此版本尚未记录已读")).font(.caption).foregroundStyle(.secondary) }
                if let receiptError { Text(ui("已读回执未保存：{0}", arguments: [String(describing: (receiptError))])).font(.caption).foregroundStyle(.secondary) }
                if let error { EmptyState(title: ui("无法读取文件"), detail: error) }
                else if let data {
                    if editing { TextEditor(text: $text).frame(minHeight: 350).accessibilityLabel(ui("文档编辑器")).accessibilityIdentifier("document.editor") }
                    else if document.mimeType == "application/pdf" { PDFPreview(data: data).frame(minHeight: 550) }
                    else if document.mimeType.hasPrefix("image/") { LocalImage(data: data) }
                    else if document.mimeType == "text/csv" { CSVTable(text: String(data: data, encoding: .utf8) ?? "") }
                    else if let string = String(data: data, encoding: .utf8) { MarkdownReader(text: string) }
                    else { EmptyState(title: ui("该格式暂不支持预览"), detail: ui("可以通过系统分享导出原文件；不会当作可执行文本打开。")) }
                    if let reference {
                        DisclosureGroup(ui("文件校验信息")) { Text("SHA-256 \(reference.contentHash)").font(.caption).foregroundStyle(catColors.secondary).textSelection(.enabled) }
                            .font(.caption).foregroundStyle(catColors.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if textSize.isAccessibilitySize { readerActions(document, data: data) }
                        else {
                            HStack(alignment: .top, spacing: 12) { readerActions(document, data: data, group: 1) }
                            HStack(alignment: .top, spacing: 12) { readerActions(document, data: data, group: 2) }
                        }
                    }.buttonStyle(.plain)
                    if document.sourceKind == "gateway_synthetic" { Text(ui("这是服务成果的只读回流；修改与控制由服务端保存。")).font(.footnote).foregroundStyle(.secondary) }
                    DisclosureGroup(ui("历史版本")) {
                        ForEach(1...document.currentVersion, id: \.self) { v in NavigationLink(ui("版本 {0}", arguments: [String(describing: (v))]), value: AppRoute.document(id, v)).touchTarget() }
                    }
                    ForEach(document.ownerIDs.filter { model.record($0)?.conversation != nil }, id: \.self) { conversationID in NavigationLink(ui("继续这件事的对话"), value: AppRoute.conversation(conversationID)).touchTarget() }
                } else { ProgressView(ui("读取本机文件")) }
            } else { EmptyState(title: ui("文件不可用"), detail: ui("文件已删除或不属于当前数据分区。")) }
        }.navigationTitle(ui("阅读器")).compactNavigationTitle()
        .task(id: version) {
            let selectedScope = model.scope
            do {
                let result = try await model.service.readDocument(scope: selectedScope, id: id, version: version)
                try Task.checkCancellation()
                guard model.scope == selectedScope else { return }
                reference = result.0; data = result.1
                do { try await model.service.markDocumentOpened(scope: selectedScope, reference: result.0); await model.refresh() }
                catch { receiptError = error.localizedDescription }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawExport-\(id)-v\(version)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let title = model.record(id)?.title ?? "document"
                let url = directory.appendingPathComponent(URL(fileURLWithPath: title).lastPathComponent)
                try result.1.write(to: url, options: .atomic); exportURL = url
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $readout) { if let reference { ReadoutSheet(text: String(data: data ?? Data(), encoding: .utf8) ?? "", reference: reference, sourceKind: model.record(id)?.document?.sourceKind ?? "unknown").presentationDetents([.medium, .large]) } }
        .sheet(isPresented: $voiceEditing) {
            if let voiceTarget { let selectedScope = model.scope
                VoiceInputSheet(accept: { _ in }, acceptSubmission: { submission in
                    let frozen = FrozenVoiceTurn(scope: selectedScope, target: .document(voiceTarget), transcript: submission)
                    model.perform {
                        guard model.scope == selectedScope else { throw catError.scopeMismatch }
                        let original = try await model.service.readDocument(scope: selectedScope, id: voiceTarget.documentID, version: voiceTarget.version)
                        let draft = try await FixtureVoiceRevisionAdapter().draft(turn: frozen, original: String(data: original.1, encoding: .utf8) ?? "")
                        NativeVoiceController.shared.stopPlayback(); voiceTurn = frozen; voiceAdapterID = draft.adapterID; text = draft.text; editing = true
                    }
                })
            }
        }
        .onChange(of: model.record(id) == nil) { _, unavailable in if unavailable { NativeVoiceController.shared.stopPlayback() } }
    }
    @ViewBuilder private func readerActions(_ document: Document, data: Data, group: Int = 0) -> some View {
        if document.mimeType.hasPrefix("text/"), document.sourceKind != "gateway_synthetic" {
            if group != 2 { Button {
                if editing { model.perform { let ref = try await model.service.editDocument(scope: model.scope, id: id, expectedVersion: version, text: text, voiceTurn: voiceTurn, adapterID: voiceAdapterID); editing = false; voiceTurn = nil; model.path.append(.document(id, ref.version)) } }
                else { NativeVoiceController.shared.stopPlayback(); voiceTurn = nil; voiceAdapterID = "user_text_edit"; text = String(data: data, encoding: .utf8) ?? ""; editing = true }
            } label: { readerActionLabel(editing ? ui("保存新版本") : ui("修改草稿"), symbol: editing ? "checkmark" : "pencil") }
                .accessibilityIdentifier("document.edit")
            if !editing {
                Button { readout = true } label: { readerActionLabel(ui("朗读"), symbol: "speaker.wave.2") }
            }
            }
            if group != 1, !editing, let reference {
                Button { NativeVoiceController.shared.stopPlayback(); voiceTarget = reference; voiceEditing = true } label: { readerActionLabel(ui("口述改稿 · 模拟模型"), symbol: "waveform") }
            }
        }
        if group != 1, let exportURL { ShareLink(item: exportURL) { readerActionLabel(ui("分享"), symbol: "square.and.arrow.up") } }
    }
    private func readerActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.body.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12)
            .foregroundStyle(catColors.ink)
            .background(catColors.input, in: RoundedRectangle(cornerRadius: catLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
    }

}
@MainActor struct CSVTable: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    let text: String
    var body: some View {
        if let rows = try? CSVParser.parse(text) { StringTable(rows: rows) }
        else { Text(ui("CSV 格式错误，无法安全解析。")).foregroundStyle(.red) }
    }
}
@MainActor struct StringTable: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth = 145.0
    @State private var viewportWidth: CGFloat = 0
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow(alignment: .top) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(rowIndex == 0 ? .headline : .body)
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                .padding(12).frame(width: columnWidth(column), alignment: .leading)
                                .foregroundStyle(catColors.ink).textSelection(.enabled)
                                .accessibilityAddTraits(rowIndex == 0 ? .isHeader : [])
                        }
                    }
                    .background(rowIndex == 0 ? catColors.input : catColors.panel)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }.accessibilityLabel(ui("表格，可左右滚动查看所有列"))
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { viewportWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
                }
            }
    }
    private var columnCount: Int { rows.map(\.count).max() ?? 0 }
    private func columnWidth(_ column: Int) -> CGFloat {
        // Keep long source labels intact; all cells in a column share one scaled width.
        #if os(iOS)
        let font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        #else
        let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        #endif
        let measured = rows.map { row -> CGFloat in
            let value = column < row.count ? row[column] : ""
            return (value as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let desired = max(minimumColumnWidth, min(420, ceil(measured)) * (minimumColumnWidth / 145) + 24)
        // A complete rightmost column must fit the viewport at accessibility sizes.
        // Long labels wrap vertically; the Grid keeps every cell in that row aligned.
        return viewportWidth > 0 ? min(desired, viewportWidth) : desired
    }
}
@MainActor struct MarkdownReader: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    if block.hasPrefix("```mermaid") { FixtureDiagram() }
                    else { ScrollView(.horizontal) { Text(block.replacingOccurrences(of: "```", with: "")).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(16) }.background(catColors.panel, in: RoundedRectangle(cornerRadius: 12)) }
                } else if block.hasPrefix("|") {
                    let rows = block.split(separator: "\n").filter { !$0.contains("---") }.map { $0.split(separator: "|", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) } }
                    StringTable(rows: rows)
                } else if block.hasPrefix("# ") { Text(String(block.dropFirst(2))).font(.title.bold()).textSelection(.enabled) }
                else if block.hasPrefix("## ") { Text(String(block.dropFirst(3))).font(.title2.bold()).textSelection(.enabled) }
                else { Text(block).font(.body).lineSpacing(5).textSelection(.enabled) }
            }
        }
    }
    private var blocks: [String] {
        var result: [String] = [], code = "", inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode { result.append(code + "\n" + line); code = ""; inCode = false }
                else { inCode = true; code = line }
            } else if inCode { code += "\n" + line }
            else if line.hasPrefix("|"), let last = result.last, last.hasPrefix("|") { result[result.count - 1] += "\n" + line }
            else if !line.isEmpty { result.append(line) }
        }
        if !code.isEmpty { result.append(code) }; return result
    }
}
@MainActor struct FixtureDiagram: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui("固定流程图示例 · 不支持任意 Mermaid 渲染")).font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) { HStack { ForEach(["素材采集", "重点筛选", "感想共创", "内容检查", "成果审阅"], id: \.self) { step in Text(step).padding(12).overlay(RoundedRectangle(cornerRadius: 8).stroke(catColors.green)); if step != "成果审阅" { Image(systemName: "arrow.right") } } }.padding().scaleEffect(zoom, anchor: .topLeading).frame(width: 760 * zoom, height: 110 * zoom, alignment: .topLeading) }.frame(height: 170).onTapGesture(count: 2) { zoom = zoom == 1 ? 1.5 : 1 }
            HStack { Button(ui("放大")) { zoom = min(2, zoom + 0.25) }; Button(ui("缩小")) { zoom = max(0.5, zoom - 0.25) }; Button(ui("还原")) { zoom = 1 } }.buttonStyle(.bordered)
        }
    }
}
@MainActor struct LocalImage: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    var data: Data; @State private var zoom: CGFloat = 1
    var body: some View {
        VStack {
            ScrollView([.horizontal, .vertical]) {
                #if os(iOS)
                if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 320 * zoom) }
                #else
                if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 320 * zoom) }
                #endif
            }.frame(minHeight: 300).onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1 }
            Button(ui("缩放 {0}%", arguments: [String(describing: (Int(zoom * 100)))])) { zoom = zoom == 1 ? 2 : 1 }.touchTarget()
        }
    }
}
#if os(iOS)
@MainActor struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.document = PDFDocument(data: data); return v }
    func updateUIView(_ uiView: PDFView, context: Context) { }
}
#else
@MainActor struct PDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.document = PDFDocument(data: data); return v }
    func updateNSView(_ nsView: PDFView, context: Context) { }
}
#endif
