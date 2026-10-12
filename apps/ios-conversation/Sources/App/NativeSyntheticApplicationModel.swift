import Foundation
import SwiftUI

#if DEBUG
/// Explicit synthetic test build only. Never installs a Supabase credential or production profile.
@MainActor final class NativeSyntheticApplicationModel: ObservableObject {
    let chat: ConversationFirstModel?
    let fixtureIdentity: String?
    @Published private(set) var ready = false
    @Published private(set) var submitted = false
    @Published private(set) var error: String?
    private var recoveryReadOnly = false
    private var origin: URL?
    private var token: String?
    private var message: String?
    private var context: [ConversationExplicitContext] = []
    init() {
        guard let encoded = ProcessInfo.processInfo.environment["R7_SYNTHETIC_CONNECTION_B64URL"] else { chat = nil; fixtureIdentity = nil; return }
        do {
            var b64 = encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/"); b64 += String(repeating:"=",count:(4-b64.count%4)%4)
            guard let data = Data(base64Encoded:b64),data.count < 8192,let json = try JSONSerialization.jsonObject(with:data) as? [String:Any],json["authentication"] as? String == "explicit_test_fixture_session",json["production_login_verified"] as? Bool == false,
                  let base = json["base_url"] as? String,let url = URL(string:base),url.scheme == "http",url.host == "127.0.0.1",url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,
                  let bearer = json["access_token"] as? String,bearer.range(of:"^[A-Za-z0-9_-]{20,128}$",options:.regularExpression) != nil,
                  let scope = json["scope"] as? [String:String],let server = scope["scope_id"].flatMap(UUID.init(uuidString:)),let profile = scope["profile_id"].flatMap(UUID.init(uuidString:)),let workspace = scope["workspace_id"].flatMap(UUID.init(uuidString:)),
                  let expiry = (json["expires_at"] as? String).flatMap({ Self.fixtureDate($0) }),expiry > Date(),let reality = json["model_reality"] as? String,
                  reality == "injected_synthetic_fixture" || (reality == "provider_unverified" && ProcessInfo.processInfo.environment["R7_AUTHORIZED_REAL_SYNTHETIC"] == "1") else { throw NativeAuthError.invalidConfiguration }
            let partition = AuthenticatedLocalPartition(issuer:"explicit-fixture|"+base+"|"+workspace.uuidString+"|"+textHash(bearer),subject:profile,serverScopeID:server)
            var namespace = partition.namespace, localScope = partition.scope
            if ProcessInfo.processInfo.environment["R9_ORIGINAL_RECOVERY"] == "1" {
                guard json["original_recovery_read_only"] as? Bool == true,
                      json["conversation_id"] as? String == "1138a779-fec9-44e6-8370-7261369355cd",
                      json["run_id"] as? String == "b585c914-1943-4f39-8193-bdd1478d3485" else { throw NativeAuthError.invalidConfiguration }
                namespace = "5f6ec24b3e3805e226af55fee4fb4b56233e58ae90e32e5b019dfa0c2d3b0ce7"
                localScope = DataScope(profileID:UUID(uuidString:"8C1973A9-F7E9-4F2B-8811-8458F522ACF8")!,workspaceID:UUID(uuidString:"0075EB56-D759-4CA6-8AFF-059D1DA27839")!)
                recoveryReadOnly = true; submitted = true
            }
            let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CatpawM-r7-explicit-synthetic").appendingPathComponent(namespace)
            let storeURL = root.appendingPathComponent("synthetic.store")
            if recoveryReadOnly { guard FileManager.default.fileExists(atPath:storeURL.path) else { throw NativeAuthError.invalidConfiguration } }
            let persistence = try SwiftDataPersistence(url:storeURL)
            if recoveryReadOnly {
                let snapshot = try persistence.load(), id = UUID(uuidString:"1138a779-fec9-44e6-8370-7261369355cd")!
                guard snapshot.records[id]?.header.scope == localScope,
                      let journal = snapshot.records[stableID("conversation-first-journal-\(id)")],case .preference(let preference) = journal.payload,
                      let bytes = preference.value.data(using:.utf8) else { throw NativeAuthError.invalidConfiguration }
                let saved = try JSONDecoder().decode(ConversationSession.self,from:bytes)
                guard saved.scope == localScope,saved.conversationID == id,saved.turns.count == 1,
                      saved.turns[0].id == UUID(uuidString:"45ac411b-53e4-4b9f-8455-853a9b089854"),
                      let goal = saved.goals["4ff046dbb2f8165376100f1c218a7779dc140e96b224eb508899c3bae6bad757"],
                      goal.binding?.run_id == UUID(uuidString:"b585c914-1943-4f39-8193-bdd1478d3485"),
                      goal.artifactHistory.contains(where:{$0.version == 1 && $0.contentHash == "c79b6bbae33ed916c0ba5b9bb244cbb096cb6426b6e8ed33d6788ea79eb29c64"}) else { throw NativeAuthError.invalidConfiguration }
            }
            let repo = try Repository(persistence:persistence)
            let configuration = try NativeChatConfiguration(origin:url,localScope:localScope,serverScopeID:server,allowInjectedTestProvider:true,useFrozenFixtureMetadata:true,fixtureExpectedReality:reality)
            let backend = NativeChatHTTPBackend(configuration:configuration,credentials:NativeSyntheticFixtureCredentials(localScope:localScope,token:bearer,expiresAt:expiry))
            chat = ConversationFirstModel(repository:repo,service:ConversationSessionService(repository:repo,backend:backend),scope:localScope)
            origin = url; token = bearer; fixtureIdentity = reality == "provider_unverified" ? "测试身份 fixture · OpenRouter free · synthetic-only" : "测试身份 fixture · injected_synthetic_fixture · 无网络模型"
        } catch { chat = nil; fixtureIdentity = nil; self.error = "明确测试配置未通过验证。" }
    }
    private static func fixtureDate(_ value: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.date(from:value) ?? ISO8601DateFormatter().date(from:value) }
    func loadFrozenCase() async {
        guard !ready, let origin,let token,let chat else { return }
        do {
            var request = URLRequest(url:origin.appendingPathComponent("catpaw/testing/v1/fixture")); request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            let (data,response) = try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,data.count < 40000,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],let cases = object["cases"] as? [[String:Any]],let chosen = cases.first(where:{$0["id"] as? String == "local-report"}),let text = chosen["message"] as? String,let contexts = chosen["context"] as? [[String:String]] else { throw NativeAuthError.invalidResponse }
            message = text; context = try contexts.map { guard let id = $0["id"],let text = $0["text"] else { throw NativeAuthError.invalidResponse }; return .init(id:id,text:text) }
            await chat.start(); submitted = !(chat.session?.turns.isEmpty ?? true); ready = true
        } catch { self.error = "冻结合成案例读取失败；未发送模型请求。" }
    }
    func sendFrozenCase() async {
        guard !recoveryReadOnly,ready,!submitted,let chat,let id = chat.conversationID,let message else { return }; submitted = true
        do { _ = try await chat.service.send(scope:chat.scope,conversationID:id,text:message,operationID:UUID(),context:context); await chat.refresh() }
        catch { self.error = "冻结请求需按原 ID 读回；不会换 ID 重发。"; await chat.refresh() }
    }
}
private struct NativeSyntheticFixtureCredentials: NativeChatSessionCredentials {
    let localScope: DataScope; let token: String; let expiresAt: Date
    func authorization(scope:DataScope) async throws -> String { guard scope == localScope,expiresAt > Date() else { throw NativeAuthError.loginRequired }; return "Bearer "+token }
}
#endif
