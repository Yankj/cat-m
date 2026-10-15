import Foundation
import Combine

public enum ImageAttachmentPhase: Equatable, Sendable {
    case empty, loading, encoding, ready, failed(ImageAttachmentError)
}

/// In-memory, one-image local draft. No networking, persistence, credential or photo-library authority.
@MainActor public final class ImageAttachmentDraft: ObservableObject {
    @Published public private(set) var phase: ImageAttachmentPhase = .empty
    @Published public private(set) var attachment: PreparedImageAttachment?
    private let encoder: any ImageAttachmentEncoding
    private let format: ImageAttachmentFormat
    private let limits: ImageEncodingLimits
    private var epoch = UUID()
    private var selectionID: UUID?
    private var sourceData: Data?
    private var work: Task<Void, Never>?
    public init(encoder: any ImageAttachmentEncoding = SystemImageAttachmentEncoder(),
                format: ImageAttachmentFormat = .png, limits: ImageEncodingLimits = .init()) {
        self.encoder = encoder; self.format = format; self.limits = limits
    }
    public var isProcessing: Bool { phase == .loading || phase == .encoding }
    public var canRetry: Bool {
        if case .failed = phase { return sourceData != nil }
        return false
    }
    public var isShowingRetainedAttachment: Bool { attachment != nil && phase != .ready }

    /// A ticket fences old PhotosPicker/iCloud completions. Original prepared preview stays visible.
    @discardableResult public func beginSelection() -> UUID {
        work?.cancel(); epoch = UUID(); selectionID = UUID(); sourceData = nil; phase = .loading
        return epoch
    }
    public func receiveSelectedData(_ data: Data, ticket: UUID) {
        guard ticket == epoch, phase == .loading else { return }
        guard data.count <= limits.maxInputBytes else { phase = .failed(.inputTooLarge); return }
        sourceData = data; launch()
    }
    public func selectionFailed(ticket: UUID) {
        guard ticket == epoch, phase == .loading else { return }
        phase = .failed(.selectionUnavailable)
    }
    public func retryEncoding() {
        guard canRetry else { return }
        work?.cancel(); epoch = UUID(); launch()
    }
    public func cancelProcessing() {
        guard isProcessing else { return }
        work?.cancel(); epoch = UUID(); phase = .failed(.cancelled)
    }
    /// A picker owns only its pending library read. Once bytes are accepted,
    /// encoding belongs to this draft and its scope, not to a presentation view.
    public func cancelPendingSelection(ticket:UUID) {
        guard ticket==epoch,phase == .loading else {return}
        cancelProcessing()
    }
    /// Call on remove, scope/account/conversation change or after the host freezes its own send snapshot.
    public func clear() {
        work?.cancel(); work = nil; epoch = UUID(); selectionID = nil
        sourceData = nil; attachment = nil; phase = .empty
    }
    /// Host restoration accepts only a packet already validated by the local encoder.
    /// It does not grant transmission authority or resume a business request.
    public func restorePrepared(_ value:PreparedImageAttachment) {
        clear();selectionID=value.id;attachment=value;phase = .ready
    }
    public func sendBlock(caption: String, messageID: UUID, gate: ImageSendGate = .unavailable) -> ImageSendBlock? {
        guard gate.available && gate.liveTransmissionAvailable else { return .unavailable }
        guard !isProcessing else { return .processing }
        guard phase == .ready, let attachment, attachment.id == selectionID else { return .notPrepared }
        guard gate.textConsentGranted else { return .textConsentRequired }
        guard gate.imageConsentMatchesCurrentRoute else { return .imageConsentRequired }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .captionRequired }
        guard caption.utf8.count <= 40_000 else { return .captionTooLarge }
        guard attachment.id != messageID else { return .identityCollision }
        return nil
    }
    private func launch() {
        guard let sourceData, let id = selectionID else { return }
        let ticket = epoch, encoder = encoder, format = format, limits = limits
        phase = .encoding
        work = Task { [weak self] in
            do {
                let result = try await encoder.encode(sourceData, id: id, format: format, limits: limits)
                guard let self, self.epoch == ticket else { return }
                self.attachment = result; self.sourceData = nil; self.phase = .ready
            } catch {
                guard let self, self.epoch == ticket else { return }
                self.phase = .failed(error is CancellationError ? .cancelled : (error as? ImageAttachmentError ?? .encodingFailed))
            }
        }
    }
    // Internal synchronization for deterministic synthetic tests, not a product waiting policy.
    func waitForCurrentWork() async { await work?.value }
    deinit { work?.cancel() }
}
