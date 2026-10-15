#if DEBUG
import Foundation

/// Explicit Simulator-only composition. All application/HTTP services are real;
/// the loopback server's account, rows and provider are named synthetic inputs.
@MainActor enum ConversationAcceptedWorkLoopbackFixture {
    static func make(repository:Repository,root:URL) throws -> ConversationFirstModel {
        let raw=ProcessInfo.processInfo.environment["CATPAW_ACCEPTED_WORK_PORT"] ?? "8767"
        guard let port=Int(raw),(1024...65535).contains(port),
              P0ExperienceFixture.scenario?.hasPrefix("p0-ui-accepted-work")==true else {throw ConversationSessionError.notConfigured}
        let subject=UUID(uuidString:"51000000-0000-4000-8000-000000000004")!
        let configuration=try NativeChatConfiguration(origin:URL(string:"http://127.0.0.1:\(port)")!,localScope:Profiles.user,serverScopeID:UUID(uuidString:"51000000-0000-4000-8000-000000000001")!,allowInjectedTestProvider:true,useFrozenFixtureMetadata:true,publishableKey:"sb_publishable_synthetic01",expectedSubjectID:subject)
        let backend=NativeChatHTTPBackend(configuration:configuration,credentials:AcceptedWorkLoopbackCredentials())
        let memory=try NativeMemoryComposition.service(repository:repository,configuration:configuration,credentials:AcceptedWorkLoopbackCredentials())
        return ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:backend),imageStore:try FileConversationImageByteStore(root:root.appendingPathComponent("image-bytes")),taskPlanService:ConversationTaskPlanService(repository:repository,scope:Profiles.user,backend:backend),artifactEditService:ConversationArtifactEditService(repository:repository,scope:Profiles.user,backend:backend),taskActionService:ConversationTaskActionService(repository:repository,scope:Profiles.user,backend:backend),taskControlService:ConversationTaskControlService(repository:repository,scope:Profiles.user,backend:backend),memoryService:memory,subjectID:subject)
    }
}
private struct AcceptedWorkLoopbackCredentials:NativeChatSessionCredentials {
    func authorization(scope:DataScope) async throws -> String {
        guard scope==Profiles.user else {throw CatpawError.scopeMismatch}
        return "Bearer native-wire-offline"
    }
}
#endif
