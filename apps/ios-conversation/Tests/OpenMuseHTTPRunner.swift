import Foundation

actor DiscardOneRunResponse: GatewayTransport {
    private let underlying = URLSessionGatewayTransport()
    private var discarded = false
    func open(_ request: URLRequest) async throws -> GatewayResponse {
        let response = try await underlying.open(request)
        if !discarded, request.httpMethod == "POST", request.url?.lastPathComponent == "runs", (200...201).contains(response.statusCode) {
            discarded = true
            for try await _ in response.chunks { }
            throw CatpawError.unavailable("Client-side fault injection discarded an actual successful HTTP Run response.")
        }
        return response
    }
}
@main struct OpenMuseHTTPRunner {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 5, let origin = URL(string: CommandLine.arguments[2]) else { throw CatpawError.invalid("phase origin client-directory output-json required") }
            let phase = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[3])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repo = try Repository(persistence: FilePersistence(url: root.appendingPathComponent("client-state.json")))
            let transport = OpenMuseFacadeHTTPTransport(configuration: try OpenMuseFacadeConfiguration(baseURL: origin),
                            http: phase == "admit-lost" ? DiscardOneRunResponse() : URLSessionGatewayTransport())
            let service = OpenMuseTaskService(repository: repo, transport: transport)
            let input = OpenMuseTaskInput(scope: Profiles.demo,
                operationID: UUID(uuidString: "33c7a101-1111-4111-8111-111111111111")!,
                businessRunID: UUID(uuidString: "44c7a101-1111-4111-8111-111111111111")!,
                delegationID: UUID(uuidString: "55c7a101-1111-4111-8111-111111111111")!,
                environmentID: UUID(uuidString: "66c7a101-1111-4111-8111-111111111111")!,
                title: "Native synthetic restart preview", goal: "Compare fixed Alpha and Beta records", requirements: "Use fixed synthetic data", stopConditions: ["Stop after one report"], syntheticFixture: .previewUnknown)
            var checks: [String] = []
            func require(_ value: Bool, _ description: String) throws {
                guard value else { throw CatpawError.invalid("FAIL: " + description) }; checks.append(description)
            }
            var session: OpenMuseTaskSession
            if phase == "admit-lost" {
                _ = try await service.prepare(input)
                do { _ = try await service.admit(operationID: input.operationID, scope: input.scope) } catch { }
                session = try await service.session(operationID: input.operationID, scope: input.scope)
                try require(session.admission == .unknown && session.serverTaskID == nil, "actual Run POST response discarded; original durable admission remains unknown")
            } else {
                try await service.recover(scope: input.scope)
                session = try await service.session(operationID: input.operationID, scope: input.scope)
                if phase == "read-receipt" {
                    guard let id = session.approvals.keys.first else { throw CatpawError.missing }
                    session = try await service.reconcileReceipt(operationID: input.operationID, scope: input.scope, proposalID: id)
                    session = try await service.reconcileReceipt(operationID: input.operationID, scope: input.scope, proposalID: id, performEvidenceCheck: true)
                    try require(session.approvals[id]?.state == .unknown && session.approvals[id]?.receipt?.verificationEvidence.contains("synthetic-local-projection:resolved_local") == true,
                                "restarted original unknown receipt resolves local evidence without remote verification or redispatch")
                    do { _ = try await service.decide(try await service.preview(operationID: input.operationID, scope: input.scope, proposalID: id), decision: .approve) } catch { }
                } else {
                    for _ in 0..<60 {
                        session = try await service.refreshUntilStable(operationID: input.operationID, scope: input.scope, maxReads: 3)
                        if session.projection?.status == .waitingApproval { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try require(session.serverTaskID != nil && session.projection?.status == .waitingApproval && !session.artifactHistory.isEmpty,
                                "new Swift client process reads original server Run/task/artifact versions after server restart")
                    guard let id = session.approvals.keys.first else { throw CatpawError.missing }
                    let preview = try await service.preview(operationID: input.operationID, scope: input.scope, proposalID: id)
                    try require(preview.artifact.body.contains("Alpha synthetic record") && preview.snapshot.artifact == preview.artifact.reference && preview.snapshot.toolID == "catpaw.preview",
                                "actual immutable JSON bytes/hash and facade action digest match native approval preview")
                    if phase == "decide-unknown" {
                        session = try await service.decide(preview, decision: .approve)
                        try require(session.approvals[id]?.state == .unknown, "actual pinned ActionService synthetic preview returns unknown")
                        do { _ = try await service.decide(preview, decision: .approve) } catch { }
                    } else { try require(phase == "restore", "recognized read-only restore phase") }
                }
            }
            let trace = await transport.requestTrace()
            try require(!trace.contains(where: { $0.contains("workspace") || $0.contains("/api/") }), "no broad workspace or guessed upstream endpoint")
            let runPosts = trace.filter { $0.hasPrefix("POST ") && $0.hasSuffix("/runs") }.count
            let decisionPosts = trace.filter { $0.hasPrefix("POST ") && $0.hasSuffix("/decisions") }.count
            try require(runPosts == (phase == "admit-lost" ? 1 : 0) && decisionPosts == (phase == "decide-unknown" ? 1 : 0), "only explicit admission/decision phases POST once; recovery never redispatches")
            let result: [String: Any] = ["phase": phase, "checks_passed": checks, "layer": "actual_loopback_HTTP_pinned_TaskWorker_preview_ActionService",
                "cloud_Intelligence_calls": 0, "real_model_calls": 0, "external_writes": 0, "fault": phase == "admit-lost" ? "client-side_discard_after_successful_HTTP_response" : "none",
                "operation_id": input.operationID.uuidString.lowercased(), "business_run_id": input.businessRunID.uuidString.lowercased(), "task_id": session.serverTaskID ?? "unresolved",
                "native_scope": input.scope.workspaceID.uuidString, "remote_synthetic_scope": Profiles.user.workspaceID.uuidString,
                "request_trace": trace, "admission": session.admission.rawValue, "multi_GET_read_budget": 3, "task_status_poll_budget": 60]
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
            print(String(decoding: bytes, as: UTF8.self))
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
