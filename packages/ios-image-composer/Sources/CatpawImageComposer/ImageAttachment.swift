import Foundation

public enum ImageAttachmentFormat: String, Sendable { case png, jpeg }
public struct ImageEncodingLimits: Sendable {
    public static let wireMaxBytes = 5_242_880
    public static let wireMaxSide = 2048
    public let maxEncodedBytes: Int
    public let maxSide: Int
    public let maxInputBytes = 50 * 1024 * 1024
    public let maxInputPixels = 100_000_000
    public let maxInputSide = 16_384
    /// Overrides can tighten the v2 contract, never raise its limits.
    public init(maxEncodedBytes: Int = wireMaxBytes, maxSide: Int = wireMaxSide) {
        self.maxEncodedBytes = max(1, min(Self.wireMaxBytes, maxEncodedBytes))
        self.maxSide = max(1, min(Self.wireMaxSide, maxSide))
    }
}
public enum ImageAttachmentError: String, Error, Sendable {
    case selectionUnavailable, inputTooLarge, inputPixelsExceeded, unsupportedSource
    case animatedSource, encodingFailed, outputTooLarge, cancelled, identityCollision
    public var message: String {
        switch self {
        case .selectionUnavailable: "未能读取所选图片。请重试或重新选择。"
        case .inputTooLarge: "原图过大。请选择小于 50 MiB 的图片。"
        case .inputPixelsExceeded: "原图像素过大。请选择尺寸较小的图片。"
        case .unsupportedSource: "无法读取这张图片。请选择其他静态图片。"
        case .animatedSource: "暂不支持动画或多帧图片。请选择静态图片。"
        case .encodingFailed: "图片处理失败。请重试或重新选择。"
        case .outputTooLarge: "压缩后仍超过图片上限。请选择其他图片。"
        case .cancelled: "已取消处理，原有附件保留。"
        case .identityCollision: "图片尚未准备好，请重新选择。"
        }
    }
}

/// Constructed only by the encoder. Never persist/log encodedData or its base64 representation.
public struct PreparedImageAttachment: Equatable, Sendable, CustomDebugStringConvertible, CustomStringConvertible {
    public let id: UUID
    public let mimeType: String
    public let sha256: String
    public let encodedData: Data
    public let thumbnailData: Data
    public let width: Int
    public let height: Int
    public var description: String { debugDescription }
    public var debugDescription: String { "PreparedImageAttachment(\(mimeType), \(width)x\(height), \(encodedData.count) bytes)" }
    public func wire(messageID: UUID) throws -> ImageAttachmentWire {
        guard id != messageID else { throw ImageAttachmentError.identityCollision }
        return .init(id: id, mimeType: mimeType, sha256: sha256, base64: encodedData.base64EncodedString())
    }
}
public struct ImageAttachmentWire: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let mimeType: String
    public let sha256: String
    public let base64: String
    public var description: String { "ImageAttachmentWire(\(mimeType), payload omitted)" }
    public var debugDescription: String { description }
    enum CodingKeys: String, CodingKey { case id, mimeType = "mime_type", sha256, base64 }
}
public struct ImageSendGate: Sendable {
    public var available: Bool
    public var liveTransmissionAvailable: Bool
    public var textConsentGranted: Bool
    public var imageConsentMatchesCurrentRoute: Bool
    public init(available: Bool = false, liveTransmissionAvailable: Bool = false,
                textConsentGranted: Bool = false, imageConsentMatchesCurrentRoute: Bool = false) {
        self.available = available; self.liveTransmissionAvailable = liveTransmissionAvailable
        self.textConsentGranted = textConsentGranted
        self.imageConsentMatchesCurrentRoute = imageConsentMatchesCurrentRoute
    }
    public static let unavailable = ImageSendGate()
}
public enum ImageSendBlock: String, Sendable {
    case unavailable, processing, notPrepared, imageConsentRequired, textConsentRequired, captionRequired, captionTooLarge, identityCollision
    public var message: String {
        switch self {
        case .unavailable: "图片发送暂不可用。所选图片仅保留在本机。"
        case .processing: "请等待图片处理完成。"
        case .notPrepared: "请先完成图片处理，或移除图片后发送文字。"
        case .imageConsentRequired: "发送图片前需要确认本次图片处理方式。"
        case .textConsentRequired: "请先确认此对话的文字处理方式。"
        case .captionRequired: "请添加你想问的问题。"
        case .captionTooLarge: "文字过长，请缩短后再发送。"
        case .identityCollision: "附件状态已变化，请重新准备发送。"
        }
    }
}
