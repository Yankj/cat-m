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
        XCTAssertEqual(card.title, "不支持的组件"); XCTAssertEqual(error.code, "schema_invalid"); XCTAssertEqual(error.blockId, "fx-bad")
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
}
