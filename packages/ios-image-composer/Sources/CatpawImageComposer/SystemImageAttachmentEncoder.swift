import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers

public protocol ImageAttachmentEncoding: Sendable {
    func encode(_ data: Data, id: UUID, format: ImageAttachmentFormat,
                limits: ImageEncodingLimits) async throws -> PreparedImageAttachment
}
public struct SystemImageAttachmentEncoder: ImageAttachmentEncoding {
    public init() {}
    public func encode(_ data: Data, id: UUID, format: ImageAttachmentFormat = .png,
                       limits: ImageEncodingLimits = .init()) async throws -> PreparedImageAttachment {
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try Self.prepare(data, id: id, format: format, limits: limits) }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func prepare(_ data: Data, id: UUID, format: ImageAttachmentFormat,
                                limits: ImageEncodingLimits) throws -> PreparedImageAttachment {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw ImageAttachmentError.unsupportedSource }
        guard data.count <= limits.maxInputBytes else { throw ImageAttachmentError.inputTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw ImageAttachmentError.unsupportedSource }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageAttachmentError.animatedSource }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= limits.maxInputSide, h <= limits.maxInputSide,
              w <= limits.maxInputPixels / h else { throw ImageAttachmentError.inputPixelsExceeded }
        var edge = min(limits.maxSide, max(w, h))
        for _ in 0..<16 {
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                    bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageAttachmentError.encodingFailed }
            if format == .jpeg {
                canvas.setFillColor(CGColor(gray: 1, alpha: 1))
                canvas.fill(CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            }
            canvas.interpolationQuality = .high
            canvas.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            guard let normalized = canvas.makeImage() else { throw ImageAttachmentError.encodingFailed }
            let buffer = NSMutableData()
            let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
            guard let destination = CGImageDestinationCreateWithData(buffer, type as CFString, 1, nil) else { throw ImageAttachmentError.encodingFailed }
            let properties: [CFString: Any] = format == .png
                ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0]]
                : [kCGImageDestinationLossyCompressionQuality: 0.82,
                   kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false]]
            CGImageDestinationAddImage(destination, normalized, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageAttachmentError.encodingFailed }
            let bytes = try ImageContainerSanitizer.strip(buffer as Data, format: format)
            try Task.checkCancellation()
            if bytes.count <= limits.maxEncodedBytes {
                guard normalized.width <= limits.maxSide, normalized.height <= limits.maxSide,
                      let check = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil),
                      decoded.width == normalized.width, decoded.height == normalized.height else { throw ImageAttachmentError.encodingFailed }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                return .init(id: id, mimeType: format == .png ? "image/png" : "image/jpeg", sha256: digest,
                             encodedData: bytes, thumbnailData: try preview(normalized), width: normalized.width, height: normalized.height)
            }
            guard edge > 1 else { break }
            edge = max(1, Int(Double(edge) * 0.75))
        }
        throw ImageAttachmentError.outputTooLarge
    }
    private static func preview(_ image: CGImage) throws -> Data {
        let scale = min(1, 192.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageAttachmentError.encodingFailed }
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = NSMutableData()
        guard let pixels = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { throw ImageAttachmentError.encodingFailed }
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageAttachmentError.encodingFailed }
        return try ImageContainerSanitizer.strip(buffer as Data, format: .png)
    }
}

/// Only sanitize freshly re-encoded pixels, never forward the source container.
enum ImageContainerSanitizer {
    static func strip(_ data: Data, format: ImageAttachmentFormat) throws -> Data {
        let bytes = [UInt8](data)
        return try format == .png ? png(bytes) : jpeg(bytes)
    }
    private static func png(_ b: [UInt8]) throws -> Data {
        guard b.count >= 33, Array(b.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw ImageAttachmentError.encodingFailed }
        var result = Data(b.prefix(8)), offset = 8, sawHeader = false, sawData = false
        while offset + 12 <= b.count {
            let length = Int(b[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length <= b.count - offset - 12 else { throw ImageAttachmentError.encodingFailed }
            let end = offset + length + 12
            let type = String(bytes: b[offset+4..<offset+8], encoding: .ascii) ?? ""
            switch type {
            case "IHDR":
                guard offset == 8, length == 13, !sawHeader,
                      b[offset+16] == 8, [2,6].contains(b[offset+17]),
                      b[offset+18] == 0, b[offset+19] == 0, b[offset+20] == 0 else { throw ImageAttachmentError.encodingFailed }
                sawHeader = true
            case "IDAT": guard sawHeader, length > 0 else { throw ImageAttachmentError.encodingFailed }; sawData = true
            case "IEND": guard sawHeader, sawData, length == 0, end == b.count else { throw ImageAttachmentError.encodingFailed }
            default:
                guard b[offset+4] & 0x20 != 0 else { throw ImageAttachmentError.encodingFailed }
                offset = end; continue // EXIF/XMP/ICC/text/time/etc never reach the wire.
            }
            result.append(contentsOf: b[offset..<end])
            if type == "IEND" { return result }
            offset = end
        }
        throw ImageAttachmentError.encodingFailed
    }
    private static func jpeg(_ b: [UInt8]) throws -> Data {
        guard b.count >= 4, b[0] == 255, b[1] == 216 else { throw ImageAttachmentError.encodingFailed }
        var result = Data([255,216]), offset = 2, sawFrame = false
        while offset + 4 <= b.count {
            guard b[offset] == 255 else { throw ImageAttachmentError.encodingFailed }
            let marker = b[offset+1], length = Int(b[offset+2]) * 256 + Int(b[offset+3])
            guard length >= 2, length <= b.count - offset - 2 else { throw ImageAttachmentError.encodingFailed }
            let end = offset + 2 + length
            if marker == 192 { sawFrame = true }
            if (224...239).contains(marker) || marker == 254 { offset = end; continue }
            guard [192,196,219,221,218].contains(marker) else { throw ImageAttachmentError.encodingFailed }
            result.append(contentsOf: b[offset..<end])
            if marker == 218 {
                guard sawFrame else { throw ImageAttachmentError.encodingFailed }
                var cursor = end
                while cursor < b.count - 1 {
                    if b[cursor] != 255 { cursor += 1; continue }
                    let next = b[cursor+1]
                    if next == 0 || (208...215).contains(next) { cursor += 2; continue }
                    guard next == 217, cursor + 2 == b.count else { throw ImageAttachmentError.encodingFailed }
                    result.append(contentsOf: b[end..<b.count]); return result
                }
                throw ImageAttachmentError.encodingFailed
            }
            offset = end
        }
        throw ImageAttachmentError.encodingFailed
    }
}
