import Foundation

/// Streaming-safe Markdown block model for assistant replies.
///
/// Identity rules (what keeps earlier blocks from re-laying out while text streams in):
/// - `id` is `"<ordinal>:<kind tag>"`. Earlier content never changes during an append-only
///   stream, so every completed block keeps the same id, and the open tail block keeps its id
///   while it grows (an unclosed ``` fence is already `.code` and stays `.code` when it closes).
/// - `contentHash` covers the block's source; views compare it to skip re-rendering.
struct MarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case quote([MarkdownBlock])
        case code(language: String, code: String, closed: Bool)
        case table(MarkdownTable)
        case rule
        /// Generative UI extension point. `payload` is the raw fence body (JSON for `catpaw-card`).
        case custom(kind: String, payload: Data, closed: Bool)

        var tag: String {
            switch self {
            case .heading: "h"
            case .paragraph: "p"
            case .list: "l"
            case .quote: "q"
            case .code: "c"
            case .table: "t"
            case .rule: "r"
            case .custom: "x"
            }
        }
    }
    let id: String
    let kind: Kind
    /// Raw markdown source of this block (used for hashing and copy).
    let source: String
    /// Whether text after this block exists (or the document is complete). Completed blocks are immutable.
    let isComplete: Bool
    /// First source line of this block within the whole document.
    let startLine: Int
    var contentHash: Int { MarkdownBlock.stableHash(source) &+ (isComplete ? 1 : 0) }

    static func stableHash(_ s: String) -> Int {
        // FNV-1a over UTF-8: deterministic across launches (unlike Hasher).
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }
}

struct MarkdownListItem: Equatable, Sendable {
    /// Nesting depth derived from leading indentation (0 = top level).
    let depth: Int
    let ordered: Bool
    let number: Int
    let text: String
    /// GitHub task list state, nil when not a task item.
    let checked: Bool?
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }
    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]
    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
}

/// Line-based block parser. Pure Foundation so it is unit-testable off the main actor.
enum MarkdownBlockParser {
    static let cardLanguage = "catpaw-card"

    static func parse(_ text: String, complete: Bool) -> [MarkdownBlock] {
        parse(lines: splitLines(text), complete: complete, ordinalOffset: 0, lineOffset: 0)
    }

    /// Parses `lines`; block ordinals start at `ordinalOffset` and `startLine` is reported relative to the
    /// whole document (`lineOffset`), which lets the incremental parser resume mid-document.
    static func parse(lines: [String], complete: Bool, ordinalOffset: Int, lineOffset: Int) -> [MarkdownBlock] {
        var raw: [(Kind: MarkdownBlock.Kind, lines: Range<Int>)] = []
        parseLines(lines, into: &raw, streaming: !complete)
        return raw.enumerated().map { index, item in
            let source = lines[item.lines].joined(separator: "\n")
            let done = complete || index < raw.count - 1
            return MarkdownBlock(id: "\(index + ordinalOffset):\(item.Kind.tag)", kind: item.Kind, source: source,
                                 isComplete: done, startLine: item.lines.lowerBound + lineOffset)
        }
    }

    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    // MARK: Line classification

    static func fenceOpen(_ line: String) -> (marker: String, info: String)? {
        let t = line.drop(while: { $0 == " " })
        guard line.count - t.count <= 3, let first = t.first, first == "`" || first == "~" else { return nil }
        let marker = t.prefix(while: { $0 == first })
        guard marker.count >= 3 else { return nil }
        let info = t.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return (String(marker), info)
    }
    static func isFenceClose(_ line: String, marker: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = marker.first, t.count >= marker.count else { return false }
        return t.allSatisfy { $0 == c }
    }
    static func heading(_ line: String) -> (Int, String)? {
        let t = line.drop(while: { $0 == " " })
        guard line.count - t.count <= 3 else { return nil }
        let hashes = t.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = t.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var body = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes.
        while body.hasSuffix("#") { body.removeLast() }
        return (hashes.count, body.trimmingCharacters(in: .whitespaces))
    }
    static func isRule(_ line: String) -> Bool {
        let t = line.replacingOccurrences(of: " ", with: "")
        guard t.count >= 3, let c = t.first, "-*_".contains(c) else { return false }
        return t.allSatisfy { $0 == c }
    }
    static func isQuote(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " })
        return line.count - t.count <= 3 && t.first == ">"
    }
    static func stripQuote(_ line: String) -> String {
        var t = Substring(line.drop(while: { $0 == " " }))
        if t.first == ">" { t = t.dropFirst() }
        if t.first == " " { t = t.dropFirst() }
        return String(t)
    }
    /// Returns (indent columns, ordered, number, content) for a list item line.
    static func listItem(_ line: String, allowEmpty: Bool) -> (Int, Bool, Int, String)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 : 1
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        guard let first = rest.first else { return nil }
        var markerEnd: String.Index
        var ordered = false
        var number = 0
        if "-*+".contains(first) {
            markerEnd = rest.index(after: rest.startIndex)
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count <= 9 else { return nil }
            let after = rest.index(rest.startIndex, offsetBy: digits.count)
            guard after < rest.endIndex, rest[after] == "." || rest[after] == ")" else { return nil }
            markerEnd = rest.index(after: after)
            ordered = true
            number = Int(digits) ?? 1
        } else { return nil }
        // A lone "*" may be the start of "**bold**", so only "-", "+" and "1." count as empty items.
        if markerEnd == rest.endIndex { return allowEmpty && first != "*" ? (indent, ordered, number, "") : nil }
        guard rest[markerEnd] == " " || rest[markerEnd] == "\t" else { return nil }
        let content = rest[markerEnd...].trimmingCharacters(in: .whitespaces)
        return (indent, ordered, number, content)
    }
    static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }
    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }
    static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for ch in t {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func startsBlock(_ line: String, isLast: Bool, streaming: Bool) -> Bool {
        fenceOpen(line) != nil || heading(line) != nil || isQuote(line) || isRule(line) || isTableLine(line)
            || listItem(line, allowEmpty: streaming && isLast) != nil
    }

    // MARK: Block assembly

    private static func parseLines(_ lines: [String], into out: inout [(Kind: MarkdownBlock.Kind, lines: Range<Int>)], streaming: Bool) {
        var i = 0
        let n = lines.count
        while i < n {
            let line = lines[i]
            let isLast = i == n - 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }

            if let fence = fenceOpen(line) {
                var j = i + 1
                var closed = false
                while j < n {
                    if isFenceClose(lines[j], marker: fence.marker) { closed = true; break }
                    j += 1
                }
                let bodyEnd = j
                let body = lines[(i + 1)..<bodyEnd].joined(separator: "\n")
                let end = closed ? j + 1 : n
                let info = fence.info
                let language = String(info.split(separator: " ").first ?? "")
                if language.lowercased() == cardLanguage || language.lowercased().hasPrefix(cardLanguage + ":") {
                    out.append((.custom(kind: cardKind(language: language, body: body, closed: closed), payload: Data(body.utf8), closed: closed), i..<end))
                } else {
                    // A closing fence that is still partially typed (e.g. "``") must not leak into code.
                    var code = body
                    if !closed, let lastLine = lines[(i + 1)..<bodyEnd].last, !lastLine.isEmpty,
                       lastLine.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.marker.first }) {
                        code = lines[(i + 1)..<(bodyEnd - 1)].joined(separator: "\n")
                    }
                    out.append((.code(language: language, code: code, closed: closed), i..<end))
                }
                i = end
                continue
            }
            if let (level, text) = heading(line) {
                out.append((.heading(level: level, text: text), i..<(i + 1)))
                i += 1
                continue
            }
            if isRule(line) {
                out.append((.rule, i..<(i + 1)))
                i += 1
                continue
            }
            if isQuote(line) {
                var j = i
                var inner: [String] = []
                while j < n {
                    let l = lines[j]
                    if isQuote(l) { inner.append(stripQuote(l)); j += 1; continue }
                    // Lazy continuation: a non-blank paragraph line directly after a quote line.
                    if !l.trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(l, isLast: j == n - 1, streaming: streaming),
                       let prev = inner.last, !prev.trimmingCharacters(in: .whitespaces).isEmpty {
                        inner.append(l); j += 1; continue
                    }
                    break
                }
                let children = parse(inner.joined(separator: "\n"), complete: !(streaming && j == n))
                out.append((.quote(children), i..<j))
                i = j
                continue
            }
            if isTableLine(line) {
                var j = i
                while j < n, isTableLine(lines[j]) { j += 1 }
                out.append((.table(table(Array(lines[i..<j]))), i..<j))
                i = j
                continue
            }
            if let first = listItem(line, allowEmpty: streaming && isLast) {
                var items: [MarkdownListItem] = []
                var indents: [Int] = []
                func depth(for indent: Int) -> Int {
                    while let last = indents.last, indent < last { indents.removeLast() }
                    if let last = indents.last, indent == last { return indents.count - 1 }
                    if indents.isEmpty || indent > indents.last! { indents.append(indent) }
                    return indents.count - 1
                }
                var j = i
                var pending = first
                var pendingText = first.3
                func flush() {
                    let (indent, ordered, number, _) = pending
                    var text = pendingText
                    var checked: Bool?
                    if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { checked = true; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    items.append(MarkdownListItem(depth: depth(for: indent), ordered: ordered, number: number, text: text, checked: checked))
                }
                j += 1
                var lastContent = j
                while j < n {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line continues the list only if the next non-blank line is an item or indented.
                        var k = j + 1
                        while k < n, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                        if k < n, let next = listItem(lines[k], allowEmpty: streaming && k == n - 1) {
                            if next.0 <= first.0 && next.1 != first.1 { break }
                            j = k; continue
                        }
                        if k < n, lines[k].hasPrefix("  ") { j = k; continue }
                        break
                    }
                    if isRule(l) { break }
                    if let next = listItem(l, allowEmpty: streaming && j == n - 1) {
                        if next.0 <= first.0 && next.1 != first.1 { break }
                        flush(); pending = next; pendingText = next.3; j += 1; lastContent = j; continue
                    }
                    if fenceOpen(l) != nil || heading(l) != nil || isQuote(l) || isTableLine(l) || isRule(l) { break }
                    // Continuation line of the current item.
                    pendingText += " " + l.trimmingCharacters(in: .whitespaces)
                    j += 1; lastContent = j
                }
                flush()
                out.append((.list(items), i..<lastContent))
                i = lastContent
                continue
            }
            // Paragraph: until blank or another block start.
            var j = i + 1
            var parts = [line.trimmingCharacters(in: .whitespaces)]
            while j < n {
                let l = lines[j]
                if l.trimmingCharacters(in: .whitespaces).isEmpty || startsBlock(l, isLast: j == n - 1, streaming: streaming) { break }
                parts.append(l.trimmingCharacters(in: .whitespaces))
                j += 1
            }
            out.append((.paragraph(parts.joined(separator: "\n")), i..<j))
            i = j
        }
    }

    static func table(_ lines: [String]) -> MarkdownTable {
        let header = tableCells(lines[0])
        var alignments = Array(repeating: MarkdownTable.Alignment.leading, count: header.count)
        var bodyStart = 1
        if lines.count > 1, isTableSeparator(lines[1]) {
            bodyStart = 2
            let specs = tableCells(lines[1])
            alignments = header.indices.map { i in
                guard i < specs.count else { return .leading }
                let s = specs[i]
                if s.hasPrefix(":") && s.hasSuffix(":") && s.count > 1 { return .center }
                if s.hasSuffix(":") { return .trailing }
                return .leading
            }
        }
        // A partial row (still streaming) renders with whatever cells exist; missing cells are padded at render time.
        let rows = lines.dropFirst(bodyStart).map(tableCells).filter { !($0.count == 1 && $0[0].isEmpty) }
        return MarkdownTable(header: header, alignments: alignments, rows: rows)
    }

    static func cardKind(language: String, body: String, closed: Bool) -> String {
        if let colon = language.firstIndex(of: ":") { return String(language[language.index(after: colon)...]) }
        if closed, let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = (object["kind"] ?? object["type"]) as? String { return kind }
        // While streaming, sniff `"kind": "..."` without requiring valid JSON.
        if let range = body.range(of: #""(kind|type)"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let match = String(body[range])
            if let q = match.dropLast().lastIndex(of: "\"") { return String(match[match.index(after: q)..<match.index(before: match.endIndex)]) }
        }
        return "unknown"
    }
}

/// Holds the previous parse so appends only re-parse from the last (open) block.
/// Completed blocks are reused by value; their ids and hashes are untouched.
final class MarkdownIncrementalParser {
    private var lastText = ""
    private var lastComplete = false
    private(set) var blocks: [MarkdownBlock] = []

    func update(_ text: String, complete: Bool) -> [MarkdownBlock] {
        if text == lastText && complete == lastComplete { return blocks }
        defer { lastText = text; lastComplete = complete }
        // Non-append edits (rare: regenerate / retry) fall back to a full parse.
        guard text.hasPrefix(lastText), blocks.count >= 2 else {
            blocks = MarkdownBlockParser.parse(text, complete: complete)
            return blocks
        }
        // Keep everything before the last two blocks: the tail block may absorb new lines and the
        // one before it may only now learn it is complete. Re-parse only from the start of that block.
        let keep = blocks.count - 2
        let resumeLine = blocks[keep].startLine
        let lines = MarkdownBlockParser.splitLines(text)
        guard resumeLine < lines.count else {
            blocks = MarkdownBlockParser.parse(text, complete: complete)
            return blocks
        }
        let tail = MarkdownBlockParser.parse(lines: Array(lines[resumeLine...]), complete: complete,
                                             ordinalOffset: keep, lineOffset: resumeLine)
        blocks = Array(blocks[..<keep]) + tail
        return blocks
    }
}

/// Hides half-typed inline syntax in the streaming tail so raw `**`, `` ` `` or `[..](` never flash.
/// Per r10 §3 an unclosed emphasis / strike / code marker is hidden (no style until it closes);
/// a link whose URL is still arriving shows only its label.
enum MarkdownInlineSanitizer {
    static func closeDangling(_ text: String) -> String {
        var s = text
        // 1. Links whose destination is incomplete: "[label](http…" → "label"; "[label" → "label".
        if let r = s.range(of: #"\[([^\[\]]*)\]\([^)\s]*$"#, options: .regularExpression) {
            let label = s[r].dropFirst().prefix(while: { $0 != "]" })
            s.replaceSubrange(r, with: label)
        } else if let r = s.range(of: #"\[([^\[\]]*)\]?$"#, options: .regularExpression) {
            var label = s[r].dropFirst()
            if label.hasSuffix("]") { label = label.dropLast() }
            s.replaceSubrange(r, with: label)
        }
        // 2. Delimiter scan outside code spans.
        let chars = Array(s)
        var open: [(marker: String, index: Int)] = []
        var inCode = false
        var codeStart = 0
        var i = 0
        func isSpace(_ k: Int) -> Bool { k < 0 || k >= chars.count || chars[k].isWhitespace }
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" { inCode.toggle(); if inCode { codeStart = i }; i += 1; continue }
            if inCode { i += 1; continue }
            var marker: String?
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" { marker = "**" }
            else if c == "~", i + 1 < chars.count, chars[i + 1] == "~" { marker = "~~" }
            else if c == "*" { marker = "*" }
            guard let m = marker else { i += 1; continue }
            let len = m.count
            if let idx = open.lastIndex(where: { $0.marker == m }), !isSpace(i - 1) {
                open.removeSubrange(idx...)
            } else if !isSpace(i + len) || i + len >= chars.count {
                open.append((m, i))
            }
            i += len
        }
        // r10 §3: an unclosed marker renders no style yet, so its opener is hidden rather than closed.
        var drop = Set<Int>()
        if inCode { drop.insert(codeStart); open.removeAll { $0.index > codeStart } }
        for marker in open { for k in 0..<marker.marker.count { drop.insert(marker.index + k) } }
        guard !drop.isEmpty else { return s }
        return String(chars.enumerated().filter { !drop.contains($0.offset) }.map(\.element))
    }
}
