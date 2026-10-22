import Foundation

/// Development loopback only. No token lookup, remote address input, retry, or startup request.
public struct LocalGatewayService: Sendable {
    public static let modelIDs = ["qwen-beijing", "dots-free", "nemotron-free", "glm-flash"]
    public static let configuration = try! GatewayConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, localSynthetic: true)
    public let repository: Repository
    public let blobs: BlobStore
    private let transport: any GatewayTransport
    public init(repository: Repository, blobs: BlobStore, transport: any GatewayTransport = URLSessionGatewayTransport()) {
        self.repository = repository; self.blobs = blobs; self.transport = transport
    }
    private struct Capabilities: Decodable { let mode: String; let real_model_calls: String }
    public func probe() async throws {
        let data = try await get("v1/capabilities")
        let status = try JSONDecoder().decode(Capabilities.self, from: data)
        guard status.mode == "local_synthetic", status.real_model_calls == "disabled" else { throw catError.unavailable("This entry requires a local synthetic gateway with real calls disabled.") }
    }
    public func sync(scope: DataScope, environmentID: UUID) async throws -> Bool {
        guard scope == Profiles.demo else { throw catError.scopeMismatch }
        let data = try await get("v1/sync")
        return try await GatewayAssistantImporter(repository: repository, blobs: blobs).apply(data, expectedScope: scope, environmentID: environmentID)
    }
    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: Self.configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"; request.setValue("synthetic-only", forHTTPHeaderField: "X-Catpaw-Demo")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.open(request)
        guard response.statusCode == 200 else { throw catError.unavailable("Local gateway HTTP \(response.statusCode).") }
        var data = Data()
        for try await chunk in response.chunks {
            try Task.checkCancellation()
            guard data.count + chunk.count <= 4 * 1024 * 1024 else { throw catError.invalid("Local gateway response exceeds 4 MiB.") }
            data.append(chunk)
        }
        return data
    }
}
