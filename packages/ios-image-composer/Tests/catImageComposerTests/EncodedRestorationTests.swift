import XCTest
import ImageIO
import CryptoKit
@testable import catImageComposer

final class EncodedRestorationTests: XCTestCase {
    private let encoder = SystemImageAttachmentEncoder()
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func restore(_ packet: PreparedImageAttachment, bytes: Data? = nil, mime: String? = nil,
                         digest: String? = nil, size: Int? = nil, width: Int? = nil, height: Int? = nil,
                         limits: ImageEncodingLimits = .init()) async throws -> PreparedImageAttachment {
        try await encoder.restoreEncoded(bytes ?? packet.encodedData, id: packet.id,
            mimeType: mime ?? packet.mimeType, sha256: digest ?? packet.sha256,
            sizeBytes: size ?? packet.encodedData.count, width: width ?? packet.width,
            height: height ?? packet.height, limits: limits)
    }
    func testBothSupportedFormatsRestoreExactPreparedBytesAndIdentity() async throws {
        for format in [ImageAttachmentFormat.png, .jpeg] {
            let original = try await encoder.encode(SyntheticImages.source(metadata: true, orientation: 6), id: UUID(), format: format)
            let recovered = try await restore(original)
            XCTAssertEqual(recovered.id, original.id)
            XCTAssertEqual(recovered.mimeType, original.mimeType)
            XCTAssertEqual(recovered.sha256, original.sha256)
            XCTAssertEqual(recovered.encodedData, original.encodedData)
            XCTAssertEqual(recovered.width, 4); XCTAssertEqual(recovered.height, 8)
            let preview = try SyntheticImages.decoded(recovered.thumbnailData)
            XCTAssertLessThanOrEqual(max(preview.width, preview.height), 192)
            if format == .jpeg {
                let legacy = try await encoder.encode(original.encodedData, id: original.id, format: .png)
                XCTAssertNotEqual(legacy.sha256, original.sha256, "The former restore path changed a supported JPEG's transport identity")
            }
        }
    }
    func testValidPNGWithDifferentIDATLayoutIsPreservedInsteadOfCanonicalized() async throws {
        let original = try await encoder.encode(SyntheticImages.source(noise: true), id: UUID(), format: .png)
        let alternate = try splitIDAT(original.encodedData)
        XCTAssertNotEqual(alternate, original.encodedData)
        let recovered = try await restore(original, bytes: alternate, digest: hash(alternate), size: alternate.count)
        XCTAssertEqual(recovered.encodedData, alternate)
        XCTAssertEqual(recovered.sha256, hash(alternate))
        XCTAssertEqual(try SyntheticImages.decoded(alternate).width, original.width)
    }
    func testReceiptMIMEHashLengthAndDimensionsMustAllMatchActualContainer() async throws {
        let original = try await encoder.encode(SyntheticImages.source(), id: UUID(), format: .jpeg)
        for index in 0..<7 {
            do {
                switch index {
                case 0: _ = try await restore(original, mime: "image/png")
                case 1: _ = try await restore(original, mime: "image/gif")
                case 2: _ = try await restore(original, digest: String(repeating: "0", count: 64))
                case 3: _ = try await restore(original, digest: original.sha256.uppercased())
                case 4: _ = try await restore(original, size: original.encodedData.count + 1)
                case 5: _ = try await restore(original, width: original.width + 1)
                default: _ = try await restore(original, height: original.height + 1)
                }
                XCTFail("Accepted mismatched frozen receipt \(index)")
            } catch { XCTAssertTrue(error is ImageAttachmentError) }
        }
    }
    func testIncompleteTrailingOrMetadataBearingContainerCannotBeRestoredEvenWithMatchingHash() async throws {
        let original = try await encoder.encode(SyntheticImages.source(), id: UUID(), format: .jpeg)
        let rawWithMetadata = try SyntheticImages.source(metadata: true)
        for bytes in [Data(original.encodedData.dropLast(2)), original.encodedData + Data([0]), rawWithMetadata] {
            do { _ = try await restore(original, bytes: bytes, digest: hash(bytes), size: bytes.count)
                XCTFail("Restoration accepted a damaged container or an unprepared raw import")
            } catch { XCTAssertTrue(error is ImageAttachmentError) }
        }
    }
    func testRestorationHonorsTighterLimitsWithoutChangingSnapshot() async throws {
        let original = try await encoder.encode(SyntheticImages.source(), id: UUID(), format: .png)
        for limits in [ImageEncodingLimits(maxEncodedBytes: original.encodedData.count - 1), ImageEncodingLimits(maxSide: original.width - 1)] {
            do { _ = try await restore(original, limits: limits); XCTFail("Restore silently recompressed an over-budget snapshot") }
            catch { XCTAssertTrue(error is ImageAttachmentError) }
        }
    }
    func testCancelledRestorationCannotReturnPreparedPacket() async throws {
        let original = try await encoder.encode(SyntheticImages.source(), id: UUID(), format: .png)
        let operation = Task { try Task.checkCancellation(); return try await self.restore(original) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled restore returned a new prepared packet") }
        catch is CancellationError { }
    }
    private func splitIDAT(_ data: Data) throws -> Data {
        let bytes = [UInt8](data); var result = Data(bytes.prefix(8)), offset = 8, split = false
        func word(_ value: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
        func chunk(_ payload: Data) -> Data {
            let body = Data("IDAT".utf8) + payload
            var crc: UInt32 = 0xffffffff
            for byte in body { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            return word(UInt32(payload.count)) + body + word(crc ^ 0xffffffff)
        }
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let end = offset + length + 12
            guard end <= bytes.count else { throw ImageAttachmentError.encodingFailed }
            if !split, length > 1, String(bytes: bytes[offset+4..<offset+8], encoding: .ascii) == "IDAT" {
                let payload = Data(bytes[offset+8..<end-4]), midpoint = length / 2
                result += chunk(Data(payload.prefix(midpoint))); result += chunk(Data(payload.dropFirst(midpoint))); split = true
            } else { result.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        guard split, offset == bytes.count else { throw ImageAttachmentError.encodingFailed }
        return result
    }
}
