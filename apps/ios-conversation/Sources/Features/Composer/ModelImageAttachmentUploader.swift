import Combine
import Foundation
import CatpawImageComposer

/// Real composer attachment transport (#64 / P0-3). Images are handed to the model's `ImageAttachmentDraft`,
/// which transcodes to PNG/JPEG ≤2048 px with metadata stripped (`SystemImageAttachmentEncoder`); the send path
/// then carries the encoded bytes in the chat turn (catpaw.chat-attachments.v1 inline `message.attachments`,
/// gated by `chat_capabilities.image_input` + per-image consent). The server accepts one image per turn, so a
/// second image or a non-image file is refused with a visible reason instead of being silently dropped.
@MainActor final class ModelImageComposerAttachmentUploader: ObservableObject, ComposerAttachmentUploading {
    typealias Update = (_ id: UUID, _ status: ComposerAttachment.Status) -> Bool
    private let update: Update
    private weak var model: ConversationFirstModel?
    private var owner: UUID?
    private var phaseSink: AnyCancellable?

    init(model: ConversationFirstModel, update: @escaping Update) {
        self.model = model
        self.update = update
    }

    func upload(_ attachment: ComposerAttachment) {
        guard attachment.kind == .image else {
            _ = update(attachment.id, .failed(message: ui("暂时只能发送图片")))
            return
        }
        guard let model else { _ = update(attachment.id, .failed(message: "")); return }
        let draft = model.imageDraft
        if let owner, owner != attachment.id {
            _ = update(attachment.id, .failed(message: ui("每条消息只能附一张图片")))
            return
        }
        guard let data = try? Data(contentsOf: attachment.localURL) else {
            _ = update(attachment.id, .failed(message: ui("图片读取失败")))
            return
        }
        owner = attachment.id
        let id = attachment.id
        _ = update(id, .uploading(fraction: 0.1))
        phaseSink = draft.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self, self.owner == id else { return }
            switch phase {
            case .loading: _ = self.update(id, .uploading(fraction: 0.2))
            case .encoding: _ = self.update(id, .uploading(fraction: 0.6))
            case .ready: _ = self.update(id, .uploaded(receiptID: draft.attachment?.id.uuidString.lowercased() ?? id.uuidString))
            case .failed: _ = self.update(id, .failed(message: ui("图片处理失败")))
            case .empty: break
            }
        }
        let ticket = draft.beginSelection()
        draft.receiveSelectedData(data, ticket: ticket)
    }

    private func ui(_ key: String) -> String { AppLanguage(locale: .current).ui(key) }

    func cancel(_ id: UUID) {
        guard owner == id else { return }
        owner = nil; phaseSink = nil
        // After a successful send the model already cleared the draft; clearing again is a no-op.
        model?.imageDraft.clear()
    }
}
