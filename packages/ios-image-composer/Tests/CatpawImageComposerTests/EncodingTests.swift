import XCTest
import ImageIO
import CryptoKit
@testable import CatpawImageComposer

final class EncodingTests: XCTestCase {
    private let encoder = SystemImageAttachmentEncoder()
    func testPNGReencodesSyntheticPixelsAndHashesFinalBytes() async throws {
        let input = try SyntheticImages.source()
        let result = try await encoder.encode(input, id: UUID(), format: .png, limits: .init())
        XCTAssertEqual(result.mimeType, "image/png")
        XCTAssertEqual(result.width, 8); XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.sha256, SHA256.hash(data: result.encodedData).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try SyntheticImages.decoded(result.encodedData).width, 8)
        let bytes = [UInt8](result.encodedData)
        var offset = 8, chunks: [String] = []
        while offset < bytes.count {
            let count = Int(bytes[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            chunks.append(String(bytes: bytes[offset+4..<offset+8], encoding: .ascii)!)
            offset += count + 12
        }
        XCTAssertEqual(chunks.first, "IHDR"); XCTAssertEqual(chunks.last, "IEND")
        XCTAssertTrue(chunks.allSatisfy { ["IHDR", "IDAT", "IEND"].contains($0) })
        XCTAssertEqual(bytes[24], 8); XCTAssertTrue([2,6].contains(bytes[25])); XCTAssertEqual(bytes[28], 0)
    }
    func testJPEGAndPNGStripGPSExifAndApplyOrientation() async throws {
        let input = try SyntheticImages.source(metadata: true, orientation: 6)
        let source = CGImageSourceCreateWithData(input as CFData, nil)!
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        XCTAssertNotNil(original[kCGImagePropertyGPSDictionary])
        for format in [ImageAttachmentFormat.png, .jpeg] {
            let result = try await encoder.encode(input, id: UUID(), format: format, limits: .init())
            XCTAssertEqual(result.width, 4); XCTAssertEqual(result.height, 8)
            let checked = CGImageSourceCreateWithData(result.encodedData as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(checked, 0, nil)! as NSDictionary
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary]); XCTAssertNil(properties[kCGImagePropertyExifDictionary])
            XCTAssertFalse(result.encodedData.range(of: Data("synthetic-private-metadata".utf8)) != nil)
            XCTAssertEqual(try SyntheticImages.decoded(result.encodedData).height, 8)
        }
    }
    func testLargePhotoIsDownsampledWithoutCroppingAndThumbnailIsBounded() async throws {
        let result = try await encoder.encode(SyntheticImages.source(width: 4096, height: 2048), id: UUID(), format: .png, limits: .init())
        XCTAssertEqual(result.width, 2048); XCTAssertEqual(result.height, 1024)
        let thumbnail = try SyntheticImages.decoded(result.thumbnailData)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 192)
        XCTAssertEqual(thumbnail.width, thumbnail.height * 2)
    }
    func testNoisyPhotoShrinksUntilEncodedByteCap() async throws {
        let result = try await encoder.encode(SyntheticImages.source(width: 512, height: 256, noise: true), id: UUID(), format: .png,
                                              limits: .init(maxEncodedBytes: 32_000))
        XCTAssertLessThanOrEqual(result.encodedData.count, 32_000)
        XCTAssertLessThan(result.width, 512)
        XCTAssertEqual(result.width, result.height * 2, accuracy: 1)
    }
    func testWireUsesCanonicalBase64AndRejectsMessageIdentityCollision() async throws {
        let result = try await encoder.encode(SyntheticImages.source(), id: UUID(), format: .png, limits: .init())
        let wire = try result.wire(messageID: UUID())
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["id", "mime_type", "sha256", "base64"])
        XCTAssertEqual(Data(base64Encoded: wire.base64), result.encodedData)
        XCTAssertEqual(wire.base64.count % 4, 0); XCTAssertFalse(wire.base64.hasPrefix("data:"))
        XCTAssertFalse(String(describing: wire).contains(wire.base64))
        XCTAssertFalse(String(reflecting: result).contains(wire.base64))
        XCTAssertThrowsError(try result.wire(messageID: result.id))
    }
    func testMalformedAndAnimatedSourcesAreRejected() async throws {
        for data in [Data(), Data("not an image".utf8)] {
            do { _ = try await encoder.encode(data, id: UUID(), format: .png, limits: .init()); XCTFail("Accepted malformed source") }
            catch { XCTAssertEqual(error as? ImageAttachmentError, .unsupportedSource) }
        }
        do { _ = try await encoder.encode(SyntheticImages.source(animated: true), id: UUID(), format: .png, limits: .init()); XCTFail("Accepted multi-frame source") }
        catch { XCTAssertEqual(error as? ImageAttachmentError, .animatedSource) }
    }
    func testInputLimitsAreCheckedBeforeThumbnailDecode() async throws {
        do { _ = try await encoder.encode(Data(repeating: 0, count: 50*1024*1024+1), id: UUID(), format: .png, limits: .init()); XCTFail("Accepted oversized file") }
        catch { XCTAssertEqual(error as? ImageAttachmentError, .inputTooLarge) }
        do { _ = try await encoder.encode(SyntheticImages.source(width: 16_385, height: 1), id: UUID(), format: .png, limits: .init()); XCTFail("Accepted oversized side") }
        catch { XCTAssertEqual(error as? ImageAttachmentError, .inputPixelsExceeded) }
    }
    func testImpossibleOutputCapFailsInsteadOfDroppingImage() async throws {
        do { _ = try await encoder.encode(SyntheticImages.source(), id: UUID(), format: .png, limits: .init(maxEncodedBytes: 1)); XCTFail("Accepted impossible cap") }
        catch { XCTAssertEqual(error as? ImageAttachmentError, .outputTooLarge) }
    }
    func testHostOverridesCannotExceedV2Limits() {
        let limits = ImageEncodingLimits(maxEncodedBytes: 100_000_000, maxSide: 10_000)
        XCTAssertEqual(limits.maxEncodedBytes, 5_242_880); XCTAssertEqual(limits.maxSide, 2048)
    }
}
