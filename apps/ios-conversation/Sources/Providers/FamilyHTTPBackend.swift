import Foundation

/// catpaw.family.v1 HTTP adapter. Reuses the authenticated session; never retries a POST with a new id.
/// A lost response becomes `outcomeUnknown(command_id)` and is resolved by GET /commands/{id} (api-v1 §5).
public actor FamilyHTTPBackend {
    private let configuration: NativeChatConfiguration
    private let credentials: any NativeChatSessionCredentials
    private let session: URLSession
    public init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials) {
        self.configuration = configuration; self.credentials = credentials
        let policy = URLSessionConfiguration.ephemeral; policy.urlCache = nil; policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: policy)
    }
    public func bootstrap() async throws -> [UUID] {
        struct B: Decodable { let enabled: Bool; let household_ids: [UUID] }
        let b = try JSONDecoder().decode(B.self, from: try await send("/bootstrap"))
        guard b.enabled else { throw FamilyError.unavailable }
        return b.household_ids
    }
    public func ensureHousehold(name: String) async throws -> UUID {
        let cmd = FamilyCommand(type: "household.ensure", household: UUID(), payload: ["name": .string(name)])
        let r = try await command(cmd, path: "/commands")
        guard r.applied, let id = r.objects.first?.id else { throw FamilyError.rejected(r.error?.code ?? "unknown") }
        return id
    }
    public func projection(_ household: UUID, localDate: String?) async throws -> FamilyProjection {
        var route = "/households/\(household.uuidString.lowercased())/projection"
        if let d = localDate { route += "?local_date=\(d)" }
        return try JSONDecoder().decode(FamilyProjection.self, from: try await send(route))
    }
    public func command(_ cmd: FamilyCommand) async throws -> FamilyReceipt {
        try await command(cmd, path: "/households/\(cmd.household_id.uuidString.lowercased())/commands")
    }
    public func receipt(_ id: UUID) async throws -> FamilyReceipt? {
        struct R: Decodable { let outcome: String }
        let data = try await send("/commands/\(id.uuidString.lowercased())")
        if try JSONDecoder().decode(R.self, from: data).outcome == "not_found" { return nil }
        return try JSONDecoder().decode(FamilyReceipt.self, from: data)
    }
    public func captureText(_ household: UUID, captureID: UUID, text: String) async throws -> FamilyCaptureResponse {
        let body = try JSONEncoder().encode(["capture_id": captureID.uuidString.lowercased(), "kind": "text", "text": text])
        return try JSONDecoder().decode(FamilyCaptureResponse.self, from: try await send("/households/\(household.uuidString.lowercased())/captures", body: body))
    }
    public func capturePhoto(_ household: UUID, captureID: UUID, jpeg: Data) async throws -> FamilyCaptureResponse {
        struct Img: Encodable { let mime: String; let data_base64: String }
        struct Body: Encodable { let capture_id: String; let kind: String; let image: Img }
        let body = try JSONEncoder().encode(Body(capture_id: captureID.uuidString.lowercased(), kind: "image", image: Img(mime: "image/jpeg", data_base64: jpeg.base64EncodedString())))
        return try JSONDecoder().decode(FamilyCaptureResponse.self, from: try await send("/households/\(household.uuidString.lowercased())/captures", body: body))
    }

    private func command(_ cmd: FamilyCommand, path: String) async throws -> FamilyReceipt {
        let body = try JSONEncoder().encode(cmd)
        do { return try JSONDecoder().decode(FamilyReceipt.self, from: try await send(path, body: body)) }
        catch let e as URLError where e.code != .cancelled {
            // response lost: ask for the original receipt instead of re-sending under a new id
            if let r = try? await receipt(cmd.command_id) { return r }
            _ = e; throw FamilyError.outcomeUnknown(cmd.command_id)
        }
    }
    private func send(_ route: String, body: Data? = nil) async throws -> Data {
        let authorization = try await credentials.authorization(scope: configuration.localScope)
        var request = try configuration.makeRequest(route: FamilyProtocol.prefix + route, authorization: authorization)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FamilyError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401: await credentials.rejected(scope: configuration.localScope); throw FamilyError.unavailable
        case 404: throw FamilyError.notFound
        case 409, 413, 422:
            struct E: Decodable { struct C: Decodable { let code: String }; let error: C }
            let code = (try? JSONDecoder().decode(E.self, from: data).error.code) ?? "rejected"
            throw http.statusCode == 409 ? FamilyError.conflict(code) : FamilyError.rejected(code)
        default: throw FamilyError.unavailable
        }
    }
}
