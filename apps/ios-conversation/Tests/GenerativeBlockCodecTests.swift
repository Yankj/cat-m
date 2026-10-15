import XCTest
@testable import CatpawM

final class GenerativeBlockCodecTests: XCTestCase {
    func testAllFixturesDecodeOrDegrade() {
        for json in GenerativeBlockFixtures.all {
            switch GenerativeBlockCodec.decode(Data(json.utf8)) {
            case .ready(let b): XCTAssertFalse(b.id.isEmpty)
            case .fallback(let card, let error): XCTAssertEqual(card.kind, .card); XCTAssertFalse(error.code.isEmpty)
            }
        }
    }
    func testUnknownKindDegradesToCardWithoutRawJSON() {
        guard case .fallback(let card, let error) = GenerativeBlockCodec.decode(Data(GenerativeBlockFixtures.invalid.utf8)) else { return XCTFail() }
        XCTAssertEqual(card.title, "不支持的组件"); XCTAssertEqual(error.code, "schema_invalid"); XCTAssertNil(error.interruptId); XCTAssertEqual(error.blockId, "fx-bad")
    }
    func testWrapperAndLimits() throws {
        guard case .ready(let b) = GenerativeBlockCodec.decode(Data(GenerativeBlockFixtures.choices.utf8)) else { return XCTFail() }
        XCTAssertEqual(b.items?.count, 3); XCTAssertEqual(b.effectiveSelection, .single)
        let many = (0..<9).map { #"{"id":"\#($0)","label":"x"}"# }.joined(separator: ",")
        guard case .fallback(_, let e) = GenerativeBlockCodec.decode(Data(#"{"id":"m","kind":"choices","items":[\#(many)]}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(e.path, "items")
    }
    func testExpiryAndResponseEncoding() throws {
        guard case .ready(let b) = GenerativeBlockCodec.decode(Data(GenerativeBlockFixtures.expired.utf8)) else { return XCTFail() }
        XCTAssertTrue(b.isExpired())
        let r = GenerativeBlockResponse(blockId: "b", actionId: nil, selected: ["a"], other: "自定义")
        let json = try XCTUnwrap(String(data: GenerativeBlockCodec.encoder.encode(r), encoding: .utf8))
        XCTAssertTrue(json.contains(#""type":"ui.response""#)); XCTAssertEqual(r.values["other"], .string("自定义"))
    }

    // services/edge/docs/fixtures/catpaw-ui-demo.jsonl — the recorded catpaw.ui.v1 wire session.
    private func recording() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("services/edge/docs/fixtures/catpaw-ui-demo.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
    private func events(_ lines: [[String: Any]], _ type: String) -> [Data] {
        lines.flatMap { ($0["events"] as? [[String: Any]]) ?? [] }.filter { $0["type"] as? String == type }
            .compactMap { try? JSONSerialization.data(withJSONObject: $0["data"] as Any) }
    }
    func testRecordedBlocksDecodeAndCarryInterruptLinkage() throws {
        let lines = try recording()
        let blocks = events(lines, "ui.block")
        XCTAssertEqual(blocks.count, 7)
        var interactive: [String] = []
        for data in blocks {
            guard case .ready(let b) = GenerativeBlockCodec.decode(data) else { return XCTFail(String(decoding: data, as: UTF8.self)) }
            XCTAssertEqual(b.needsAnswer, b.interruptId != nil, b.id)
            if b.interruptId != nil { XCTAssertEqual(b.argsHash?.count, 64); XCTAssertNotNil(b.expiresAt); interactive.append(b.id) }
        }
        XCTAssertEqual(Set(interactive), ["demo-choices", "demo-form", "demo-confirm", "demo-sheet"])
        for data in events(lines, "ui.block.update") { XCTAssertNoThrow(try GenerativeBlockCodec.decoder.decode(GenerativeBlockPatch.self, from: data)) }
        let resolutions = try events(lines, "ui.block.resolve").map { try GenerativeBlockCodec.decoder.decode(GenerativeBlockResolution.self, from: $0) }
        XCTAssertEqual(resolutions.map(\.status), ["submitted", "submitted", "submitted", "dismissed"])
    }
    func testRecordedClientBodiesMatchOurResponseShape() throws {
        for line in try recording() where line["direction"] as? String == "client" {
            let body = try XCTUnwrap(line["body"] as? [String: Any])
            let decision = try XCTUnwrap(GenerativeUIDecision(rawValue: try XCTUnwrap(body["decision"] as? String)))
            if let response = body["response"] {
                let data = try JSONSerialization.data(withJSONObject: response)
                let decoded = try GenerativeBlockCodec.decoder.decode(GenerativeBlockResponse.self, from: data)
                XCTAssertEqual(decision, .submit); XCTAssertEqual(decoded.blockId, line["blockId"] as? String)
                if decoded.blockId == "demo-confirm" { XCTAssertNotNil(decoded.actionId) }
                // Round-trip through our encoder keeps the contract keys.
                let ours = try XCTUnwrap(JSONSerialization.jsonObject(with: GenerativeBlockCodec.encoder.encode(decoded)) as? [String: Any])
                XCTAssertEqual(ours["type"] as? String, "ui.response"); XCTAssertNotNil(ours["respondedAt"])
            } else { XCTAssertEqual(decision, .dismiss) }
        }
    }
    func testDisplayBlocksAreNotPatchableWhenInteractive() async throws {
        await MainActor.run {
            let store = GenerativeBlockStore(defaults: nil)
            let ctx = GenerativeBlockStore.Context(conversationID: UUID(), turnID: UUID())
            store.receive(Data(#"{"id":"p","kind":"progress","steps":[{"id":"a","label":"x","state":"running"}]}"#.utf8), context: ctx)
            store.receive(Data(#"{"id":"c","kind":"confirm","title":"t","interruptId":"i","argsHash":"\#(String(repeating: "0", count: 64))"}"#.utf8), context: ctx)
            store.update(GenerativeBlockPatch(id: "p", title: "new")); store.update(GenerativeBlockPatch(id: "c", title: "hacked"))
            XCTAssertEqual(store.blocks["p"]?.title, "new"); XCTAssertEqual(store.blocks["c"]?.title, "t")
        }
    }
    func testResponseOmitsOptionalKeysAndDecodesMinimalBody() throws {
        let minimal = try GenerativeBlockCodec.decoder.decode(GenerativeBlockResponse.self, from: Data(#"{"type":"ui.response","blockId":"demo-sheet","actionId":null}"#.utf8))
        XCTAssertNil(minimal.actionId); XCTAssertEqual(minimal.values, [:]); XCTAssertEqual(minimal.selected, [])
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: GenerativeBlockCodec.encoder.encode(GenerativeBlockResponse(blockId: "b", actionId: nil))) as? [String: Any])
        XCTAssertNil(wire["actionId"]); XCTAssertNil(wire["values"]); XCTAssertNil(wire["selected"]); XCTAssertEqual(wire["blockId"] as? String, "b")
    }
    func testBlocksAreStoredPerConversation() async throws {
        await MainActor.run {
            let suite = "catpaw.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = GenerativeBlockStore(defaults: defaults)
            let a = UUID(), b = UUID()
            store.activate(conversationID: a)
            store.receive(Data(#"{"id":"demo-card","kind":"card","title":"A"}"#.utf8), context: .init(conversationID: a, turnID: UUID()))
            store.activate(conversationID: b)
            XCTAssertNil(store.blocks["demo-card"])
            store.receive(Data(#"{"id":"demo-card","kind":"card","title":"B"}"#.utf8), context: .init(conversationID: b, turnID: UUID()))
            store.activate(conversationID: a)
            XCTAssertEqual(store.blocks["demo-card"]?.title, "A")
        }
    }
}
