import Foundation
@main struct LegacyR3Producer {
 static func main() async throws {
  let root = URL(fileURLWithPath:CommandLine.arguments[1]);let repo = try Repository(persistence:FilePersistence(url:root.appendingPathComponent("local-store-r3.json")))
  let service = try WorkspaceService(repository:repo,blobs:BlobStore(root:root.appendingPathComponent("blobs")))
  try await service.bootstrap(scope:Profiles.user)
  let c = try await service.createConversation(scope:Profiles.user,environment:service.environmentID(.local,Profiles.user),project:nil,configuration:ConversationConfiguration(model:"offline",safety:true,subagents:false))
  try await service.saveDraft(scope:Profiles.user,conversationID:c,text:"r3 legacy compatibility synthetic draft")
  try await repo.setPreference(scope:Profiles.user,key:"legacy-compatibility",value:"old-encoder-v1")
  let data = try await repo.exportProfile(scope:Profiles.user);try data.write(to:root.appendingPathComponent("legacy-r3-snapshot.json"))
  let saved = await repo.read(scope:Profiles.user);print("Old r3 encoder: \(saved.records.count) records, sequence \(saved.sequence)")
 }
}
