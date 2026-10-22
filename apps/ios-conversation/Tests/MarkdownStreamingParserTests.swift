import XCTest
@testable import cat

final class MarkdownStreamingParserTests: XCTestCase {
    static let sample = """
    # Title

    Intro with **bold**, *italic*, ~~gone~~ and `code`.

    - one
      - nested
    - two

    1. first
    2. second

    > quoted line
    > more

    | Name | Value |
    |:-----|------:|
    | a | 1 |
    | b | 2 |

    ```swift
    let x = 1
    print(x)
    ```

    ```catpaw-card
    {"kind": "reminder", "title": "Water"}
    ```

    ---

    Tail paragraph.
    """

    func testFullDocumentKinds() {
        let blocks = MarkdownBlockParser.parse(Self.sample, complete: true)
        XCTAssertEqual(blocks.map(\.kind.tag), ["h", "p", "l", "l", "q", "t", "c", "x", "r", "p"])
        guard case let .list(items) = blocks[2].kind else { return XCTFail("list") }
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
        guard case let .table(table) = blocks[5].kind else { return XCTFail("table") }
        XCTAssertEqual(table.header, ["Name", "Value"])
        XCTAssertEqual(table.alignments, [.leading, .trailing])
        XCTAssertEqual(table.rows.count, 2)
        guard case let .code(language, code, closed) = blocks[6].kind else { return XCTFail("code") }
        XCTAssertEqual(language, "swift"); XCTAssertEqual(code, "let x = 1\nprint(x)"); XCTAssertTrue(closed)
        guard case let .custom(kind, _, cardClosed) = blocks[7].kind else { return XCTFail("card") }
        XCTAssertEqual(kind, "reminder"); XCTAssertTrue(cardClosed)
        XCTAssertTrue(blocks.allSatisfy(\.isComplete))
    }

    /// Every streaming prefix: completed blocks keep the id and source they have in the final document.
    func testStreamingPrefixesKeepCompletedBlockIDsStable() {
        let final = MarkdownBlockParser.parse(Self.sample, complete: true)
        let incremental = MarkdownIncrementalParser()
        let characters = Array(Self.sample)
        for end in stride(from: 1, through: characters.count, by: 1) {
            let prefix = String(characters[..<end])
            let fresh = MarkdownBlockParser.parse(prefix, complete: false)
            let reused = incremental.update(prefix, complete: false)
            XCTAssertEqual(fresh, reused, "incremental parse diverged at \(end)")
            for block in fresh where block.isComplete {
                guard let match = final.first(where: { $0.id == block.id }) else {
                    return XCTFail("completed block \(block.id) missing from final document at prefix \(end)")
                }
                XCTAssertEqual(match.source, block.source, "completed block \(block.id) changed at prefix \(end)")
            }
            // Only the tail block may be incomplete.
            XCTAssertTrue(fresh.dropLast().allSatisfy(\.isComplete))
        }
        XCTAssertEqual(incremental.update(Self.sample, complete: true), final)
    }

    func testUnclosedFenceIsAnOpenCodeBlockWithTheSameID() {
        let open = MarkdownBlockParser.parse("Hi\n\n```py\nprint(1)\n``", complete: false)
        guard case let .code(language, code, closed) = open.last?.kind else { return XCTFail("code") }
        XCTAssertEqual(language, "py"); XCTAssertEqual(code, "print(1)"); XCTAssertFalse(closed)
        let done = MarkdownBlockParser.parse("Hi\n\n```py\nprint(1)\n```", complete: false)
        XCTAssertEqual(open.last?.id, done.last?.id)
    }

    func testPartialTableRowAndHeaderOnly() {
        let headerOnly = MarkdownBlockParser.parse("| A | B", complete: false)
        guard case let .table(t1) = headerOnly.first?.kind else { return XCTFail("table") }
        XCTAssertEqual(t1.header, ["A", "B"])
        let partial = MarkdownBlockParser.parse("| A | B |\n|---|---|\n| 1 |", complete: false)
        guard case let .table(t2) = partial.first?.kind else { return XCTFail("table") }
        XCTAssertEqual(t2.rows, [["1"]])
        XCTAssertEqual(t2.columnCount, 2)
    }

    func testDanglingInlineMarkersAreHiddenWhileStreaming() {
        XCTAssertEqual(MarkdownInlineSanitizer.closeDangling("say **hel"), "say hel")
        XCTAssertEqual(MarkdownInlineSanitizer.closeDangling("a `co"), "a co")
        XCTAssertEqual(MarkdownInlineSanitizer.closeDangling("see [docs](https://ex"), "see docs")
        XCTAssertEqual(MarkdownInlineSanitizer.closeDangling("~~x"), "x")
        XCTAssertEqual(MarkdownInlineSanitizer.closeDangling("trailing *"), "trailing ")
        XCTAssertEqual(MarkdownInlineSanitizer.closeDangling("done **b** ok"), "done **b** ok")
    }
}

final class MarkdownSyntaxHighlighterTests: XCTestCase {
    func testSwiftLineTokens() {
        let spans = MarkdownSyntaxHighlighter.spans(line: #"let url = "a//b" // note 42"#, language: "swift")
        XCTAssertEqual(spans.map(\.token), [.keyword, .string, .comment])
        XCTAssertTrue(MarkdownSyntaxHighlighter.spans(line: "x = 1", language: "unknown-lang").isEmpty)
        XCTAssertEqual(MarkdownSyntaxHighlighter.spans(line: "def f(): return None", language: "py").map(\.token), [.keyword, .keyword, .literal])
    }
}
