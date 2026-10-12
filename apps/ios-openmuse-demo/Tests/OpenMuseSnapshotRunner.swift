import Foundation

// External HTTP response replay using bytes captured from our real r2 UI service.
// This is deterministic synthetic replay, not another live TaskWorker or network test.
actor PublicationReplayHTTP: GatewayTransport {
    private let files: [String: Data]
    private var changingReads: Int
    private var runGets = 0
    private var runPosts = 0
    private let corruptArtifact: Bool
    private let wrongScope: Bool
    init(directory: URL, changingReads: Int, corruptArtifact: Bool = false, wrongScope: Bool = false) throws {
        files = try Dictionary(uniqueKeysWithValues: ["capabilities", "delegation", "operation", "run", "artifact"].map { ($0, try Data(contentsOf: directory.appendingPathComponent($0 + ".json"))) })
        self.changingReads = changingReads; self.corruptArtifact = corruptArtifact; self.wrongScope = wrongScope
    }
    func endPublication() { changingReads = 0 }
    func counts() -> (gets: Int, posts: Int) { (runGets, runPosts) }
    private func completedRun(_ name: String, incomplete: Bool = false) throws -> Data {
        var envelope = try JSONSerialization.jsonObject(with: files[name]!) as! [String: Any]
        var run = envelope["run"] as! [String: Any], task = envelope["task"] as! [String: Any]
        run["state"] = incomplete ? "running" : "succeeded"; task["status"] = incomplete ? "running" : "succeeded"
        run["approval_ids"] = [] as [String]
        if incomplete { run["artifact_references"] = [] as [[String: Any]] }
        if wrongScope { run["operation_id"] = "99999999-1111-4111-8111-111111111111" }
        envelope["run"] = run; envelope["task"] = task
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func open(_ request: URLRequest) async throws -> GatewayResponse {
        let path = request.url!.path, method = request.httpMethod!
        let data: Data
        if path.hasSuffix("/capabilities") { data = files["capabilities"]! }
        else if method == "POST", path.hasSuffix("/runs") { runPosts += 1; data = try completedRun("run") }
        else if path.hasSuffix("/delegations") || path.contains("/delegations/") { data = files["delegation"]! }
        else if path.contains("/operations/") { data = try completedRun("operation") }
        else if path.contains("/runs/") {
            runGets += 1
            let incomplete = runGets % 2 == 1 && (runGets + 1) / 2 <= changingReads
            data = try completedRun("run", incomplete: incomplete)
        } else if path.contains("/artifacts/") {
            if corruptArtifact {
                var envelope = try JSONSerialization.jsonObject(with: files["artifact"]!) as! [String: Any]
                var artifact = envelope["artifact"] as! [String: Any]; artifact["body"] = "tampered artifact bytes"; envelope["artifact"] = artifact
                data = try JSONSerialization.data(withJSONObject: envelope)
            } else { data = files["artifact"]! }
        } else { throw CatpawError.invalid("Unexpected replay route " + path) }
        return GatewayResponse(statusCode: method == "POST" ? 201 : 200, chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}

@main struct OpenMuseSnapshotRunner {
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]), fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
            let r = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("run.json"))) as! [String: Any]
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("delegation.json"))) as! [String: Any]
            let run = r["run"] as! [String: Any], delegation = d["delegation"] as! [String: Any]
            let input = OpenMuseTaskInput(scope: Profiles.demo, operationID: UUID(uuidString: run["operation_id"] as! String)!,
                businessRunID: UUID(uuidString: run["id"] as! String)!, delegationID: UUID(uuidString: run["delegation_id"] as! String)!,
                environmentID: UUID(uuidString: "66c7a101-1111-4111-8111-111111111111")!, title: delegation["title"] as! String,
                goal: delegation["goal"] as! String, requirements: delegation["requirements"] as! String,
                stopConditions: delegation["stop_conditions"] as! [String])
            func service(_ name: String, _ peer: PublicationReplayHTTP) throws -> OpenMuseTaskService {
                OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent(name + ".json"))),
                    transport: OpenMuseFacadeHTTPTransport(configuration: try OpenMuseFacadeConfiguration(), http: peer))
            }
            func check(_ value: Bool, _ message: String) throws { guard value else { throw CatpawError.invalid("FAIL: " + message) }; print("PASS: " + message) }
            let racing = try PublicationReplayHTTP(directory: fixtures, changingReads: 1), race = try service("completion", racing)
            _ = try await race.prepare(input); _ = try await race.admit(operationID: input.operationID, scope: input.scope)
            let completed = try await race.refreshUntilStable(operationID: input.operationID, scope: input.scope, maxReads: 3)
            let raceCounts = await racing.counts()
            try check(completed.projection?.status == .succeeded && completed.artifactHistory.count == 1 && !completed.needsRead && raceCounts.gets == 4 && raceCounts.posts == 1,
                "deterministic completion during multi-GET rejects torn references and publishes only the next checked final task/artifact snapshot")
            let endless = try PublicationReplayHTTP(directory: fixtures, changingReads: 99), bounded = try service("bounded", endless)
            _ = try await bounded.prepare(input); _ = try await bounded.admit(operationID: input.operationID, scope: input.scope)
            var exhausted = 0
            do { _ = try await bounded.refreshUntilStable(operationID: input.operationID, scope: input.scope, maxReads: 3) }
            catch let error as OpenMuseReadBudgetExhausted { exhausted = error.attemptedReads }
            let unresolved = try await bounded.session(operationID: input.operationID, scope: input.scope), boundedCounts = await endless.counts()
            try check(exhausted == 3 && boundedCounts.gets == 6 && boundedCounts.posts == 1 && unresolved.needsRead && unresolved.admission == .accepted && unresolved.projection == nil,
                "three changing reads end with explicit recoverable budget error and retained original admission; no spinner or redispatch loop")
            await endless.endPublication()
            let recovered = try await bounded.refreshUntilStable(operationID: input.operationID, scope: input.scope)
            let recoveryCounts = await endless.counts()
            try check(recovered.projection?.status == .succeeded && recoveryCounts.posts == 1,
                "a later explicit original-task read recovers after exhausted budget without another Run POST")
            for scenario in ["hash", "scope"] {
                let bad = try PublicationReplayHTTP(directory: fixtures, changingReads: 0, corruptArtifact: scenario == "hash", wrongScope: scenario == "scope")
                let guarded = try service(scenario, bad)
                _ = try await guarded.prepare(input)
                // Scope corruption also affects create acknowledgement; unknown retains the original request for readback.
                if scenario == "scope" {
                    do { _ = try await guarded.admit(operationID: input.operationID, scope: input.scope) } catch { }
                } else { _ = try await guarded.admit(operationID: input.operationID, scope: input.scope) }
                var failure = false
                do { _ = try await guarded.refreshUntilStable(operationID: input.operationID, scope: input.scope) }
                catch is OpenMuseReadBudgetExhausted { throw CatpawError.invalid("Hash/scope mismatch was incorrectly retried") }
                catch { failure = true }
                let counts = await bad.counts()
                try check(failure && counts.gets == (scenario == "hash" ? 1 : 0) && counts.posts == 1,
                    scenario + " mismatch is a strict failure rather than a retryable snapshot publication race")
            }
            print("layer=synthetic_HTTP_response_replay live_network=0 worker_execution=0 cloud=0 real_model=0")
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
