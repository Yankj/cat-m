import Foundation

/// App composition supplies the existing authenticated partition; views receive only the service.
public enum NativeMemoryComposition {
    public static func service(repository:Repository,configuration:NativeChatConfiguration,credentials:any NativeChatSessionCredentials) throws -> ConversationMemoryService {
        guard let subject=configuration.expectedSubjectID else {throw ConversationSessionError.notConfigured}
        let reference=ConversationMemoryReference(scope:configuration.localScope,serverScopeID:configuration.serverScopeID,subjectID:subject)
        return ConversationMemoryService(repository:repository,reference:reference,backend:try NativeMemoryHTTPBackend(configuration:configuration,credentials:credentials))
    }
}
