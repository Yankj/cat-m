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
actor StateLog { var states: [ChatAttachmentUploadState] = []; func add(_ s: ChatAttachmentUploadState) { states.append(s) }; func all() -> [ChatAttachmentUploadState] { states } }
@main struct AttachmentUploadRunner {
    static func main() async throws {
        func check(_ condition: Bool, _ text: String) throws { guard condition else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        let configuration = try NativeChatConfiguration(origin: URL(string: "https://api.invalid/functions/v1/catpaw-api")!, localScope: Profiles.user, serverScopeID: Profiles.user.workspaceID, publishableKey: "test-publishable-placeholder")
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
    }
}
