#if DEBUG && canImport(UIKit)
import Foundation
import UIKit
import CatpawImageComposer

/// Explicit in-process QA composition only. No HTTP/Auth/provider, Photos access,
/// upload or send is available. Only permission metadata is exercised by the UI.
@MainActor enum ConversationConsentHandoffFixture {
    static let scenario = "p0-ui-consent-handoff"
    static let caption = "请描述这张本地合成色块图片。\n这段说明仍未发送。"
    private static var instance: (model: ObjectIdentifier, backend: ConsentHandoffBackend)?

    static func make(repository: Repository, root: URL) throws -> ConversationFirstModel {
        guard P0ExperienceFixture.scenario == scenario else { throw ConversationSessionError.notConfigured }
        let backend = ConsentHandoffBackend(scope: Profiles.user)
        let model = ConversationFirstModel(repository: repository,
            service: ConversationSessionService(repository: repository, backend: backend),
            imageStore: try FileConversationImageByteStore(root: root.appendingPathComponent("image-bytes")))
        instance = (ObjectIdentifier(model), backend)
        return model
    }
    /// Bootstrap calls after start(), before publishing the model. Encoding and
    /// capability reads are awaited; no timer or automatic consent action races UI.
    static func prepare(model: ConversationFirstModel) async throws {
        guard P0ExperienceFixture.scenario == scenario, let instance, instance.model == ObjectIdentifier(model),
              model.loaded, let conversation = model.conversationID else { throw ConversationSessionError.invalidEvent }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).pngData { context in
            UIColor(CatpawColors.action).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            UIColor(CatpawColors.userMessageBackground).setFill()
            context.fill(CGRect(x: 16, y: 0, width: 16, height: 24))
        }
        let image = try await SystemImageAttachmentEncoder().encode(bytes, id: stableID("consent-handoff-image:" + conversation.uuidString), format: .png, limits: .init())
        try Task.checkCancellation()
        guard model.loaded, model.conversationID == conversation else { throw CancellationError() }
        await instance.backend.bind(conversation: conversation, previewID: image.id, previewHash: image.sha256)
        model.editDraft(caption); model.imageDraft.restorePrepared(image)
        await model.refreshConnection()
        guard model.loaded, model.conversationID == conversation, model.imageCapability.available,
              model.imageCapability.liveTransmissionAvailable else { throw ConversationSessionError.invalidEvent }
        P0ExperienceProbe.shared.update(model)
    }
}

/// This actor deliberately cannot produce an answer. A surprise Send is counted
/// and rejected rather than accidentally appearing to prove image understanding.
private actor ConsentHandoffBackend: ConversationBackend {
    let scope: DataScope
    private let textRoute = textHash("synthetic consent handoff text route v1")
    private let imageRoute = textHash("synthetic consent handoff image route v1")
    private var conversation: UUID?
    private var previewID: UUID?
    private var previewHash: String?
    private var textGranted = false
    private var imageRevision = 0
    private var imageConsentValue: ConversationImageConsent?
    private var textReads = 0, textAllowAttempts = 0, textAllows = 0
    private var imageReads = 0, imageAllowAttempts = 0, imageAllows = 0, previewMismatches = 0, replyAttempts = 0
    init(scope: DataScope) { self.scope = scope }
    func bind(conversation: UUID, previewID: UUID, previewHash: String) async {
        self.conversation = conversation; self.previewID = previewID; self.previewHash = previewHash
        await publish()
    }
    func connection(scope: DataScope) async -> ConversationConnection {
        .init(state: scope == self.scope ? .providerUnverified : .notConfigured, provider: "Synthetic in-process consent handoff", detail: "No HTTP, Auth, model or image upload")
    }
    func imageCapabilities(scope: DataScope, conversationID: UUID) async throws -> ConversationImageCapability {
        guard scope == self.scope else { throw CatpawError.scopeMismatch }
        return .init(available: true, liveTransmissionAvailable: true, routeHash: imageRoute,
                     state: "synthetic_inprocess_only", detail: "Explicit local consent fixture. Image bytes never leave this process.")
    }
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? {
        guard scope == self.scope, conversationID == conversation else { throw ConversationSessionError.invalidEvent }
        textReads += 1; await publish()
        return textGranted ? nil : textConsent(conversationID)
    }
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws {
        textAllowAttempts += 1; await publish()
        guard scope == self.scope, consent.conversationID == conversation, consent.routeHash == textRoute,
              consent.expectedRevision == 0, !textGranted else { throw ConversationSessionError.invalidEvent }
        textGranted = true; textAllows += 1
        await MainActor.run { P0ExperienceFixture.consentCalls += 1 }
        await publish()
    }
    func imageConsent(scope: DataScope, conversationID: UUID, previewID: UUID, previewHash: String) async throws -> ConversationImageConsent {
        imageReads += 1
        guard scope == self.scope, conversationID == conversation, textGranted,
              previewID == self.previewID, previewHash == self.previewHash else {
            previewMismatches += 1; await publish(); throw ConversationSessionError.invalidEvent
        }
        let value = ConversationImageConsent(id: stableID("consent-handoff-review:" + previewID.uuidString),
            conversationID: conversationID, previewID: previewID, previewHash: previewHash, routeHash: imageRoute,
            expectedRevision: imageRevision, title: "合成图片处理许可",
            body: "这是明确的本机合成测试。图片只是程序生成的两色色块，不含照片、账户或个人资料。此许可与文字许可分别确认；确认后仍需明确点击发送。此夹具没有网络、图片上传或真实模型。",
            confirmation: "我确认这张合成图片不含敏感内容。", allowLabel: "允许本次图片处理", denyLabel: "暂不允许")
        imageConsentValue = value; await publish(); return value
    }
    func allowImageConsent(scope: DataScope, consent: ConversationImageConsent, nonSensitiveConfirmed: Bool) async throws -> Int {
        imageAllowAttempts += 1; await publish()
        guard scope == self.scope, textGranted, nonSensitiveConfirmed, consent == imageConsentValue,
              consent.conversationID == conversation, consent.previewID == previewID, consent.previewHash == previewHash,
              consent.routeHash == imageRoute, consent.expectedRevision == imageRevision, imageRevision == 0 else { throw ConversationSessionError.invalidEvent }
        imageRevision += 1; imageAllows += 1; await publish(); return imageRevision
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        replyAttempts += 1
        await MainActor.run { P0ExperienceFixture.replyCalls += 1 }
        await publish(); throw ConversationSessionError.invalidEvent
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        await MainActor.run { P0ExperienceFixture.observeCalls += 1 }
        throw ConversationSessionError.invalidEvent
    }
    private func textConsent(_ id: UUID) -> ConversationModelConsent {
        .init(conversationID: id, title: "合成文字处理许可",
              body: "这是本机进程内的许可交接测试，不使用真实账户、HTTP 或模型。请先确认文字许可，再独立检查图片许可。允许此对话不会发送图片或提交这段草稿。",
              routeHash: textRoute, expectedRevision: 0)
    }
    private func publish() async {
        let values = ["handoff_text_reads": textReads, "handoff_text_allow_attempts": textAllowAttempts,
                      "handoff_text_allows": textAllows, "handoff_image_reads": imageReads,
                      "handoff_image_allow_attempts": imageAllowAttempts, "handoff_image_allows": imageAllows,
                      "handoff_preview_mismatches": previewMismatches, "handoff_reply_attempts": replyAttempts]
        await MainActor.run { P0ExperienceProbe.shared.recordTaskReviewStats(values) }
    }
}
#endif
