import XCTest
@testable import CatpawImageComposer

@MainActor final class DraftTests: XCTestCase {
    private var allowed: ImageSendGate {
        .init(available: true, liveTransmissionAvailable: true, textConsentGranted: true, imageConsentMatchesCurrentRoute: true)
    }
    func testPreparationIsLocalAndUnavailableGateAlwaysBlocks() async throws {
        let draft = ImageAttachmentDraft(), ticket = draft.beginSelection()
        XCTAssertEqual(draft.phase, .loading)
        draft.receiveSelectedData(try SyntheticImages.source(), ticket: ticket)
        XCTAssertEqual(draft.phase, .encoding)
        XCTAssertEqual(draft.sendBlock(caption: "合成问题", messageID: UUID(), gate: allowed), .processing)
        await draft.waitForCurrentWork()
        XCTAssertEqual(draft.phase, .ready)
        XCTAssertEqual(draft.sendBlock(caption: "合成问题", messageID: UUID()), .unavailable)
        XCTAssertEqual(draft.sendBlock(caption: "合成问题", messageID: UUID(), gate: .init(available: true)), .unavailable)
        XCTAssertNil(draft.sendBlock(caption: "合成问题", messageID: UUID(), gate: allowed))
    }
    func testConsentCaptionAndAttachmentIdentityAreSeparateGates() async throws {
        let draft = ImageAttachmentDraft(), ticket = draft.beginSelection()
        draft.receiveSelectedData(try SyntheticImages.source(), ticket: ticket); await draft.waitForCurrentWork()
        var gate = allowed; gate.imageConsentMatchesCurrentRoute = false
        XCTAssertEqual(draft.sendBlock(caption: "问题", messageID: UUID(), gate: gate), .imageConsentRequired)
        gate = allowed; gate.textConsentGranted = false
        XCTAssertEqual(draft.sendBlock(caption: "问题", messageID: UUID(), gate: gate), .textConsentRequired)
        XCTAssertEqual(draft.sendBlock(caption: " \n ", messageID: UUID(), gate: allowed), .captionRequired)
        XCTAssertEqual(draft.sendBlock(caption: String(repeating: "a", count: 40_001), messageID: UUID(), gate: allowed), .captionTooLarge)
        XCTAssertEqual(draft.sendBlock(caption: "问题", messageID: draft.attachment!.id, gate: allowed), .identityCollision)
    }
    func testOldPickerCompletionAndErrorCannotReplaceNewSelection() async throws {
        let draft = ImageAttachmentDraft(), old = draft.beginSelection(), current = draft.beginSelection()
        draft.receiveSelectedData(Data("bad".utf8), ticket: old); draft.selectionFailed(ticket: old)
        XCTAssertEqual(draft.phase, .loading)
        draft.receiveSelectedData(try SyntheticImages.source(), ticket: current); await draft.waitForCurrentWork()
        XCTAssertEqual(draft.phase, .ready)
    }
    func testDisappearingPickerCannotCancelAnotherPickerPendingSelection() async throws {
        let draft=ImageAttachmentDraft(),old=draft.beginSelection(),current=draft.beginSelection()
        draft.cancelPendingSelection(ticket:old)
        XCTAssertEqual(draft.phase,.loading)
        draft.receiveSelectedData(try SyntheticImages.source(),ticket:current)
        await draft.waitForCurrentWork()
        XCTAssertEqual(draft.phase,.ready)
        let later=draft.beginSelection()
        draft.cancelPendingSelection(ticket:later)
        XCTAssertEqual(draft.phase,.failed(.cancelled))
        draft.receiveSelectedData(try SyntheticImages.source(),ticket:later)
        XCTAssertEqual(draft.phase,.failed(.cancelled),"A cancelled read cannot deliver its late bytes")
    }
    func testAcceptedEncodingOutlivesPickerPresentationAndRemainsScoped() async throws {
        let template=try await SystemImageAttachmentEncoder().encode(SyntheticImages.source(),id:UUID(),format:.png,limits:.init())
        let encoder=GateEncoder(template:template),draft=ImageAttachmentDraft(encoder:encoder),ticket=draft.beginSelection()
        draft.receiveSelectedData(try SyntheticImages.source(),ticket:ticket)
        let ids=await encoder.started(1)
        draft.cancelPendingSelection(ticket:ticket)
        XCTAssertEqual(draft.phase,.encoding,"The accepting draft owns encoding after the read delivers bytes")
        await encoder.finish(ids[0]);await draft.waitForCurrentWork()
        XCTAssertEqual(draft.phase,.ready);XCTAssertEqual(draft.attachment?.id,ids[0])
        draft.clear();draft.cancelPendingSelection(ticket:ticket)
        XCTAssertEqual(draft.phase,.empty);XCTAssertNil(draft.attachment)
    }
    func testEncodingFailureKeepsPreviousPreviewAndBlocksSilentTextFallback() async throws {
        let draft = ImageAttachmentDraft(), first = draft.beginSelection()
        draft.receiveSelectedData(try SyntheticImages.source(), ticket: first); await draft.waitForCurrentWork()
        let previous = draft.attachment
        let replacement = draft.beginSelection()
        draft.receiveSelectedData(Data("invalid replacement".utf8), ticket: replacement); await draft.waitForCurrentWork()
        XCTAssertEqual(draft.phase, .failed(.unsupportedSource)); XCTAssertTrue(draft.canRetry)
        XCTAssertEqual(draft.attachment, previous); XCTAssertTrue(draft.isShowingRetainedAttachment)
        XCTAssertEqual(draft.sendBlock(caption: "问题", messageID: UUID(), gate: allowed), .notPrepared)
        draft.clear(); XCTAssertEqual(draft.phase, .empty); XCTAssertNil(draft.attachment); XCTAssertFalse(draft.canRetry)
    }
    func testRetryRetainsSourceAndSelectionIdentity() async throws {
        let encoder = FlakyEncoder(), draft = ImageAttachmentDraft(encoder: encoder), ticket = draft.beginSelection()
        draft.receiveSelectedData(try SyntheticImages.source(), ticket: ticket); await draft.waitForCurrentWork()
        XCTAssertEqual(draft.phase, .failed(.encodingFailed)); XCTAssertTrue(draft.canRetry)
        draft.retryEncoding(); await draft.waitForCurrentWork()
        let ids = await encoder.ids
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids.first, ids.last)
        XCTAssertEqual(draft.phase, .ready); XCTAssertFalse(draft.canRetry)
    }
    func testCancelAndScopeClearRejectLateUncancellableEncodingResult() async throws {
        let template = try await SystemImageAttachmentEncoder().encode(SyntheticImages.source(), id: UUID(), format: .png, limits: .init())
        for clear in [false, true] {
            let engine = GateEncoder(template: template), draft = ImageAttachmentDraft(encoder: engine), ticket = draft.beginSelection()
            draft.receiveSelectedData(try SyntheticImages.source(), ticket: ticket)
            let ids = await engine.started(1)
            let action = Task { @MainActor in
                if clear { draft.clear() } else { draft.cancelProcessing() }
                await engine.finish(ids[0]) // Intentionally ignores cancellation in the test seam.
            }
            await draft.waitForCurrentWork(); await action.value
            XCTAssertEqual(draft.phase, clear ? .empty : .failed(.cancelled))
            XCTAssertNil(draft.attachment)
            XCTAssertEqual(draft.canRetry, !clear)
        }
    }
    func testLateOldEncodingCannotOverwriteCompletedReplacement() async throws {
        let template = try await SystemImageAttachmentEncoder().encode(SyntheticImages.source(), id: UUID(), format: .png, limits: .init())
        let engine = GateEncoder(template: template), draft = ImageAttachmentDraft(encoder: engine), first = draft.beginSelection()
        draft.receiveSelectedData(try SyntheticImages.source(), ticket: first)
        let old = await engine.started(1)
        let replacement = Task { @MainActor in
            let ticket = draft.beginSelection()
            draft.receiveSelectedData(try SyntheticImages.source(width: 4, height: 8), ticket: ticket)
            let ids = await engine.started(2)
            await engine.finish(ids[1]); await draft.waitForCurrentWork(); await engine.finish(old[0])
            return ids[1]
        }
        await draft.waitForCurrentWork()
        let latest = try await replacement.value
        XCTAssertEqual(draft.phase, .ready); XCTAssertEqual(draft.attachment?.id, latest)
    }
}
private actor FlakyEncoder: ImageAttachmentEncoding {
    private(set) var ids: [UUID] = []
    func encode(_ data: Data, id: UUID, format: ImageAttachmentFormat, limits: ImageEncodingLimits) async throws -> PreparedImageAttachment {
        ids.append(id)
        if ids.count == 1 { throw ImageAttachmentError.encodingFailed }
        return try await SystemImageAttachmentEncoder().encode(data, id: id, format: format, limits: limits)
    }
}
private actor GateEncoder: ImageAttachmentEncoding {
    let template: PreparedImageAttachment
    var ids: [UUID] = []
    var pending: [UUID: CheckedContinuation<PreparedImageAttachment, Error>] = [:]
    var waiters: [(Int, CheckedContinuation<[UUID], Never>)] = []
    init(template: PreparedImageAttachment) { self.template = template }
    func encode(_ data: Data, id: UUID, format: ImageAttachmentFormat, limits: ImageEncodingLimits) async throws -> PreparedImageAttachment {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation; ids.append(id)
            for (count, waiter) in waiters where ids.count >= count { waiter.resume(returning: ids) }
            waiters.removeAll { ids.count >= $0.0 }
        }
    }
    func started(_ count: Int) async -> [UUID] {
        if ids.count >= count { return ids }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ id: UUID) {
        let image = PreparedImageAttachment(id: id, mimeType: template.mimeType, sha256: template.sha256,
            encodedData: template.encodedData, thumbnailData: template.thumbnailData, width: template.width, height: template.height)
        pending.removeValue(forKey: id)!.resume(returning: image)
    }
}
