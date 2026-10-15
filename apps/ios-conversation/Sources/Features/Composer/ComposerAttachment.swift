import Foundation
import ImageIO
import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Local attachment staged in the composer. Upload transport belongs to 三角 (`ComposerAttachmentUploading`);
/// this file is UI state + limits only.
struct ComposerAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, pdf, text, spreadsheet, other }
    enum Status: Equatable, Sendable {
        case staged
        case uploading(fraction: Double)
        case uploaded(receiptID: String)
        case failed(message: String)
    }
    let id: UUID
    let localURL: URL          // file in the app's Caches/ComposerStaging dir; used by Quick Look
    let filename: String
    let kind: Kind
    let byteCount: Int64
    var thumbnail: Data?       // JPEG ≤ 240px, produced at stage time
    var status: Status = .staged
    var isSendable: Bool { if case .uploaded = status { return true }; return false }
}

enum ComposerAttachmentLimits {
    static let maxPerMessage = 10
    static let maxBytes: Int64 = 20 * 1024 * 1024
    /// Pasted text longer than this becomes a .txt attachment (mapping §3).
    static let pasteTextThreshold = 400
    static let importTypes: [UTType] = [.image, .pdf, .plainText, .commaSeparatedText, .spreadsheet, .json]
}

enum ComposerAttachmentRejection: Equatable {
    case tooMany(accepted: Int), tooLarge(filename: String), unsupported(filename: String)
}

/// Seam for 三角: upload, cancel, retry. UI calls only these; progress comes back by mutating `attachments`.
@MainActor protocol ComposerAttachmentUploading: AnyObject {
    func upload(_ attachment: ComposerAttachment)
    func cancel(_ id: UUID)
}

/// UI-only upload simulator. It never opens a network connection or creates a
/// durable receipt; it only drives composer chrome through its upload states.
@MainActor final class LocalMockComposerAttachmentUploader: ObservableObject, ComposerAttachmentUploading {
    typealias Update = (_ id: UUID, _ status: ComposerAttachment.Status) -> Bool

    private let update: Update
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]

    init(update: @escaping Update) {
        self.update = update
    }

    func upload(_ attachment: ComposerAttachment) {
        cancel(attachment.id)
        #if !DEBUG
        // The simulated success path is intentionally unavailable in production builds.
        _ = update(attachment.id, .failed(message: ""))
        return
        #else
        let token = UUID()
        tokens[attachment.id] = token
        guard update(attachment.id, .uploading(fraction: 0)) else {
            tokens.removeValue(forKey: attachment.id)
            return
        }

        let id = attachment.id
        tasks[id] = Task { @MainActor [weak self] in
            let steps = [0.12, 0.34, 0.62, 0.86, 1.0]
            for fraction in steps {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.tokens[id] == token,
                      self.update(id, .uploading(fraction: fraction)) else { return }
            }
            guard let self,
                  self.tokens[id] == token,
                  self.update(id, .uploaded(receiptID: "local-mock-\(id.uuidString.lowercased())")) else { return }
            self.tokens.removeValue(forKey: id)
            self.tasks.removeValue(forKey: id)
        }
        #endif
    }

    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        tokens.removeValue(forKey: id)
    }
}

/// Composer run state for the send/stop morph. Mirrors what `ConversationFirstModel` already knows.
enum ComposerRunState: Equatable { case idle, responding, offlineQueued }

/// Thin view-model the composer chrome binds to. `ConversationFirstModel` (or an adapter) conforms.
@MainActor protocol ComposerChromeModel: ObservableObject {
    var draftIsEmpty: Bool { get }
    var isComposingMarkedText: Bool { get }
    var runState: ComposerRunState { get }
    /// Draft queued to send after the current answer finishes ("排队发送").
    var queuedDraftPreview: String? { get }
    var attachments: [ComposerAttachment] { get set }
    func send()
    func stop()
    func cancelQueued()
}

@MainActor extension ComposerChromeModel {
    var attachmentsAreReady: Bool { attachments.allSatisfy(\.isSendable) }

    @discardableResult
    func addAttachments(_ items: [ComposerAttachment], using uploader: ComposerAttachmentUploading?) -> ComposerAttachmentRejection? {
        let (accepted, rejection) = ComposerAttachmentStager.admit(items, existing: attachments.count)
        attachments.append(contentsOf: accepted)
        accepted.forEach { uploader?.upload($0) }
        return rejection
    }

    func retryAttachment(_ item: ComposerAttachment, using uploader: ComposerAttachmentUploading?) {
        guard let index = attachments.firstIndex(where: { $0.id == item.id }) else { return }
        attachments[index].status = .staged
        uploader?.upload(attachments[index])
    }

    func removeAttachment(_ item: ComposerAttachment, using uploader: ComposerAttachmentUploading?) {
        uploader?.cancel(item.id)
        attachments.removeAll { $0.id == item.id }
        ComposerAttachmentStager.discard(item)
    }

    func discardAttachments(using uploader: ComposerAttachmentUploading?) {
        let discarded = attachments
        discarded.forEach { uploader?.cancel($0.id) }
        attachments.removeAll()
        discarded.forEach(ComposerAttachmentStager.discard)
    }
}

extension ComposerAttachment.Kind {
    init(_ type: UTType?) {
        guard let type else { self = .other; return }
        if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) { self = .spreadsheet }
        else if type.conforms(to: .text) { self = .text }
        else { self = .other }
    }
    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.plaintext"
        case .spreadsheet: "tablecells"
        case .other: "doc"
        }
    }
}

/// Copies picked/pasted/dropped content into a staging dir and enforces limits. Pure local file work.
enum ComposerAttachmentStager {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ComposerStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stage(data: Data, filename: String, type: UTType?) throws -> ComposerAttachment {
        let id = UUID()
        let ext = type?.preferredFilenameExtension ?? (filename as NSString).pathExtension
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext.isEmpty ? "bin" : ext)
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        let kind = ComposerAttachment.Kind(type)
        return ComposerAttachment(id: id, localURL: url, filename: filename, kind: kind, byteCount: Int64(data.count),
                                  thumbnail: kind == .image ? Thumbnailer.jpeg(from: data, maxPixel: 240) : nil)
    }

    static func stage(fileURL: URL) throws -> ComposerAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try stage(data: data, filename: fileURL.lastPathComponent, type: UTType(filenameExtension: fileURL.pathExtension))
    }

    /// Applies 10 × 20MB limits against what is already staged. Returns accepted items + first rejection to toast.
    static func admit(_ incoming: [ComposerAttachment], existing: Int) -> (accepted: [ComposerAttachment], rejection: ComposerAttachmentRejection?) {
        var accepted: [ComposerAttachment] = [], rejection: ComposerAttachmentRejection?
        for item in incoming {
            if item.byteCount > ComposerAttachmentLimits.maxBytes { rejection = rejection ?? .tooLarge(filename: item.filename); discard(item); continue }
            if existing + accepted.count >= ComposerAttachmentLimits.maxPerMessage { rejection = rejection ?? .tooMany(accepted: accepted.count); discard(item); continue }
            accepted.append(item)
        }
        return (accepted, rejection)
    }

    static func discard(_ item: ComposerAttachment) { try? FileManager.default.removeItem(at: item.localURL) }
}

enum Thumbnailer {
    static func jpeg(from data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
    }
}
