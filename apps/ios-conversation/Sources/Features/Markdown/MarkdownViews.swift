import SwiftUI
import UIKit
import SafariServices

// MARK: Theme (r10 §3 rich-render; r9 tokens from Components.swift)

enum MarkdownTheme {
    static var ink: Color { CatpawColors.ink }
    static let pawOrange = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xF0A27E) : UIColor(rgb: 0xE8916A) })
    static let codeBackground = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1E1C1B) : UIColor(rgb: 0xF6F4F2) })
    static let keyword = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xF08A62) : UIColor(rgb: 0xC0522D) })
    static let string = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x7CC08C) : UIColor(rgb: 0x3C7A4A) })
    static let number = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xB596E6) : UIColor(rgb: 0x8155BA) })
    static let typeName = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x8FB8E8) : UIColor(rgb: 0x3A6A9A) })
    static let paragraphSpacing: CGFloat = 12
    static let lineSpacing: CGFloat = 6
    static let codeCollapseLines = 24
    static let tableCollapseRows = 6

    static func color(_ token: MarkdownSyntaxToken) -> Color {
        switch token {
        case .keyword: keyword
        case .string: string
        case .number, .literal: number
        case .comment: ink.opacity(0.45)
        case .type: typeName
        }
    }
}

// MARK: Inline

@MainActor enum MarkdownInlineRenderer {
    private static var cache: [String: AttributedString] = [:]

    /// Inline Markdown → AttributedString. Streaming text hides dangling markers first.
    static func render(_ text: String, streaming: Bool) -> AttributedString {
        let source = streaming ? MarkdownInlineSanitizer.closeDangling(text) : text
        if !streaming, let hit = cache[source] { return hit }
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                result[run.range].font = SwiftUI.Font.system(.subheadline, design: .monospaced)
                result[run.range].backgroundColor = MarkdownTheme.ink.opacity(0.06)
            }
            if run.link != nil {
                // Color rule: paw orange is fill/icon only; link text stays ink, marked by underline.
                result[run.range].foregroundColor = MarkdownTheme.ink
                result[run.range].underlineStyle = .single
            }
        }
        if !streaming {
            if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
            cache[source] = result
        }
        return result
    }
}

@MainActor enum MarkdownLinkOpener {
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .systemAction }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else { return .systemAction }
        while let presented = top.presentedViewController { top = presented }
        top.present(SFSafariViewController(url: url), animated: true)
        return .handled
    }
}

// MARK: Generative UI extension point

/// Renders a `.custom(kind:payload:)` block (```catpaw-card fences today; `render_ui` blocks later).
@MainActor protocol MarkdownCustomBlockRenderer {
    func makeView(payload: Data, closed: Bool) -> AnyView
}

@MainActor final class MarkdownCustomBlockRegistry {
    static let shared = MarkdownCustomBlockRegistry()
    private var renderers: [String: any MarkdownCustomBlockRenderer] = [:]

    func register(kind: String, renderer: any MarkdownCustomBlockRenderer) { renderers[kind] = renderer }
    func register<Content: View>(kind: String, @ViewBuilder _ build: @escaping @MainActor (Data, Bool) -> Content) {
        renderers[kind] = ClosureRenderer { payload, closed in AnyView(build(payload, closed)) }
    }
    func unregister(kind: String) { renderers[kind] = nil }
    func renderer(for kind: String) -> (any MarkdownCustomBlockRenderer)? { renderers[kind] }

    private struct ClosureRenderer: MarkdownCustomBlockRenderer {
        let build: @MainActor (Data, Bool) -> AnyView
        func makeView(payload: Data, closed: Bool) -> AnyView { build(payload, closed) }
    }
}

// MARK: Document

/// Streaming-safe Markdown body for assistant messages. Completed blocks are equatable by
/// (id, content hash) so appends never re-render or re-layout them.
@MainActor struct MarkdownMessageView: View {
    let text: String
    let complete: Bool
    @State private var parser = MarkdownIncrementalParser()

    var body: some View {
        let blocks = parser.update(text, complete: complete)
        VStack(alignment: .leading, spacing: MarkdownTheme.paragraphSpacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, streaming: !block.isComplete).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(MarkdownTheme.ink)
        .environment(\.openURL, OpenURLAction { MarkdownLinkOpener.open($0) })
        .transaction { $0.animation = nil }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let streaming: Bool
    var inkOpacity: Double = 1
    @ScaledMetric(relativeTo: .body) private var listIndent: CGFloat = 20

    static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.block.id == rhs.block.id && lhs.block.contentHash == rhs.block.contentHash
            && lhs.streaming == rhs.streaming && lhs.inkOpacity == rhs.inkOpacity
    }

    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            Text(MarkdownInlineRenderer.render(text, streaming: streaming))
                .font((level == 1 ? Font.title2 : level == 2 ? Font.title3 : Font.body).weight(.semibold))
                .foregroundStyle(MarkdownTheme.ink.opacity(inkOpacity))
                .padding(.top, level == 1 ? 8 : level == 2 ? 4 : 0)
                .fixedSize(horizontal: false, vertical: true)
                .catpawTextSelection()
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            paragraph(text)
        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item)
                        Text(MarkdownInlineRenderer.render(item.text, streaming: streaming))
                            .font(.body).lineSpacing(MarkdownTheme.lineSpacing)
                            .foregroundStyle(MarkdownTheme.ink.opacity(inkOpacity))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.depth) * listIndent)
                }
            }.catpawTextSelection()
        case let .quote(children):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(MarkdownTheme.ink.opacity(0.15)).frame(width: 3)
                VStack(alignment: .leading, spacing: MarkdownTheme.paragraphSpacing) {
                    ForEach(children) { child in
                        MarkdownBlockView(block: child, streaming: streaming && !child.isComplete, inkOpacity: 0.7)
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
        case let .code(language, code, closed):
            MarkdownCodeBlockView(language: language, code: code, closed: closed)
        case let .table(table):
            MarkdownTableView(table: table, streaming: streaming)
        case .rule:
            Rectangle().fill(MarkdownTheme.ink.opacity(0.12)).frame(height: 0.5).padding(.vertical, 4)
        case let .custom(kind, payload, closed):
            if let renderer = MarkdownCustomBlockRegistry.shared.renderer(for: kind) {
                renderer.makeView(payload: payload, closed: closed)
            } else {
                MarkdownCardPlaceholder(kind: kind, closed: closed)
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(MarkdownInlineRenderer.render(text, streaming: streaming))
            .font(.body).lineSpacing(MarkdownTheme.lineSpacing)
            .foregroundStyle(MarkdownTheme.ink.opacity(inkOpacity))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .catpawTextSelection()
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square" : "square").font(.body)
                .foregroundStyle(MarkdownTheme.ink.opacity(0.55)).accessibilityLabel(checked ? "☑" : "☐")
        } else if item.ordered {
            Text(verbatim: "\(item.number).").font(.body).monospacedDigit()
                .foregroundStyle(MarkdownTheme.ink.opacity(0.55))
        } else {
            Image(systemName: "circle.fill").font(.footnote).imageScale(.small).scaleEffect(0.6)
                .foregroundStyle(MarkdownTheme.ink.opacity(0.55)).accessibilityHidden(true)
        }
    }
}

// MARK: Code block

@MainActor enum MarkdownCodeHighlighter {
    private static var lineCache: [String: [MarkdownSyntaxSpan]] = [:]

    static func attributed(_ code: String, language: String) -> AttributedString {
        let hasGrammar = MarkdownSyntaxHighlighter.grammar(for: language) != nil
        var out = AttributedString()
        let lines = code.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append(AttributedString("\n")) }
            guard hasGrammar, !line.isEmpty else { out.append(AttributedString(line)); continue }
            let key = language + "\u{1}" + line
            let spans: [MarkdownSyntaxSpan]
            if let hit = lineCache[key] { spans = hit } else {
                spans = MarkdownSyntaxHighlighter.spans(line: line, language: language)
                if lineCache.count > 4096 { lineCache.removeAll(keepingCapacity: true) }
                lineCache[key] = spans
            }
            let ns = line as NSString
            var cursor = 0
            for span in spans {
                if span.range.location > cursor {
                    out.append(AttributedString(ns.substring(with: NSRange(location: cursor, length: span.range.location - cursor))))
                }
                var piece = AttributedString(ns.substring(with: span.range))
                piece.foregroundColor = MarkdownTheme.color(span.token)
                out.append(piece)
                cursor = span.range.location + span.range.length
            }
            if cursor < ns.length { out.append(AttributedString(ns.substring(from: cursor))) }
        }
        return out
    }
}

@MainActor struct MarkdownCodeBlockView: View {
    let language: String
    let code: String
    let closed: Bool
    @State private var expanded = false
    @State private var copied = false
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 14
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: locale).ui(key, arguments: arguments) }

    var body: some View {
        let lines = code.components(separatedBy: "\n")
        let collapsed = !expanded && lines.count > MarkdownTheme.codeCollapseLines
        let shown = collapsed ? lines.prefix(MarkdownTheme.codeCollapseLines).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: language.isEmpty ? ui("代码") : language)
                    .font(.footnote).foregroundStyle(MarkdownTheme.ink.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? ui("已复制") : ui("复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote).labelStyle(.titleAndIcon)
                        .frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(MarkdownTheme.ink.opacity(0.55))
                .accessibilityLabel(ui("复制代码"))
                .accessibilityIdentifier("chat.markdown.code.copy")
            }
            .padding(.horizontal, 12).frame(height: 32)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(MarkdownCodeHighlighter.attributed(shown, language: language))
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(codeSize * 0.4)
                    .foregroundStyle(MarkdownTheme.ink)
                    .fixedSize(horizontal: true, vertical: true)
                    .catpawTextSelection()
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            if lines.count > MarkdownTheme.codeCollapseLines {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? ui("收起") : ui("展开全部 ({0} 行)", arguments: [String(lines.count)]))
                        .font(.footnote).foregroundStyle(MarkdownTheme.ink.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .overlay(alignment: .top) { Rectangle().fill(CatpawColors.hairline).frame(height: 0.5) }
            }
        }
        .background(MarkdownTheme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func copy() {
        UIPasteboard.general.string = code
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

// MARK: Table

@MainActor struct MarkdownTableView: View {
    let table: MarkdownTable
    let streaming: Bool
    @State private var expanded = false
    @Environment(\.locale) private var locale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: locale).ui(key, arguments: arguments) }

    var body: some View {
        let columns = max(1, table.columnCount)
        let collapsed = !expanded && table.rows.count > MarkdownTheme.tableCollapseRows
        let rows = collapsed ? Array(table.rows.prefix(MarkdownTheme.tableCollapseRows)) : table.rows
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(c < table.header.count ? table.header[c] : "", column: c)
                                .fontWeight(.semibold)
                                .background(MarkdownTheme.ink.opacity(0.04))
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Rectangle().fill(CatpawColors.hairline).frame(height: 0.5)
                        GridRow {
                            ForEach(0..<columns, id: \.self) { c in
                                cell(c < row.count ? row[c] : "", column: c)
                            }
                        }
                    }
                }
            }
            if table.rows.count > MarkdownTheme.tableCollapseRows {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? ui("收起") : ui("展开全部 ({0} 行)", arguments: [String(table.rows.count)]))
                        .font(.footnote).foregroundStyle(MarkdownTheme.ink.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .overlay(alignment: .top) { Rectangle().fill(CatpawColors.hairline).frame(height: 0.5) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment
        switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: alignment = .leading
        case .center: alignment = .center
        case .trailing: alignment = .trailing
        }
        return Text(MarkdownInlineRenderer.render(text, streaming: streaming))
            .font(.subheadline)
            .foregroundStyle(MarkdownTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 44, maxWidth: 280, alignment: alignment)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .catpawTextSelection()
    }
}

// MARK: Card fallback

@MainActor struct MarkdownCardPlaceholder: View {
    let kind: String
    let closed: Bool
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        HStack(spacing: 10) {
            if closed {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(MarkdownTheme.ink.opacity(0.55))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(closed ? ui("卡片") : ui("卡片加载中…")).font(.subheadline).foregroundStyle(MarkdownTheme.ink.opacity(0.7))
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(CatpawColors.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.markdown.card." + kind)
    }
}
