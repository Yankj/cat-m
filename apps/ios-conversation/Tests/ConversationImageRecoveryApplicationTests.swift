import Combine
import Foundation
import UIKit
import XCTest
import CatpawImageComposer
@testable import CatpawM

/// Uses real local journals, image vault and recovery entry points; all backend replies are injected.
@MainActor final class ConversationImageRecoveryApplicationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: Repository
        let service: ConversationSessionService
        let model: ConversationFirstModel
        let backend: ImageRecoveryBackend
        let store: FileConversationImageByteStore
        let conversation: UUID
        let operation: UUID
        let packet: PreparedImageAttachment
        let original: ConversationTurnRequest
    }
    private func fixture(format: ImageAttachmentFormat, state: ImageRecoveryBackend.Mode = .notSent,
                         wrongDimensions: Bool = false, hold: ImageRecoveryHeldStore? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-recovery-" + UUID().uuidString)
        let persistence = FilePersistence(url: root.appendingPathComponent("store.json"))
        let repository = try Repository(persistence: persistence), seedBackend = ImageRecoveryBackend(mode: state)
        let service = ConversationSessionService(repository: repository, backend: seedBackend)
        let conversation = try await service.create(scope: Profiles.user), operation = UUID()
        try await service.rememberSelection(scope: Profiles.user, conversationID: conversation)
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 12)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 12))
        }
        let packet = try await SystemImageAttachmentEncoder().encode(raw, id: UUID(), format: format)
        let reference = ConversationVisionReference(receipt: .init(id: packet.id, mimeType: packet.mimeType,
            sha256: packet.sha256, size: packet.encodedData.count, width: packet.width + (wrongDimensions ? 1 : 0), height: packet.height),
            routeHash: textHash("synthetic-recovery-route"), consentRevision: 1)
        let payload = ConversationVisionPayload(reference: reference, bytes: packet.encodedData)
        let store = try FileConversationImageByteStore(root: root.appendingPathComponent("image-bytes"))
        try await store.save(payload, conversationID: conversation, operationID: operation)
        do { _ = try await service.send(scope: Profiles.user, conversationID: conversation,
                    text: "Original image question 🐾", operationID: operation, image: payload)
            XCTFail("Injected incomplete request unexpectedly completed")
        } catch { }
        let seeded = try await service.read(scope: Profiles.user, conversationID: conversation)
        let original = try XCTUnwrap(seeded.turns.last?.request)
        let coldRepository = try Repository(persistence: persistence), backend = ImageRecoveryBackend(mode: state)
        let coldService = ConversationSessionService(repository: coldRepository, backend: backend)
        if let hold { await hold.configure(store) }
        let model = ConversationFirstModel(repository: coldRepository, service: coldService,
            imageStore: hold.map { $0 as any ConversationImageByteStore } ?? store)
        return .init(root: root, repository: coldRepository, service: coldService, model: model,
            backend: backend, store: store, conversation: conversation, operation: operation, packet: packet, original: original)
    }
    private func waitForImage(_ model: ConversationFirstModel) async throws -> PreparedImageAttachment {
        let ready = expectation(description: "Original frozen image restored")
        var received: PreparedImageAttachment?
        let subscription = model.imageDraft.$attachment.compactMap { $0 }.prefix(1).sink { received = $0; ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3); withExtendedLifetime(subscription) { }
        return try XCTUnwrap(received)
    }
    private func finish(_ f: Fixture) async {
        _ = await f.model.deactivate(); try? FileManager.default.removeItem(at: f.root)
    }
    func testColdNotSentJPEGAndPNGRestoreOriginalBytesWithoutConsentOrSending() async throws {
        for format in [ImageAttachmentFormat.jpeg, .png] {
            let f = try await fixture(format: format)
            await f.model.start()
            let restored = try await waitForImage(f.model)
            XCTAssertEqual(restored.id, f.packet.id); XCTAssertEqual(restored.mimeType, f.packet.mimeType)
            XCTAssertEqual(restored.sha256, f.packet.sha256); XCTAssertEqual(restored.encodedData, f.packet.encodedData)
            XCTAssertEqual(f.model.draft, "Original image question 🐾"); XCTAssertEqual(f.model.imageDraft.phase, .ready)
            XCTAssertFalse(f.model.imageGate.imageConsentMatchesCurrentRoute); XCTAssertFalse(f.model.canAcceptDraft)
            XCTAssertNil(f.model.pendingImageConsent)
            let saved = try await f.service.read(scope: Profiles.user, conversationID: f.conversation)
            XCTAssertEqual(saved.turns.count, 1); XCTAssertEqual(saved.turns.last?.id, f.operation)
            XCTAssertEqual(saved.turns.last?.state, .notSent)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(saved.turns.last?.request), try encoder.encode(f.original))
            let vault = try await f.store.read(reference: f.original.image!, conversationID: f.conversation, operationID: f.operation)
            XCTAssertEqual(vault, f.packet.encodedData)
            let counts = await f.backend.counts(); XCTAssertEqual(counts.posts, 0); XCTAssertEqual(counts.grants, 0)
            await finish(f)
        }
    }
    func testUnknownJPEGRecoveryKeepsOriginalOperationAndOnlyObservesIt() async throws {
        let f = try await fixture(format: .jpeg, state: .unknown)
        await f.model.start(); let restored = try await waitForImage(f.model)
        XCTAssertEqual(restored.encodedData, f.packet.encodedData)
        XCTAssertFalse(f.model.imageGate.imageConsentMatchesCurrentRoute); XCTAssertFalse(f.model.canAcceptDraft)
        let saved = try await f.service.read(scope: Profiles.user, conversationID: f.conversation)
        XCTAssertEqual(saved.turns.count, 1); XCTAssertEqual(saved.turns.last?.id, f.operation)
        XCTAssertEqual(saved.turns.last?.state, .unknown); XCTAssertNil(saved.turns.last?.request.imageBytes)
        let counts = await f.backend.counts()
        XCTAssertEqual(counts.posts, 0); XCTAssertEqual(counts.grants, 0)
        XCTAssertTrue(counts.observed.allSatisfy { $0 == f.operation })
        await finish(f)
    }
    func testMismatchedDurableDimensionsFailVisibleWithoutChangingOriginalSnapshot() async throws {
        let f = try await fixture(format: .jpeg, wrongDimensions: true)
        let failed = expectation(description: "Frozen receipt mismatch is reported")
        let subscription = f.model.$error.compactMap { $0 }.filter { $0 == "本机图片读取未完成，原请求已保留。" }.prefix(1).sink { _ in failed.fulfill() }
        await f.model.start(); await fulfillment(of: [failed], timeout: 3); withExtendedLifetime(subscription) { }
        XCTAssertNil(f.model.imageDraft.attachment); XCTAssertFalse(f.model.imageGate.imageConsentMatchesCurrentRoute)
        let saved = try await f.service.read(scope: Profiles.user, conversationID: f.conversation)
        XCTAssertEqual(saved.turns.last?.request.image, f.original.image); XCTAssertEqual(saved.turns.last?.state, .notSent)
        let counts = await f.backend.counts(); XCTAssertEqual(counts.posts, 0); XCTAssertEqual(counts.grants, 0)
        await finish(f)
    }
    func testLateImageVaultReadCannotRestoreOldConversationIntoNewDraft() async throws {
        let hold = ImageRecoveryHeldStore(), f = try await fixture(format: .jpeg, hold: hold)
        let started = expectation(description: "Old conversation vault read held")
        await hold.onRead { started.fulfill() }
        await f.model.start(); await fulfillment(of: [started], timeout: 3)
        let other = try await f.service.create(scope: Profiles.user)
        try await f.model.select(other); f.model.editDraft("Independent B draft 🐾")
        let returned = expectation(description: "Old vault read released")
        await hold.release { returned.fulfill() }
        await fulfillment(of: [returned], timeout: 3)
        // The old read has returned after selection cancelled its task; re-read B's actual journal.
        await f.model.refresh()
        XCTAssertEqual(f.model.conversationID, other); XCTAssertEqual(f.model.draft, "Independent B draft 🐾")
        XCTAssertEqual(f.model.imageDraft.phase, .empty); XCTAssertNil(f.model.imageDraft.attachment)
        let counts = await f.backend.counts(); XCTAssertEqual(counts.posts, 0); XCTAssertEqual(counts.grants, 0)
        await finish(f)
    }
}

private actor ImageRecoveryBackend: ConversationBackend {
    enum Mode: Sendable { case notSent, unknown }
    private let mode: Mode
    private var posts = 0, grants = 0
    private var observed: [UUID] = []
    init(mode: Mode) { self.mode = mode }
    func counts() -> (posts: Int, grants: Int, observed: [UUID]) { (posts, grants, observed) }
    func connection(scope: DataScope) async -> ConversationConnection {
        .init(state: .providerUnverified, provider: "Injected local image-recovery backend", detail: "No HTTP/Auth/model")
    }
    func imageCapabilities(scope: DataScope, conversationID: UUID) async throws -> ConversationImageCapability {
        .init(available: true, liveTransmissionAvailable: true, routeHash: textHash("synthetic-recovery-route"), state: "injected_offline_only")
    }
    private func events(_ request: ConversationTurnRequest) -> [ConversationTurnEvent] {
        [.init(operationID: request.operationID, epoch: request.epoch, sequence: 1,
            payload: .started(requestHash: textHash("original-" + request.operationID.uuidString), conversationRevision: 1,
                              grantEpoch: 1, attachmentReceipts: request.image.map { [$0.receipt] }))]
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        posts += 1
        if mode == .notSent { throw ConversationDispatchFailure.notSent(reason: "Injected pre-dispatch refusal") }
        return AsyncThrowingStream { continuation in events(request).forEach { continuation.yield($0) }; continuation.finish() }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        observed.append(request.operationID)
        return .init(request: request, events: events(request), requestHash: textHash("original-" + request.operationID.uuidString), grantEpoch: 1)
    }
    func allowImageConsent(scope: DataScope, consent: ConversationImageConsent, nonSensitiveConfirmed: Bool) async throws -> Int {
        grants += 1; throw ConversationSessionError.notConfigured
    }
}

private actor ImageRecoveryHeldStore: ConversationImageByteStore {
    private var store: FileConversationImageByteStore?
    private var started: (@Sendable () -> Void)?
    private var resumed: (@Sendable () -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?
    func configure(_ store: FileConversationImageByteStore) { self.store = store }
    func onRead(_ started: @escaping @Sendable () -> Void) { self.started = started }
    func release(_ resumed: @escaping @Sendable () -> Void) { self.resumed = resumed; waiting?.resume(); waiting = nil }
    func save(_ payload: ConversationVisionPayload, conversationID: UUID, operationID: UUID) async throws {
        try await store!.save(payload, conversationID: conversationID, operationID: operationID)
    }
    func read(reference: ConversationVisionReference, conversationID: UUID, operationID: UUID) async throws -> Data {
        let bytes = try await store!.read(reference: reference, conversationID: conversationID, operationID: operationID)
        await withCheckedContinuation { waiting = $0; started?() }
        resumed?()
        return bytes
    }
    func remove(conversationID: UUID, operationID: UUID) async throws {
        try await store!.remove(conversationID: conversationID, operationID: operationID)
    }
}
