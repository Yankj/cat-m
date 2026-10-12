import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SyntheticImages {
    static func pixels(width: Int = 8, height: Int = 4, noise: Bool = false) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for pixel in 0..<width*height {
            if noise {
                for channel in 0..<3 {
                    seed = seed &* 1664525 &+ 1013904223
                    bytes[pixel*4+channel] = UInt8(truncatingIfNeeded: seed >> 24)
                }
            } else {
                bytes[pixel*4] = pixel % 2 == 0 ? 255 : 0
                bytes[pixel*4+1] = pixel % 2 == 0 ? 0 : 255
                bytes[pixel*4+2] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SyntheticFailure.image }
        return image
    }
    static func source(width: Int = 8, height: Int = 4, noise: Bool = false,
                       metadata: Bool = false, orientation: Int = 1, animated: Bool = false) throws -> Data {
        let buffer = NSMutableData(), image = try pixels(width: width, height: height, noise: noise)
        let type = animated ? UTType.gif.identifier : (metadata ? UTType.jpeg.identifier : UTType.png.identifier)
        guard let writer = CGImageDestinationCreateWithData(buffer, type as CFString, animated ? 2 : 1, nil) else { throw SyntheticFailure.image }
        var properties: [CFString: Any] = [:]
        if metadata {
            properties[kCGImagePropertyOrientation] = orientation
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "synthetic-private-metadata"]
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        if animated { CGImageDestinationAddImage(writer, image, nil) }
        guard CGImageDestinationFinalize(writer) else { throw SyntheticFailure.image }
        return buffer as Data
    }
    static func decoded(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SyntheticFailure.image }
        return image
    }
    enum SyntheticFailure: Error { case image }
}
