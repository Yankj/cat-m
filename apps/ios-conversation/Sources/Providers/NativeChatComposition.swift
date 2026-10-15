import Foundation

/// Deployment values are public and must be provisioned by the backend owner.
/// No endpoint, project reference, JWT, owner or model configuration is inferred.
public struct NativeChatComposition {
    public let backend: any ConversationBackend
    public let loginSession: SupabaseUserAccessSession?
    public static func make(publicConfiguration: [String: String], localScope: DataScope) throws -> NativeChatComposition {
        let keys = ["CatpawBackendOrigin", "CatpawSupabaseProjectURL", "CatpawServerScopeID"]
        if keys.allSatisfy({ publicConfiguration[$0] == nil }) { return NativeChatComposition(backend: UnconfiguredConversationBackend(), loginSession: nil) }
        guard let originText = publicConfiguration[keys[0]], let origin = URL(string: originText), let projectText = publicConfiguration[keys[1]], let project = URL(string: projectText), let scopeText = publicConfiguration[keys[2]], let serverScope = UUID(uuidString: scopeText) else { throw CatpawError.invalid("后台公开配置不完整；需要已核实的 origin、Supabase 项目和 scope。") }
        let session = try SupabaseUserAccessSession(projectURL: project, localScope: localScope)
        let configuration = try NativeChatConfiguration(origin: origin, localScope: localScope, serverScopeID: serverScope)
        return NativeChatComposition(backend: NativeChatHTTPBackend(configuration: configuration, credentials: session), loginSession: session)
    }
    public static func make(bundle: Bundle = .main, localScope: DataScope) throws -> NativeChatComposition {
        let keys = ["CatpawBackendOrigin", "CatpawSupabaseProjectURL", "CatpawServerScopeID"]
        var values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in (bundle.object(forInfoDictionaryKey: key) as? String).map { (key, $0) } })
        #if DEBUG
        // Same Debug-only PUBLIC env fallback as NativeAuthApplicationModel (scheme env / UI-test launchEnvironment).
        if values.values.allSatisfy(\.isEmpty) {
            let env = ProcessInfo.processInfo.environment
            for (key, name) in ["CatpawBackendOrigin": "CATPAW_BACKEND_ORIGIN", "CatpawSupabaseProjectURL": "CATPAW_SUPABASE_PROJECT_URL", "CatpawServerScopeID": "CATPAW_SERVER_SCOPE_ID"] {
                if let value = env[name], !value.isEmpty { values[key] = value }
            }
        }
        #endif
        return try make(publicConfiguration: values, localScope: localScope)
    }
}
