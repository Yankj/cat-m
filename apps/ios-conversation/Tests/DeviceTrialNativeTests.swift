import XCTest
@testable import CatpawM
final class DeviceTrialNativeTests: XCTestCase {
 @MainActor func testP0ConversationSelectionCannotMoveMarkedDraftToAnotherConversation() async throws {
  let (model,_,service,_)=try makeP0Model();await model.start();let original=model.conversationID,other=try await service.create(scope:Profiles.user)
  model.editDraft("Synthetic composing draft");model.updateInputComposition(true)
  do { try await model.select(other);XCTFail("Active marked draft cannot switch conversation") } catch ConversationSessionError.busy { }
  model.newConversation();XCTAssertEqual(model.conversationID,original);XCTAssertEqual(model.draft,"Synthetic composing draft");model.updateInputComposition(false);await model.deactivate()
 }

 @MainActor func testP0BackgroundBeforeAdmissionPreservesOriginalPendingIntent() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0LifecycleBackend(),service=ConversationSessionService(repository:repo,backend:backend),model=ConversationFirstModel(repository:repo,service:service)
  await model.start();await backend.holdReadiness();model.editDraft("Synthetic held before admission");model.prepareSend();let original=try XCTUnwrap(model.outgoingMessages.first?.id),cid=try XCTUnwrap(model.conversationID)
  try await p0Until { model.sending && !model.enqueueing };await model.suspend();await backend.releaseReadiness()
  let queue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid)
  try await p0Until { let state=try await queue.state();return state.inflight == nil && state.pending.first?.id == original }
  let state=try await queue.state(),counts=await backend.counts();XCTAssertEqual(counts[0],0);XCTAssertEqual(state.pending.first?.text,"Synthetic held before admission");XCTAssertTrue(state.paused);await model.deactivate()
 }

 @MainActor func testP0DeactivateClosesAdmissionBeforeLateForegroundTask() async throws {
  let (model,backend,service,_)=try makeP0Model();model.setNetworkAdmissionAllowed(false);await model.start();let id=try XCTUnwrap(model.conversationID)
  model.editDraft("Synthetic queued before logout");model.prepareSend();try await p0Until { !model.enqueueing }
  model.setNetworkAdmissionAllowed(true);await model.deactivate();await Task.yield()
  let counts=await backend.counts();XCTAssertEqual(counts[0],0);XCTAssertFalse(model.loaded);XCTAssertFalse(model.networkAdmissionAllowed)
  let saved=try await service.read(scope:Profiles.user,conversationID:id);XCTAssertTrue(saved.turns.isEmpty)
 }

 @MainActor func testP0ExistingLocalConversationAppearsWhileAuthValidationIsHeld() async throws {
  let issuer="https://abcdefghijklmnopqrst.supabase.co/auth/v1",subject=UUID(),scope=UUID(),vault=AuthTestStorage(),remote=NativeAuthBoundaryRemote(issuer:issuer,subject:subject)
  let config=try NativeAuthConfiguration(projectURL:URL(string:"https://abcdefghijklmnopqrst.supabase.co")!,publishableKey:"sb_publishable_fixture_public",backendOrigin:URL(string:"https://backend.example.invalid")!,serverScopeID:scope)
  try vault.save(await remote.candidate());let manager=NativeAuthSessionManager(configuration:config,remote:remote,vault:vault,barrier:vault)
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("P0-local-start-"+UUID().uuidString),receipt=LocalConversationReceipt(issuer:issuer,subject:subject,serverScopeID:scope),partition=AuthenticatedLocalPartition(issuer:issuer,subject:subject,serverScopeID:scope)
  let repo=try Repository(persistence:SwiftDataPersistence(url:root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store"))),service=ConversationSessionService(repository:repo),id=try await service.openLatest(scope:partition.scope)
  try await service.saveDraft(scope:partition.scope,conversationID:id,text:"Existing local draft")
  try JSONEncoder().encode(receipt).write(to:root.appendingPathComponent("last-local-workspace.json"),options:.atomic)
  let app=NativeAuthApplicationModel(configuration:config,manager:manager,vault:vault,barrier:vault,root:root),start=Task { await app.start() }
  try await p0Until { await remote.pendingUser() }
  let chat=try XCTUnwrap(app.chat);XCTAssertTrue(chat.loaded);XCTAssertEqual(chat.conversationID,id);XCTAssertEqual(chat.draft,"Existing local draft");XCTAssertFalse(chat.networkAdmissionAllowed)
  do { _=try await manager.authorization(subject:subject);XCTFail("Local receipt cannot authorize HTTP") } catch NativeAuthError.loginRequired { }
  chat.prepareSend();try await p0Until { !chat.enqueueing };XCTAssertTrue(chat.session?.turns.isEmpty == true);XCTAssertEqual(chat.followups.pending.count,1)
  await remote.rejectUser();_ = try? await start.value;try await p0Until { app.chat == nil }
  let preserved=try await service.read(scope:partition.scope,conversationID:id);XCTAssertTrue(preserved.turns.isEmpty)
 }
 func testP0LocalReceiptCannotOpenAnotherSubjectOrAfterLogout() throws {
  let issuer="https://abcdefghijklmnopqrst.supabase.co/auth/v1",subject=UUID(),receipt=LocalConversationReceipt(issuer:issuer,subject:subject,serverScopeID:UUID())
  let candidate=NativeAuthCredential(issuer:issuer,user:.init(id:subject),accessToken:"synthetic.local.signature",refreshToken:"synthetic-local-only",expiresAt:Date())
  XCTAssertNotNil(receipt.partition(candidate:candidate,signedOut:false,expectedIssuer:issuer));XCTAssertNil(receipt.partition(candidate:candidate,signedOut:true,expectedIssuer:issuer))
  let other=NativeAuthCredential(issuer:issuer,user:.init(id:UUID()),accessToken:"synthetic.other.signature",refreshToken:"synthetic-other-only",expiresAt:Date())
  XCTAssertNil(receipt.partition(candidate:other,signedOut:false,expectedIssuer:issuer));XCTAssertNil(receipt.partition(candidate:candidate,signedOut:false,expectedIssuer:"https://other.example.invalid"))
 }
 @MainActor func testP0NativeMarkedTextAndReturnDoNotAccidentallySubmit() {
  let editor=ConversationTextView();var sends=0;editor.submit={sends += 1};editor.text="Draft "
  editor.setMarkedText("nihao",selectedRange:NSRange(location:5,length:0));XCTAssertNotNil(editor.markedTextRange)
  editor.commandSubmit();XCTAssertEqual(sends,0);editor.unmarkText();XCTAssertEqual(sends,0)
  editor.insertText("\n");XCTAssertEqual(sends,0);XCTAssertTrue(editor.text.hasSuffix("\n"));editor.commandSubmit();XCTAssertEqual(sends,1)
 }

 @MainActor func testP0RapidIdenticalSubmissionsKeepIndependentIDsFIFOAndLatestDraft() async throws {
  let (model,backend,service,repo)=try makeP0Model();await model.start()
  model.editDraft("同一内容🐾");model.prepareSend();let first=try XCTUnwrap(model.outgoingMessages.first?.id)
  model.editDraft("同一内容🐾");model.prepareSend();let second=try XCTUnwrap(model.outgoingMessages.last?.id)
  XCTAssertNotEqual(first,second);XCTAssertEqual(model.outgoingMessages.count,2)
  model.editDraft("下一条尚未发送的草稿")
  try await p0Until { await backend.has(first) };try await backend.finish(first,"first")
  try await p0Until { await backend.has(second) };try await backend.finish(second,"second")
  try await p0Until { model.session?.turns.count == 2 && model.session?.turns.allSatisfy({$0.state == .completed}) == true && !model.busy }
  let cid=try XCTUnwrap(model.conversationID),saved=try await service.read(scope:Profiles.user,conversationID:cid)
  XCTAssertEqual(saved.turns.map(\.id),[first,second]);let counts=await backend.counts();XCTAssertEqual(counts[0],2)
  try await model.flushDraft();let record=try await repo.record(cid,scope:Profiles.user)
  XCTAssertEqual(record.conversation?.draftText,"下一条尚未发送的草稿");await model.deactivate()
 }
 @MainActor func testP0FailedLocalAdmissionRollsBackQueueAndDoesNotRequestProvider() async throws {
  let storage=SelectedConversationTestStorage(),repo=try Repository(persistence:storage),backend=P0ScriptedBackend(),service=ConversationSessionService(repository:repo,backend:backend),model=ConversationFirstModel(repository:repo,service:service)
  await model.start();try await model.flushDraft();let before=await repo.read(scope:Profiles.user)
  model.editDraft("保存失败保留原文🐾");storage.rejectNextSave();model.prepareSend()
  XCTAssertEqual(model.outgoingMessages.first?.state,.savingLocal)
  try await p0Until { model.outgoingMessages.first?.state == .failed && !model.enqueueing }
  let after=await repo.read(scope:Profiles.user),counts=await backend.counts()
  XCTAssertEqual(after.sequence,before.sequence);XCTAssertEqual(counts[0],0);XCTAssertEqual(model.draft,"保存失败保留原文🐾");XCTAssertTrue(model.followups.pending.isEmpty);XCTAssertTrue(model.session?.turns.isEmpty == true)
  await model.deactivate()
 }
 @MainActor func testP0CompositionBlocksSubmissionWithoutAlteringDraft() async throws {
  let (model,backend,_,_)=try makeP0Model();await model.start();let text="拼音 nihao\n第二行🐾"
  model.editDraft(text);model.updateInputComposition(true);model.prepareSend()
  XCTAssertFalse(model.canAcceptDraft);XCTAssertEqual(model.draft,text);XCTAssertTrue(model.outgoingMessages.isEmpty)
  let counts=await backend.counts();XCTAssertEqual(counts[0],0)
  model.updateInputComposition(false);XCTAssertTrue(model.canAcceptDraft);await model.deactivate()
 }
 func testP0UserPauseSurvivesBackgroundAndReopen() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),service=ConversationSessionService(repository:repo),cid=try await service.openLatest(scope:Profiles.user)
  let queue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid)
  try await queue.enqueue(.init(text:"Explicit user pause"));try await queue.pause();try await queue.pause(reason:.background);try await queue.resume(backgroundOnly:true)
  let reopened=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid),state=try await reopened.state()
  XCTAssertTrue(state.paused);XCTAssertEqual(state.pauseReason,.user);XCTAssertEqual(state.pending.count,1)
 }
 @MainActor func testP0ForegroundReadsOriginalBeforeSlowReadinessAndResumesPendingOnlyOnce() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0LifecycleBackend(),service=ConversationSessionService(repository:repo,backend:backend),model=ConversationFirstModel(repository:repo,service:service)
  await model.start();model.editDraft("First synthetic turn");model.prepareSend();let first=try XCTUnwrap(model.outgoingMessages.first?.id)
  try await p0Until { await backend.has(first) };model.editDraft("Second queued locally");model.prepareSend()
  let second=try XCTUnwrap(model.outgoingMessages.last?.id);try await p0Until { !model.enqueueing }
  await model.suspend();try await backend.finish(first,"Completed while detached")
  await backend.holdReadiness();await model.resumeForeground()
  try await p0Until { let counts=await backend.counts();return model.session?.turns.first?.state == .completed && counts[1] >= 1 }
  let beforeRelease=await backend.counts();XCTAssertEqual(beforeRelease[0],1)
  await backend.releaseReadiness();try await p0Until("pending turn after original recovery") { await backend.has(second) };try await backend.finish(second,"Queued turn completed")
  try await p0Until { model.session?.turns.count == 2 && model.session?.turns.allSatisfy({$0.state == .completed}) == true && !model.busy }
  let final=await backend.counts();XCTAssertEqual(final[0],2);XCTAssertEqual(model.session?.turns.map(\.id),[first,second]);await model.deactivate()
 }
 @MainActor func testP0RapidSceneEventsKeepLatestForegroundAndInactiveKeepsObserver() async throws {
  let (model,backend,_,_)=try makeP0Model();await model.start();model.editDraft("Synthetic scene race");model.prepareSend();let id=try XCTUnwrap(model.outgoingMessages.first?.id)
  try await p0Until { await backend.has(id) };model.sceneChanged(.inactive)
  try await backend.delta(id,"Inactive event preserves stream")
  try await p0Until { model.session?.messages.contains(where:{$0.content == "Inactive event preserves stream"}) == true }
  XCTAssertEqual(model.observerLifecycle,.streaming)
  model.sceneChanged(.background);model.sceneChanged(.active);model.sceneChanged(.background);model.sceneChanged(.active)
  try await backend.finish(id,"Latest foreground recovered")
  try await p0Until { model.session?.turns.first?.state == .completed && !model.busy }
  XCTAssertEqual(model.observerLifecycle,.foregroundIdle);let counts=await backend.counts();XCTAssertEqual(counts[0],1);await model.deactivate()
 }
 func testStoppedObserverCannotReviveOrClearForegroundReplacement() async throws { try await verifySceneObservationReplacement() }
 func testRegionHeaderOnlyCurrentEdgeAndConfigurable() throws {
  let current = URL(string:"https://dbyklgxdvjbutxzsjeth.supabase.co/functions/v1/catpaw-api")!
  func request(_ url:URL,_ region:String? = nil) throws -> URLRequest { try NativeChatConfiguration(origin:url,localScope:Profiles.user,serverScopeID:UUID(),edgeRegion:region).makeRequest(route:"/readyz",authorization:"Bearer synthetic-region-only") }
  XCTAssertEqual(try request(current).value(forHTTPHeaderField:"x-region"),"us-east-1")
  XCTAssertEqual(try request(current,"eu-central-1").value(forHTTPHeaderField:"x-region"),"eu-central-1")
  XCTAssertEqual(try request(URL(string:current.absoluteString+"/")!).value(forHTTPHeaderField:"x-region"),"us-east-1")
  for url in ["https://backend.example.invalid","https://dbyklgxdvjbutxzsjeth.supabase.co:8443/functions/v1/catpaw-api","http://127.0.0.1:12345","https://dbyklgxdvjbutxzsjeth.supabase.co","https://dbyklgxdvjbutxzsjeth.supabase.co/functions/v1/other-api","https://abcdefghijklmnopqrst.supabase.co/functions/v1/catpaw-api"] {
   XCTAssertNil(try request(URL(string:url)!,"us-west-1").value(forHTTPHeaderField:"x-region"))
  }
  XCTAssertThrowsError(try request(current,"us-east-1\r\nAuthorization: injected"))
  XCTAssertThrowsError(try request(current,""))
 }
 func testOfficialAuthRequestsKeepDefaultRegionRouting() async throws {
  let config = try NativeAuthConfiguration(projectURL:URL(string:"https://dbyklgxdvjbutxzsjeth.supabase.co")!,publishableKey:"sb_publishable_synthetic_region_12345",backendOrigin:URL(string:"https://dbyklgxdvjbutxzsjeth.supabase.co/functions/v1/catpaw-api")!)
  let transport=AuthTestHTTPTransport(id:UUID());await transport.response(anonymous:true)
  let auth=NativeAuthHTTPRemote(configuration:config,transport:transport),session=try await auth.signInAnonymously()
  _ = try await auth.user(accessToken:session.accessToken);_ = try await auth.refresh(refreshToken:session.refreshToken);try await auth.signOut(accessToken:session.accessToken)
  let calls=await transport.captured();XCTAssertEqual(calls.count,4)
  for request in calls { XCTAssertTrue(request.url!.path.hasPrefix("/auth/v1/"));XCTAssertNil(request.value(forHTTPHeaderField:"x-region")) }
 }

 func testSelectedConversationSurvivesDraftUpdatesAndFailedSelectionSave() async throws {
  let store = SelectedConversationTestStorage(),repo = try Repository(persistence:store),service = ConversationSessionService(repository:repo)
  let scope = Profiles.user,a = try await service.create(scope:scope),b = try await service.create(scope:scope)
  try await service.rememberSelection(scope:scope,conversationID:b)
  try await service.saveDraft(scope:scope,conversationID:a,text:"Recent edit to A must not replace selected B")
  let restored = try await service.openLatest(scope:scope);XCTAssertEqual(restored,b)
  let before = await repo.read(scope:scope);store.rejectNextSave()
  do { try await service.rememberSelection(scope:scope,conversationID:a);XCTFail("Failed selection save cannot commit") } catch CatpawError.unavailable { }
  let after = await repo.read(scope:scope);XCTAssertEqual(after.sequence,before.sequence)
  let unchanged = try await service.openLatest(scope:scope);XCTAssertEqual(unchanged,b)
  let foreign = try await service.create(scope:Profiles.demo)
  do { try await service.rememberSelection(scope:scope,conversationID:foreign);XCTFail("A foreign account conversation cannot be selected") } catch CatpawError.scopeMismatch { }
  let other = try await service.openLatest(scope:Profiles.demo);XCTAssertEqual(other,foreign)
 }

 func testAnonymousEntranceRestoreStorageCancellationAndHTTPBoundaries() async throws { try await AnonymousAuthScenarios.run() }
 func testLegacyR3SnapshotRoundTripPreservesRecordsAndScopeInsideSwiftData() throws {
  let resource = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"legacy-r3-snapshot",withExtension:"json")),bytes = try Data(contentsOf:resource)
  let legacy = try JSONDecoder().decode(StoreSnapshot.self,from:bytes)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceTrialLegacy-"+UUID().uuidString)
  let persistence = try SwiftDataPersistence(url:directory.appendingPathComponent("local.store"));try persistence.save(legacy)
  let reopened = try SwiftDataPersistence(url:directory.appendingPathComponent("local.store")).load()
  let e = JSONEncoder();e.outputFormatting = [.sortedKeys]
  XCTAssertEqual(reopened.schemaVersion,1);XCTAssertEqual(reopened.records.count,12);XCTAssertEqual(reopened.sequence,legacy.sequence)
  XCTAssertEqual(Set(reopened.journal.keys),Set(legacy.journal.keys))
  for (id,record) in legacy.records { XCTAssertEqual(try e.encode(reopened.records[id]),try e.encode(record)) }
  for (id,entry) in legacy.journal { XCTAssertEqual(try e.encode(reopened.journal[id]),try e.encode(entry)) }
  XCTAssertEqual(Set(reopened.records.keys),Set(legacy.records.keys))
  let next = AuthenticatedLocalPartition(issuer:"https://dbyklgxdvjbutxzsjeth.supabase.co/auth/v1",subject:UUID(),serverScopeID:UUID())
  XCTAssertFalse(reopened.records.values.contains(where:{$0.header.scope == next.scope}))
  XCTAssertEqual(try Data(contentsOf:resource),bytes)
 }
 func testEdgePrefixAndModernPublicHeaderInsideNativeApp() throws {
  let base = URL(string:"https://dbyklgxdvjbutxzsjeth.supabase.co/functions/v1/catpaw-agent")!,key = "sb_publishable_native_public_fixture_1234567890"
  let config = try NativeChatConfiguration(origin:base,localScope:Profiles.user,serverScopeID:UUID(),publishableKey:key)
  let request = try config.makeRequest(route:"/readyz",authorization:"Bearer native-unit-user-token")
  XCTAssertEqual(request.url?.absoluteString,base.absoluteString+"/readyz");XCTAssertEqual(request.value(forHTTPHeaderField:"apikey"),key);XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer native-unit-user-token")
  XCTAssertThrowsError(try config.makeRequest(route:"//unapproved.example/leak",authorization:"Bearer token"))
  XCTAssertThrowsError(try NativeChatConfiguration(origin:base,localScope:Profiles.user,serverScopeID:UUID(),publishableKey:"sb_secret_never_a_client_key"))
 }
}

private final class SelectedConversationTestStorage: SnapshotPersistence, @unchecked Sendable {
 private let lock = NSLock();private var state = StoreSnapshot();private var reject = false
 func load() throws -> StoreSnapshot { lock.lock();defer { lock.unlock() };return state }
 func rejectNextSave() { lock.lock();reject = true;lock.unlock() }
 func save(_ snapshot:StoreSnapshot) throws { lock.lock();defer { lock.unlock() };if reject { reject = false;throw CatpawError.unavailable("Synthetic selection save rejection") };state = snapshot }
}

@MainActor private func p0Until(_ phase:String = "local lifecycle",_ body:() async throws -> Bool) async throws {
 for _ in 0..<6000 { if try await body() { return };try await Task.sleep(nanoseconds:1_000_000) }
 throw CatpawError.invalid("P0 \(phase) deadline")
}
@MainActor private func makeP0Model() throws -> (ConversationFirstModel,P0ScriptedBackend,ConversationSessionService,Repository) {
 let repository=try Repository(persistence:SelectedConversationTestStorage()),backend=P0ScriptedBackend(),service=ConversationSessionService(repository:repository,backend:backend)
 return (ConversationFirstModel(repository:repository,service:service),backend,service,repository)
}
private actor P0LifecycleBackend: ConversationBackend {
 let backend=P0ScriptedBackend();private var held=false;private var waiters:[CheckedContinuation<Void,Never>]=[]
 func holdReadiness(){held=true}
 func releaseReadiness(){held=false;let old=waiters;waiters=[];for c in old { c.resume() }}
 func connection(scope:DataScope) async -> ConversationConnection { if held { await withCheckedContinuation { waiters.append($0) } };return await backend.connection(scope:scope) }
 func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> { try await backend.reply(request) }
 func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation { try await backend.observe(request) }
 func has(_ id:UUID) async -> Bool { await backend.has(id) }
 func counts() async -> [Int] { await backend.counts() }
 func finish(_ id:UUID,_ text:String) async throws { try await backend.finish(id,text) }
}
