import Foundation
import ImageIO

/// No UIApplication, photo-library access, model or service. Only synthetic pixels.
@main struct CodecSmoke {
    static func main() async throws {
        let input = try SyntheticImages.source(metadata: true, orientation: 6)
        var payloads: [[String: Any]] = []
        for format in [ImageAttachmentFormat.png, .jpeg] {
            let result = try await SystemImageAttachmentEncoder().encode(input, id: UUID(), format: format, limits: .init())
            guard result.width == 4, result.height == 8, result.encodedData.count <= 5_242_880 else { fatalError("Codec limits/orientation failed") }
            let source = CGImageSourceCreateWithData(result.encodedData as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            guard properties[kCGImagePropertyGPSDictionary] == nil, properties[kCGImagePropertyExifDictionary] == nil else { fatalError("Metadata survived") }
            let messageID = UUID(), wire = try result.wire(messageID: messageID)
            let attachment = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire))
            payloads.append(["schema_version":2,"turn_id":UUID().uuidString,"expected_revision":1,"expected_grant_epoch":1,
                             "message":["id":messageID.uuidString,"text":"Synthetic codec interoperability only", "attachments":[attachment]],"context":[]])
        }
        if let output = CommandLine.arguments.dropFirst().first {
            try JSONSerialization.data(withJSONObject: payloads).write(to: URL(fileURLWithPath: output))
        }
        print("PASS iOS synthetic PNG/JPEG codec, orientation and EXIF/GPS removal; no picker/UI/live-route claim")
    }
}
