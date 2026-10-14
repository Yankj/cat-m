#if canImport(XCTest)
import Foundation
import XCTest
@testable import CatpawM

private final class PlanWireProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private struct PlanWireCredentials: NativeChatSessionCredentials {
    func authorization(scope: DataScope) async throws -> String { "Bearer explicit-local-plan-fixture" }
}
final class NativeTaskPlanTransportTests: XCTestCase {
    private func fixture() throws -> (NativeChatHTTPBackend, ConversationTaskPlanReference, ConversationTaskPlanContent) {
        let scope = Profiles.user, serverScope = UUID(), conversation = UUID(), run = UUID()
        let bindingObject: [String: Any] = ["scope_id": serverScope.uuidString, "conversation_id": conversation.uuidString, "turn_id": UUID().uuidString, "call_id": "local-plan-call", "delegation_id": UUID().uuidString, "operation_id": UUID().uuidString, "run_id": run.uuidString, "task_id": "local-plan-task", "request_hash": String(repeating: "a", count: 64), "delegation_revision": 1, "grant_epoch": 1, "projection_url": "/catpaw/v1/scopes/\(serverScope.uuidString.lowercased())/runs/\(run.uuidString.lowercased())"]
        let binding = try JSONDecoder().decode(ConversationTaskBinding.self, from: JSONSerialization.data(withJSONObject: bindingObject))
        let content = ConversationTaskPlanContent(title: "Local report", goal: "Summarize supplied fictional data", requirements: "", stopConditions: ["Save only a local report"], steps: ["compose", "save", "verify"].map { ConversationTaskPlanStep(id: $0, title: $0, detail: "") })
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PlanWireProtocol.self]
        return (NativeChatHTTPBackend(configuration: try NativeChatConfiguration(origin: URL(string: "https://plan.example.invalid")!, localScope: scope, serverScopeID: serverScope), credentials: PlanWireCredentials(), sessionConfiguration: configuration), ConversationTaskPlanReference(scope: scope, binding: binding, title: content.title), content)
    }
    private func request(_ content: ConversationTaskPlanContent) throws -> ConversationTaskPlanAmendRequest {
        ConversationTaskPlanAmendRequest(operationID: UUID(), expectedRevision: 1, expectedPlanHash: try content.canonicalHash(), expectedGrantEpoch: 1, content: content)
    }
    func testPlanGETAndAmendmentUsePinnedObjectsAndOriginalOperation() async throws {
        let (backend, reference, content) = try fixture(), amendment = try request(content), hash = try content.canonicalHash()
        var paths: [String] = []
        PlanWireProtocol.handler = { wire in
            paths.append(wire.url!.path)
            XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer explicit-local-plan-fixture")
            XCTAssertEqual(wire.value(forHTTPHeaderField: "Accept"), "application/json")
            if wire.httpMethod == "POST" {
                let bytes = wire.httpBody ?? (wire.httpBodyStream.map { stream -> Data in
                    stream.open(); defer { stream.close() }; var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&chunk, maxLength: chunk.count); if n <= 0 { break }; data.append(contentsOf: chunk.prefix(n)) }; return data
                }) ?? Data()
                XCTAssertEqual(try JSONDecoder().decode(ConversationTaskPlanAmendRequest.self, from: bytes), amendment)
            }
            let plan = ConversationTaskPlanSnapshot(runID: reference.binding.run_id, taskID: reference.binding.task_id, conversationID: reference.binding.conversation_id, acceptedRevision: wire.url!.path.contains("amendments") ? 2 : 1, acceptedPlanHash: hash, appliedRevision: wire.url!.path.contains("amendments") ? 2 : 1, appliedPlanHash: hash, applicationState: .applied, taskStatus: "queued", content: content, appliedContent: content)
            let receipt = wire.url!.path.contains("amendments") ? ConversationTaskPlanAmendment(operationID: amendment.operationID, state: .applied, acceptedRevision: 2, acceptedPlanHash: hash) : nil
            return (200, try JSONEncoder().encode(ConversationTaskPlanEnvelope(plan: plan, amendment: receipt)))
        }
        defer { PlanWireProtocol.handler = nil }
        _ = try await backend.readPlan(reference)
        _ = try await backend.amendPlan(reference, request: amendment)
        _ = try await backend.readAmendment(reference, operationID: amendment.operationID)
        XCTAssertEqual(paths.count, 3)
        XCTAssertTrue(paths.allSatisfy { $0.contains(reference.binding.run_id.uuidString.lowercased()) })
        XCTAssertTrue(paths[2].hasSuffix("/amendments/" + amendment.operationID.uuidString.lowercased()))
        await backend.close()
    }
    func testExplicitRejectionIsDistinctFromUnknownTransportAndMalformedSuccess() async throws {
        let (backend, reference, content) = try fixture(), amendment = try request(content)
        defer { PlanWireProtocol.handler = nil }
        for status in [403, 409, 500] {
            PlanWireProtocol.handler = { _ in (status, Data(#"{"schema_version":1,"error":{"code":"fixture_denied","reconciliation_required":false}}"#.utf8)) }
            do { _ = try await backend.amendPlan(reference, request: amendment); XCTFail("Accepted HTTP \(status)") }
            catch { if status == 403 { XCTAssertTrue(error is ConversationDispatchFailure) }; if status == 409 { if case .conflict? = error as? CatpawError {} else { XCTFail("Expected explicit conflict") } }; if status == 500 { XCTAssertFalse(error is ConversationDispatchFailure); XCTAssertNil(error as? CatpawError) } }
        }
        PlanWireProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        do { _ = try await backend.amendPlan(reference, request: amendment); XCTFail("Transport became accepted") } catch { XCTAssertFalse(error is ConversationDispatchFailure) }
        PlanWireProtocol.handler = { _ in (200, Data(#"{"schema_version":1,"contract":"catpaw.task-plan.v1","plan":{}}"#.utf8)) }
        do { _ = try await backend.amendPlan(reference, request: amendment); XCTFail("Malformed success became accepted") } catch { XCTAssertFalse(error is ConversationDispatchFailure) }
        await backend.close()
    }
    func testCrossScopeIsRejectedBeforeAnyHTTP() async throws {
        let (backend, reference, _) = try fixture()
        var calls = 0; PlanWireProtocol.handler = { _ in calls += 1; return (500, Data()) }; defer { PlanWireProtocol.handler = nil }
        let wrong = ConversationTaskPlanReference(scope: Profiles.demo, binding: reference.binding, title: reference.title)
        do { _ = try await backend.readPlan(wrong); XCTFail("Cross scope read") } catch {}
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference.binding)) as! [String: Any]
        object["scope_id"] = UUID().uuidString
        let foreignBinding = try JSONDecoder().decode(ConversationTaskBinding.self, from: JSONSerialization.data(withJSONObject: object))
        let foreign = ConversationTaskPlanReference(scope: reference.scope, binding: foreignBinding, title: reference.title)
        do { _ = try await backend.readPlan(foreign); XCTFail("Cross server scope read") } catch {}
        XCTAssertEqual(calls, 0); await backend.close()
    }
    func testTwoLongPlanVersionsRemainReadableWithinFiniteWireLimit() async throws {
        let (backend, reference, base) = try fixture()
        var content = base
        content.goal = String(repeating: "文", count: 4000)
        content.requirements = String(repeating: "料", count: 4000)
        content.steps[0] = ConversationTaskPlanStep(id: "compose", title: "compose", detail: String(repeating: "据", count: 4000))
        let hash = try content.canonicalHash(), amendment = try request(content)
        let snapshot = ConversationTaskPlanSnapshot(runID: reference.binding.run_id, taskID: reference.binding.task_id, conversationID: reference.binding.conversation_id, acceptedRevision: 2, acceptedPlanHash: hash, appliedRevision: 2, appliedPlanHash: hash, applicationState: .applied, taskStatus: "queued", content: content, appliedContent: content)
        let envelope = ConversationTaskPlanEnvelope(plan: snapshot, amendment: ConversationTaskPlanAmendment(operationID: amendment.operationID, state: .applied, acceptedRevision: 2, acceptedPlanHash: hash))
        let bytes = try JSONEncoder().encode(envelope)
        XCTAssertGreaterThan(bytes.count, 65536)
        XCTAssertLessThan(try JSONEncoder().encode(amendment).count, 48000)
        PlanWireProtocol.handler = { _ in (200, bytes) }; defer { PlanWireProtocol.handler = nil }
        let accepted = try await backend.amendPlan(reference, request: amendment)
        let observed = try await backend.readAmendment(reference, operationID: amendment.operationID)
        XCTAssertEqual(accepted.plan, snapshot); XCTAssertEqual(observed.plan, snapshot)
        XCTAssertEqual(accepted.amendment?.operationID, amendment.operationID)
        XCTAssertEqual(observed.amendment?.operationID, amendment.operationID)
        var oversized = bytes; oversized.append(Data(repeating: 32, count: 512001 - bytes.count))
        PlanWireProtocol.handler = { _ in (200, oversized) }
        do { _ = try await backend.readPlan(reference); XCTFail("Oversized wire response was accepted") } catch {}
        await backend.close()
    }
}
#endif
