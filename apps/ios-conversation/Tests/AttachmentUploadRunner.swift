import Foundation
// catpaw.chat-attachments.v1 client flow against a scripted transport (no network): create → PUT → complete.
struct UploadTestSession: NativeChatSessionCredentials { func authorization(scope: DataScope) async throws -> String { "Bearer explicit-upload-test-only" } }
actor ScriptedAttachmentTransport: ChatAttachmentTransport {
    struct Call: Sendable { let method: String; let path: String; let host: String; let body: Data? }
    var calls: [Call] = []
    var completeReplies: [(Int, String)] = []
    var createStatus = 201
    var createdIDs: [String] = []
    func setComplete(_ replies: [(Int, String)]) { completeReplies = replies }
    func setCreateStatus(_ status: Int) { createStatus = status }
    func log() -> [Call] { calls }
    nonisolated func send(_ request: URLRequest, body: Data?, progress: (@Sendable (Double) -> Void)?) async throws -> (status: Int, body: Data) {
        try await handle(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body, progress: progress)
    }
    private func handle(method: String, url: URL, headers: [String: String], body: Data?, progress: (@Sendable (Double) -> Void)?) throws -> (status: Int, body: Data) {
        calls.append(.init(method: method, path: url.path, host: url.host ?? "", body: body))
        if url.host == "storage.invalid" {
            guard headers["Authorization"] == nil, headers["Content-Type"] != nil else { return (400, Data()) }
            progress?(0.5); progress?(1); return (200, Data("{}".utf8))
        }
        if url.path.hasSuffix("/attachments"), method == "POST" {
            let input = try JSONSerialization.jsonObject(with: body ?? Data()) as! [String: Any]
            let id = input["attachment_id"] as! String; createdIDs.append(id)
            if createStatus != 201 { return (createStatus, Data("{\"error\":{\"code\":\"image_too_large\"}}".utf8)) }
            let reply: [String: Any] = ["attachment": ["id": id, "state": "pending", "mime_type": input["mime_type"]!, "size_bytes": input["size_bytes"]!, "sha256": input["sha256"]!],
                                        "upload": ["method": "PUT", "url": "https://storage.invalid/upload/sign/chat-attachments/x?token=t", "headers": ["Content-Type": input["mime_type"] as! String, "x-upsert": "false"]]]
            return (201, try JSONSerialization.data(withJSONObject: reply))
        }
        if url.path.hasSuffix("/complete") {
            let id = url.deletingLastPathComponent().lastPathComponent
            let next = completeReplies.isEmpty ? (200, "ready") : completeReplies.removeFirst()
            if next.0 != 200 { return (next.0, Data("{\"error\":{\"code\":\"\(next.1)\"}}".utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: ["attachment": ["id": id, "state": next.1, "width": 10, "height": 10, "reason": "image_hash_mismatch"]]))
        }
        return (404, Data())
    }
}
final class TurnCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var headers: [[String: String]] = []
    static func reset() { bodies = []; headers = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func reply(_ status: Int, _ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func startLoading() {
        let path = request.url?.path ?? ""
        if request.httpMethod == "POST", path.hasSuffix("/turns") {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream { stream.open(); var buffer = [UInt8](repeating: 0, count: 65536); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }; stream.close() }
            Self.bodies.append(body); Self.headers.append(request.allHTTPHeaderFields ?? [:])
            reply(409, ["schema_version": 1, "contract": "catpaw.native-chat.v1", "error": ["code": "attachment_consumed", "retryable": false, "reconciliation_required": false]]); return
        }
        let parts = path.split(separator: "/"), cid = parts.last.map(String.init) ?? "", scope = parts.count > 2 ? String(parts[parts.count - 3]) : ""
        reply(200, ["schema_version": 1, "contract": "catpaw.native-chat.v1", "conversation": ["id": cid, "scope_id": scope, "state": "active", "policy": "conversation-local-output-v1", "revision": 3, "grant_epoch": 1, "messages": []]])
    }
    override func stopLoading() {}
}
actor StateLog { var states: [ChatAttachmentUploadState] = []; func add(_ s: ChatAttachmentUploadState) { states.append(s) }; func all() -> [ChatAttachmentUploadState] { states } }
@main struct AttachmentUploadRunner {
    static func main() async {
        do { try await run() }
        catch { print("FAIL AttachmentUploadRunner: uncaught \(type(of: error)).\(error) — \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        func check(_ condition: Bool, _ text: String) throws { guard condition else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        // Must satisfy production validation: https origin with /functions/v1/<name>, key ^sb_publishable_[A-Za-z0-9_-]{10,}$ (kept under 20 chars so it can never look like a deployment key).
        let configuration = try NativeChatConfiguration(origin: URL(string: "https://api.invalid/functions/v1/catpaw-api")!, localScope: Profiles.user, serverScopeID: Profiles.user.workspaceID, publishableKey: "sb_publishable_test_fixture")
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: UInt8(7), count: 64))
        let transport = ScriptedAttachmentTransport(), states = StateLog()
        let uploader = ChatAttachmentUploader(configuration: configuration, credentials: UploadTestSession(), transport: transport, pause: { _ in })
        let receipt = try await uploader.upload(png, scope: Profiles.user, onState: { state in Task { await states.add(state) } })
        let calls = await transport.log()
        try check(calls.map(\.method) == ["POST", "PUT", "POST"] && calls[0].path.hasSuffix("/attachments") && calls[1].host == "storage.invalid" && calls[2].path.hasSuffix("/complete"), "create → signed PUT (no Authorization) → complete")
        try check(receipt.mimeType == "image/png" && receipt.sizeBytes == png.count && receipt.sha256 == bytesHash(png) && receipt.width == 10, "ready receipt carries exact bytes metadata")
        let message = ChatAttachmentUploader.turnMessage(id: UUID(), text: "看图", attachments: [receipt])
        try check((message["attachment_ids"] as? [String]) == [receipt.id.uuidString.lowercased()], "turn message carries attachment_ids (schema_version 2)")
        try await Task.sleep(nanoseconds: 50_000_000)
        let seen = await states.all()
        try check(seen.contains(.creating) && seen.contains(.uploading(fraction: 0.5)) && seen.contains(.ready(attachmentID: receipt.id)), "progress states reach the UI")
        let retryUpload = try await uploader.upload(png, scope: Profiles.user)
        try check(retryUpload.id != receipt.id, "retry after a failed turn re-uploads under a new id")
        await transport.setComplete([(409, "attachment_upload_missing"), (200, "ready")])
        let late = try await uploader.upload(png, scope: Profiles.user)
        let lateCalls = await transport.log().filter { $0.path.hasSuffix("/complete") }.count
        try check(late.sizeBytes == png.count && lateCalls == 4, "409 attachment_upload_missing retries complete")
        await transport.setComplete([(410, "attachment_expired"), (200, "ready")])
        let before = await transport.createdIDs.count
        let renewed = try await uploader.upload(png, scope: Profiles.user)
        let after = await transport.createdIDs
        try check(after.count == before + 2 && after.last == renewed.id.uuidString.lowercased(), "410 attachment_expired restarts once under a new attachment id")
        await transport.setComplete([(200, "rejected")])
        var rejected = false
        do { _ = try await uploader.upload(png, scope: Profiles.user) } catch ChatAttachmentUploadError.rejected { rejected = true }
        try check(rejected, "rejected upload surfaces a friendly re-select error")
        var unsupported = false
        do { _ = try await uploader.upload(Data("GIF89a".utf8), scope: Profiles.user) } catch ChatAttachmentUploadError.unsupportedType { unsupported = true }
        var tooLarge = false
        do { _ = try await uploader.upload(png + Data(count: ChatAttachmentUploader.maxBytes), scope: Profiles.user) } catch ChatAttachmentUploadError.tooLarge { tooLarge = true }
        try check(unsupported && tooLarge, "client rejects non PNG/JPEG and > 5 MiB before any request")

        // ConversationTurnRequest.attachmentIDs: Codable, survives withHistory, empty → nil.
        let cid = UUID(), userMessage = ConversationTranscriptMessage(id: UUID(), role: .user, content: "看看这张图")
        let plain = ConversationTurnRequest(scope: Profiles.user, conversationID: cid, threadID: nil, operationID: UUID(), epoch: 1, history: [userMessage])
        let withIDs = plain.withAttachmentIDs([receipt.id])
        let decoded = try JSONDecoder().decode(ConversationTurnRequest.self, from: JSONEncoder().encode(withIDs))
        try check(decoded.attachmentIDs == [receipt.id] && withIDs.withHistory([userMessage]).attachmentIDs == [receipt.id] && plain.withAttachmentIDs([]).attachmentIDs == nil, "request carries attachment_ids through Codable and withHistory")
        let legacy = try JSONDecoder().decode(ConversationTurnRequest.self, from: JSONEncoder().encode(plain))
        try check(legacy.attachmentIDs == nil && !legacy.hasUploadedAttachments, "old journals without attachmentIDs still decode")

        // prepare(): schema_version 2 message.attachment_ids, no inline bytes, no tool contracts.
        let policy = URLSessionConfiguration.ephemeral; policy.protocolClasses = [TurnCaptureProtocol.self]
        let backend = NativeChatHTTPBackend(configuration: configuration, credentials: UploadTestSession(), sessionConfiguration: policy)
        TurnCaptureProtocol.reset()
        do { for try await _ in try await backend.reply(withIDs) {} } catch {}
        let sent = try JSONSerialization.jsonObject(with: TurnCaptureProtocol.bodies.first ?? Data("{}".utf8)) as? [String: Any] ?? [:]
        let sentMessage = sent["message"] as? [String: Any] ?? [:]
        try check(sent["schema_version"] as? Int == 2 && (sentMessage["attachment_ids"] as? [String]) == [receipt.id.uuidString.lowercased()] && sentMessage["attachments"] == nil && sentMessage["text"] as? String == "看看这张图", "prepare() posts schema_version 2 message.attachment_ids")
        let sentHeaders = TurnCaptureProtocol.headers.first ?? [:]
        try check(sentHeaders["X-Catpaw-Approval-Contract"] == nil && sentHeaders["X-Catpaw-Memory-Proposal-Contract"] == nil, "attachment turns are not offered tool contracts (server runs image turns without tools)")
        TurnCaptureProtocol.reset()
        do { for try await _ in try await backend.reply(plain) {} } catch {}
        let plainSent = try JSONSerialization.jsonObject(with: TurnCaptureProtocol.bodies.first ?? Data("{}".utf8)) as? [String: Any] ?? [:]
        try check(plainSent["schema_version"] == nil && ((plainSent["message"] as? [String: Any])?["attachment_ids"]) == nil, "plain turns are unchanged")

        // ChatAttachmentSendCoordinator: keep bytes until turn_completed; failed turn → re-upload under NEW ids.
        let coordinator = ChatAttachmentSendCoordinator(uploader: uploader, scope: Profiles.user)
        let creates = await transport.createdIDs.count
        let attached = try await coordinator.attach([png], to: plain)
        let again = try await coordinator.attach([png], to: plain)
        let afterAttach = await transport.createdIDs.count
        try check(attached.attachmentIDs?.count == 1 && again.attachmentIDs == attached.attachmentIDs && afterAttach == creates + 1, "attach uploads once per operation and reuses ready ids")
        let keptBytes = await coordinator.localImages(for: plain.operationID)
        try check(keptBytes == [png], "local bytes kept while the turn runs")
        let retry = ConversationTurnRequest(scope: Profiles.user, conversationID: cid, threadID: nil, operationID: UUID(), epoch: 2, history: [userMessage])
        let reattached = try await coordinator.reattach(after: plain.operationID, to: retry)
        let movedOld = await coordinator.localImages(for: plain.operationID), movedNew = await coordinator.localImages(for: retry.operationID)
        try check(reattached.attachmentIDs?.count == 1 && reattached.attachmentIDs != attached.attachmentIDs && movedOld == nil && movedNew == [png], "failed turn re-uploads the kept bytes under a new id for the retry turn")
        await coordinator.turnCompleted(retry.operationID)
        let dropped = await coordinator.localImages(for: retry.operationID)
        var nothing = false
        do { _ = try await coordinator.reattach(after: retry.operationID, to: plain) } catch ChatAttachmentUploadError.expired { nothing = true }
        try check(dropped == nil && nothing, "turn_completed drops the local bytes; nothing left to re-upload")
    }
}
