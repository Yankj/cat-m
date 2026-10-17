import XCTest
import UIKit
import CatpawImageComposer
@testable import CatpawM
final class DeviceTrialNativeTests: XCTestCase {
 @MainActor func testConversationSwitchPreservesEachImageDraftWithoutReusingApproval() async throws {
  let (model,backend,service,_)=try makeVisionModel();let firstHash=try await selectVisionImage(model)
  let first=try XCTUnwrap(model.conversationID),firstDraft=model.imageDraft,firstImage=try XCTUnwrap(firstDraft.attachment?.id)
  try await approveVisionImage(model);let second=try await service.create(scope:model.scope)
  try await model.select(second);XCTAssertEqual(model.draft,"");XCTAssertEqual(model.imageDraft.phase,.empty)
  model.editDraft("Second independent unsent image caption")
  let raw=UIGraphicsImageRenderer(size:CGSize(width:24,height:12)).pngData{ctx in UIColor.red.setFill();ctx.fill(CGRect(x:0,y:0,width:24,height:12))}
  let ticket=model.imageDraft.beginSelection();model.imageDraft.receiveSelectedData(raw,ticket:ticket)
  try await p0Until {model.imageDraft.phase == .ready};let secondDraft=model.imageDraft,secondHash=try XCTUnwrap(secondDraft.attachment?.sha256)
  try await model.select(first);XCTAssertEqual(model.draft,"Synthetic image caption");XCTAssertTrue(model.imageDraft === firstDraft)
  XCTAssertEqual(model.imageDraft.attachment?.sha256,firstHash);XCTAssertEqual(model.imageDraft.attachment?.id,firstImage)
  XCTAssertFalse(model.imageGate.imageConsentMatchesCurrentRoute);XCTAssertFalse(model.canAcceptDraft)
  try await model.select(second);XCTAssertEqual(model.draft,"Second independent unsent image caption")
  XCTAssertTrue(model.imageDraft === secondDraft);XCTAssertEqual(model.imageDraft.attachment?.sha256,secondHash)
  let counts=await backend.counts();XCTAssertEqual(counts[0],0)
  await model.deactivate();XCTAssertEqual(firstDraft.phase,.empty);XCTAssertEqual(secondDraft.phase,.empty)
 }
 @MainActor func testFailedConversationSwitchKeepsExactTextAndImage() async throws {
  let storage=SelectedConversationTestStorage(),repo=try Repository(persistence:storage),service=ConversationSessionService(repository:repo)
  let model=ConversationFirstModel(repository:repo,service:service);await model.start()
  let first=try XCTUnwrap(model.conversationID),second=try await service.create(scope:model.scope)
  let raw=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).pngData{ctx in UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:16,height:16))}
  let ticket=model.imageDraft.beginSelection();model.imageDraft.receiveSelectedData(raw,ticket:ticket)
  try await p0Until {model.imageDraft.phase == .ready};let original=model.imageDraft,hash=original.attachment?.sha256
  model.editDraft("Unsent draft retained after failed switch");storage.rejectNextSave()
  do {try await model.select(second);XCTFail("Storage rejection must prevent selection")} catch CatpawError.unavailable { }
  XCTAssertEqual(model.conversationID,first);XCTAssertEqual(model.draft,"Unsent draft retained after failed switch")
  XCTAssertTrue(model.imageDraft === original);XCTAssertEqual(model.imageDraft.attachment?.sha256,hash);await model.deactivate()
 }
 @MainActor func testLatePhotoSelectionCannotEnterAnotherConversation() async throws {
  let (model,backend,service,_)=try makeVisionModel();let hash=try await selectVisionImage(model)
  let first=try XCTUnwrap(model.conversationID),original=model.imageDraft,ticket=original.beginSelection()
  let second=try await service.create(scope:model.scope);try await model.select(second)
  let raw=UIGraphicsImageRenderer(size:CGSize(width:32,height:16)).pngData{ctx in UIColor.red.setFill();ctx.fill(CGRect(x:0,y:0,width:32,height:16))}
  original.receiveSelectedData(raw,ticket:ticket);XCTAssertEqual(model.imageDraft.phase,.empty)
  try await model.select(first);XCTAssertEqual(model.imageDraft.attachment?.sha256,hash)
  XCTAssertEqual(model.imageDraft.phase,.failed(.cancelled));XCTAssertFalse(model.canAcceptDraft)
  let counts=await backend.counts();XCTAssertEqual(counts[0],0);await model.deactivate()
 }
 @MainActor func testVisionConsentCancelAndUnconfirmedCheckboxNeverSend() async throws {
  let (model,backend,_,_)=try makeVisionModel();let hash=try await selectVisionImage(model)
  model.requestImageConsent();try await p0Until {model.pendingImageConsent != nil};let consent=try XCTUnwrap(model.pendingImageConsent)
  model.allowPendingImageConsent(consent,confirmed:false);await Task.yield();var counts=await backend.counts();XCTAssertEqual(counts[0],0);XCTAssertEqual(counts[2],0)
  model.cancelImageConsent();model.prepareSend();counts=await backend.counts();XCTAssertEqual(counts[0],0);XCTAssertEqual(model.draft,"Synthetic image caption");XCTAssertEqual(model.imageDraft.attachment?.sha256,hash);XCTAssertFalse(model.canAcceptDraft);await model.deactivate()
 }
 @MainActor func testVisionExactPreviewApprovalV2MetadataAndTerminalReceipt() async throws {
  let (model,backend,service,_)=try makeVisionModel();let hash=try await selectVisionImage(model);try await approveVisionImage(model)
  XCTAssertTrue(model.canAcceptDraft);model.prepareSend();try await p0Until {model.session?.turns.last?.state == .completed && !model.busy}
  let turn=try XCTUnwrap(model.session?.turns.last),image=try XCTUnwrap(turn.request.image),message=try XCTUnwrap(turn.request.history.last)
  XCTAssertEqual(image.receipt.sha256,hash);XCTAssertNotEqual(image.receipt.id,message.id);XCTAssertNotNil(turn.visionProviderReceipt);XCTAssertNil(turn.request.imageBytes)
  let stored=try await service.read(scope:model.scope,conversationID:try XCTUnwrap(model.conversationID));let encoded=try JSONEncoder().encode(stored)
  XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("base64"));let counts=await backend.counts();XCTAssertEqual(counts[0],1);XCTAssertEqual(counts[2],1);XCTAssertEqual(model.draft,"");await model.deactivate()
 }
 @MainActor func testVisionExpiredConsentRefusesPostAndPreservesExactInputAndImage() async throws {
  let (model,backend,_,_)=try makeVisionModel();let hash=try await selectVisionImage(model);try await approveVisionImage(model);await backend.expireConsent()
  model.prepareSend();try await p0Until {model.followups.paused && !model.enqueueing && !model.busy && model.imageDraft.phase == .ready}
  let counts=await backend.counts();XCTAssertEqual(counts[0],0);XCTAssertEqual(model.draft,"Synthetic image caption");XCTAssertEqual(model.imageDraft.attachment?.sha256,hash);XCTAssertEqual(model.session?.turns.last?.state,.notSent);await model.deactivate()
 }
 @MainActor func testVisionLateGrantAfterDraftChangeCannotAuthorizeAnotherVersion() async throws {
  let (model,backend,_,_)=try makeVisionModel();let hash=try await selectVisionImage(model);model.requestImageConsent();try await p0Until {model.pendingImageConsent != nil}
  await backend.holdGrant();model.allowPendingImageConsent(try XCTUnwrap(model.pendingImageConsent),confirmed:true);try await p0Until {await backend.isGrantWaiting()}
  model.editDraft("Changed after review");await backend.releaseGrant();await Task.yield();await Task.yield()
  XCTAssertFalse(model.imageGate.imageConsentMatchesCurrentRoute);XCTAssertEqual(model.draft,"Changed after review");XCTAssertEqual(model.imageDraft.attachment?.sha256,hash);let counts=await backend.counts();XCTAssertEqual(counts[0],0);await model.deactivate()
 }
 @MainActor func testVisionMalformedImageNeverReachesPermissionOrTransport() async throws {
  let (model,backend,_,_)=try makeVisionModel();await model.start();await model.refreshConnection();model.editDraft("Invalid image caption");let ticket=model.imageDraft.beginSelection();model.imageDraft.receiveSelectedData(Data([1,2,3]),ticket:ticket)
  try await p0Until {if case .failed=model.imageDraft.phase{return true};return false};model.requestImageConsent();model.prepareSend()
  let counts=await backend.counts();XCTAssertEqual(counts[0],0);XCTAssertEqual(counts[2],0);XCTAssertEqual(model.draft,"Invalid image caption");await model.deactivate()
 }
 @MainActor func testVisionSaveFailureRollsBackBeforeProviderAndKeepsDraft() async throws {
  let storage=SelectedConversationTestStorage(),backend=VisionFlowTestBackend(),repository=try Repository(persistence:storage),service=ConversationSessionService(repository:repository,backend:backend),model=ConversationFirstModel(repository:repository,service:service)
  print("p0wait stage=vision-1/2 select+approve begin");let hash=try await selectVisionImage(model);try await approveVisionImage(model);print("p0wait stage=vision-1/2 select+approve done");let before=await repository.read(scope:model.scope);storage.rejectNextSave();model.prepareSend();try await p0Until("vision-3 enqueue rollback",state:{await p0State(model)}) {!model.enqueueing}
  let after=await repository.read(scope:model.scope),counts=await backend.counts();XCTAssertEqual(after.sequence,before.sequence);XCTAssertEqual(counts[0],0);XCTAssertEqual(model.draft,"Synthetic image caption");XCTAssertEqual(model.imageDraft.attachment?.sha256,hash);await model.deactivate()
 }
 @MainActor func testVisionUnknownResumesOriginalTurnAfterBackgroundWithoutSecondPost() async throws {
  let (model,backend,service,_)=try makeVisionModel();await backend.setEOF();let hash=try await selectVisionImage(model);try await approveVisionImage(model);model.prepareSend()
  try await p0Until {await backend.counts()[0] == 1};model.setNetworkAdmissionAllowed(false);try await p0Until {model.session?.turns.last?.state == .unknown && !model.busy}
  let original=try XCTUnwrap(model.session?.turns.last?.id),cid=try XCTUnwrap(model.conversationID);await model.suspend();model.setNetworkAdmissionAllowed(true);await model.resumeForeground()
  try await p0Until {model.session?.turns.last?.state == .completed && !model.busy};let counts=await backend.counts()
  XCTAssertEqual(counts[0],1);XCTAssertGreaterThanOrEqual(counts[1],1);XCTAssertEqual(model.session?.turns.last?.id,original);XCTAssertEqual(model.conversationID,cid)
  let stored=try await service.read(scope:model.scope,conversationID:cid);XCTAssertEqual(stored.turns.last?.request.image?.receipt.sha256,hash);XCTAssertEqual(stored.messages.filter{$0.role == .assistant}.count,1);await model.deactivate()
 }
 @MainActor func testVisionWrongProviderReceiptNeverCompletes() async throws {
  let (model,backend,_,_)=try makeVisionModel();await backend.setWrongReceipt();_ = try await selectVisionImage(model);try await approveVisionImage(model);model.prepareSend()
  try await p0Until {await backend.counts()[0] == 1};model.setNetworkAdmissionAllowed(false);try await p0Until {model.session?.turns.last?.state == .unknown && !model.busy}
  XCTAssertNil(model.session?.turns.last?.visionProviderReceipt);XCTAssertFalse(model.session?.messages.last?.complete ?? true);let counts=await backend.counts();XCTAssertEqual(counts[0],1);await model.deactivate()
 }
 @MainActor func testVisionLocalByteVaultSurvivesRestartAndRejectsForeignOperation() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("VisionBytes-"+UUID().uuidString),store=try FileConversationImageByteStore(root:root),encoder=SystemImageAttachmentEncoder()
  let raw=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).pngData{ctx in UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:16,height:16))},packet=try await encoder.encode(raw,id:UUID(),format:.png,limits:.init()),cid=UUID(),operation=UUID()
  let ref=ConversationVisionReference(receipt:.init(id:packet.id,mimeType:packet.mimeType,sha256:packet.sha256,size:packet.encodedData.count,width:packet.width,height:packet.height),routeHash:textHash("Synthetic route"),consentRevision:1)
  try await store.save(.init(reference:ref,bytes:packet.encodedData),conversationID:cid,operationID:operation)
  let reopened=try FileConversationImageByteStore(root:root),bytes=try await reopened.read(reference:ref,conversationID:cid,operationID:operation),normalized=try await encoder.encode(bytes,id:packet.id,format:.png,limits:.init())
  XCTAssertEqual(bytes,packet.encodedData);XCTAssertEqual(normalized.sha256,packet.sha256)
  do {_ = try await reopened.read(reference:ref,conversationID:UUID(),operationID:operation);XCTFail("Foreign operation cannot read image")}catch CatpawError.missing{}
  try await reopened.remove(conversationID:cid,operationID:operation)
 }

 @MainActor func testImageSelectionStaysLocalAndUnavailableGateKeepsCaption() async throws {
  let (model,backend,_,_)=try makeP0Model();await model.start();model.editDraft("Synthetic image question")
  let image=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).pngData {ctx in UIColor.systemBlue.setFill();ctx.fill(CGRect(x:0,y:0,width:16,height:16))}
  let ticket=model.imageDraft.beginSelection();model.imageDraft.receiveSelectedData(image,ticket:ticket)
  try await p0Until {model.imageDraft.phase == .ready}
  let id=model.imageDraft.attachment?.id,hash=model.imageDraft.attachment?.sha256;XCTAssertNotNil(id);XCTAssertNotNil(hash)
  XCTAssertEqual(model.imageSendBlock,.unavailable);let imageID=model.imageDraft.attachment?.id;try await model.select(try XCTUnwrap(model.conversationID));XCTAssertEqual(model.imageDraft.attachment?.id,imageID)
  XCTAssertFalse(model.canAcceptDraft);model.prepareSend()
  XCTAssertEqual(model.draft,"Synthetic image question");XCTAssertEqual(model.imageDraft.attachment?.id,id);XCTAssertTrue(model.outgoingMessages.isEmpty)
  let counts=await backend.counts();XCTAssertEqual(counts[0],0)
  model.imageDraft.clear();XCTAssertTrue(model.canAcceptDraft);await model.deactivate()
 }
 @MainActor func testImageContextChangeRejectsLateSelectionAndDoesNotLeakCaption() async throws {
  let (model,_,service,_)=try makeP0Model();await model.start();let other=try await service.create(scope:Profiles.user),ticket=model.imageDraft.beginSelection()
  try await model.select(other);model.imageDraft.receiveSelectedData(Data([1,2,3]),ticket:ticket)
  XCTAssertEqual(model.imageDraft.phase,.empty);XCTAssertNil(model.imageDraft.attachment);XCTAssertEqual(model.conversationID,other)
  await model.deactivate()
 }
 @MainActor func testImageGateNeverSilentlyFallsBackToTextDuringProcessing() async throws {
  let (model,backend,_,_)=try makeP0Model();await model.start();model.editDraft("Synthetic processing caption");_ = model.imageDraft.beginSelection()
  model.prepareSend();XCTAssertTrue(model.outgoingMessages.isEmpty);XCTAssertEqual(model.draft,"Synthetic processing caption");let counts=await backend.counts();XCTAssertEqual(counts[0],0);await model.deactivate()
 }

 @MainActor func testIncrementalReaderKeepsExactUnicodeAcrossAppendsAndReplacement() {
  let reader=IncrementalConversationTextView(),font=UIFont.systemFont(ofSize:17),prefix="Unicode e\u{301} and \u{1F43E}\n",tail=String(repeating:"Exact \u{4E2D}\u{6587} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\n",count:256)
  reader.apply(prefix,font:font,color:.label);reader.apply(prefix+tail,font:font,color:.label)
  XCTAssertEqual(Data(reader.textStorage.string.utf8),Data((prefix+tail).utf8));XCTAssertEqual(textHash(reader.textStorage.string),textHash(prefix+tail))
  reader.apply("Confirmed final replacement",font:font,color:.label);XCTAssertEqual(reader.textStorage.string,"Confirmed final replacement")
 }
 @MainActor func testIncrementalReaderRetainsSelectionAndReflowsAtAccessibleSize() {
  let reader=IncrementalConversationTextView(),text=String(repeating:"Synthetic readable paragraph.\n",count:64)
  reader.apply(text,font:ConversationTypeScale.font(.large),color:.label);reader.selectedRange=NSRange(location:5,length:12);let initial=reader.measured(320)
  reader.apply(text+"More",font:ConversationTypeScale.font(.large),color:.label);XCTAssertEqual(reader.selectedRange,NSRange(location:5,length:12))
  reader.apply(text+"More",font:ConversationTypeScale.font(.accessibility5),color:.label);let larger=reader.measured(320)
  XCTAssertGreaterThan(larger.height,initial.height);XCTAssertEqual(reader.measured(320),larger);XCTAssertEqual(reader.textStorage.string,text+"More")
 }

 @MainActor func testP0ConversationSelectionCannotMoveMarkedDraftToAnotherConversation() async throws {
  let (model,_,service,_)=try makeP0Model();await model.start();let original=model.conversationID,other=try await service.create(scope:Profiles.user)
  model.editDraft("Synthetic composing draft");model.updateInputComposition(true)
  do { try await model.select(other);XCTFail("Active marked draft cannot switch conversation") } catch ConversationSessionError.busy { }
  model.newConversation();XCTAssertEqual(model.conversationID,original);XCTAssertEqual(model.draft,"Synthetic composing draft");model.updateInputComposition(false)
  // IME fix: the 新对话 tapped while composing is deferred, not dropped — it opens once composition ends.
  for _ in 0..<200 where model.conversationID == original { try await Task.sleep(nanoseconds:10_000_000) }
  XCTAssertNotEqual(model.conversationID,original,"新对话 during marked text opens after the composition ends");await model.deactivate()
 }

 @MainActor func testNewConversationDuringCompositionEndsCompositionAndProceedsWithinGrace() async throws {
  let (model,_,_,_)=try makeP0Model();await model.start();let original=model.conversationID
  var ended=0;ConversationFirstModel.endInputComposition={ended+=1};defer{ConversationFirstModel.endInputComposition=nil}
  let grace=ConversationFirstModel.newConversationCompositionGrace;ConversationFirstModel.newConversationCompositionGrace=0.05;defer{ConversationFirstModel.newConversationCompositionGrace=grace}
  model.editDraft("你");model.updateInputComposition(true)
  model.newConversation();model.newConversation()
  XCTAssertEqual(ended,1,"composition is ended once; a second tap does not queue a second 新对话")
  // The IME never reports the end: the grace fallback still proceeds instead of silently dropping the action.
  for _ in 0..<200 where model.conversationID == original { try await Task.sleep(nanoseconds:10_000_000) }
  XCTAssertNotEqual(model.conversationID,original)
  XCTAssertFalse(model.isInputComposing)
  await model.deactivate()
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
  chat.prepareSend();let original=try XCTUnwrap(chat.outgoingMessages.first)
  let producerQueue=ConversationFollowupQueueService(repository:chat.repository,scope:partition.scope,conversationID:id)
  // Persistence completion and the repository subscription's UI publication
  // are separate events. Observe both naturally; do not force a refresh.
  try await p0Until("original local intent committed and projected") {
   let durable=try await producerQueue.state()
   return !chat.enqueueing && durable.inflight == nil && durable.pending.count == 1 && durable.pending.first?.id == original.id && durable.pending.first?.text == original.text && chat.followups.pending.count == 1 && chat.followups.pending.first?.id == original.id
  }
  XCTAssertEqual(original.text,"Existing local draft");XCTAssertTrue(chat.session?.turns.isEmpty == true);XCTAssertEqual(chat.followups.pending.count,1)
  let storeURL=root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store")
  let cold=try Repository(persistence:SwiftDataPersistence(url:storeURL)),coldQueue=ConversationFollowupQueueService(repository:cold,scope:partition.scope,conversationID:id)
  let persisted=try await coldQueue.state();XCTAssertNil(persisted.inflight);XCTAssertEqual(persisted.pending.map(\.id),[original.id]);XCTAssertEqual(persisted.pending.map(\.text),[original.text])
  let coldSession=try await ConversationSessionService(repository:cold).read(scope:partition.scope,conversationID:id);XCTAssertTrue(coldSession.turns.isEmpty)
  await remote.rejectUser();_ = try? await start.value;try await p0Until { app.chat == nil && !chat.loaded }
  let reopened=try Repository(persistence:SwiftDataPersistence(url:storeURL)),preserved=try await ConversationSessionService(repository:reopened).read(scope:partition.scope,conversationID:id)
  let preservedQueue=try await ConversationFollowupQueueService(repository:reopened,scope:partition.scope,conversationID:id).state()
  XCTAssertTrue(preserved.turns.isEmpty);XCTAssertNil(preservedQueue.inflight);XCTAssertEqual(preservedQueue.pending.map(\.id),[original.id]);XCTAssertEqual(preservedQueue.pending.map(\.text),[original.text])
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
 @MainActor func testP0UnknownKeepsNewDraftUntilOriginalIsRead() async throws {
  let (model,backend,_,_)=try makeP0Model();await model.start()
  model.editDraft("Synthetic original request");model.prepareSend();let original=try XCTUnwrap(model.outgoingMessages.first?.id)
  try await p0Until {await backend.has(original)};await model.suspend()
  try await p0Until {model.session?.unresolved?.state == .unknown && !model.busy}
  model.editDraft("Retained new draft while original is unknown")
  let before=model.outgoingMessages.map(\.id);model.prepareSend()
  XCTAssertFalse(model.canAcceptDraft);XCTAssertEqual(model.draft,"Retained new draft while original is unknown")
  XCTAssertEqual(model.outgoingMessages.map(\.id),before);XCTAssertEqual(model.session?.unresolved?.id,original)
  let counts=await backend.counts();XCTAssertEqual(counts[0],1);await model.deactivate()
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
 /// Follow-up chips used to require `draft.isEmpty && canAcceptDraft` before filling — unsatisfiable, so a tap never sent.
 @MainActor func testFollowUpChipQuickSendFillsEmptyComposerAndIsAcceptedLikeStarter() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0LifecycleBackend(),service=ConversationSessionService(repository:repo,backend:backend)
  let model=ConversationFirstModel(repository:repo,service:service);await model.start()
  XCTAssertTrue(model.draft.isEmpty);XCTAssertFalse(model.draft.isEmpty && model.canAcceptDraft,"the old chip precondition can never hold")
  XCTAssertFalse(model.stageQuickSend(nil));XCTAssertFalse(model.stageQuickSend("   "));XCTAssertFalse(model.stageQuickSend("帮我总结一下",attachmentsEmpty:false))
  XCTAssertTrue(model.draft.isEmpty,"refused quick sends leave the composer untouched")
  XCTAssertTrue(model.stageQuickSend("帮我总结一下"));XCTAssertEqual(model.draft,"帮我总结一下");XCTAssertTrue(model.canAcceptDraft)
  XCTAssertFalse(model.stageQuickSend("另一个建议"),"never overwrites a draft");XCTAssertEqual(model.draft,"帮我总结一下")
  model.prepareSend();XCTAssertTrue(model.draft.isEmpty);XCTAssertEqual(model.outgoingMessages.last?.text,"帮我总结一下")
  await model.deactivate()
 }
 @MainActor func testTextConsentSurvivesPresentationBindingClearAndRejectsDuplicate() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0ExperienceBackend(scenario:"p0-ui-consent"),service=ConversationSessionService(repository:repo,backend:backend)
  let model=ConversationFirstModel(repository:repo,service:service);await model.start();model.editDraft("Owned synthetic permission")
  model.prepareSend();try await p0Until {model.pendingModelConsent != nil}
  let consent=try XCTUnwrap(model.pendingModelConsent);model.pendingModelConsent=nil
  model.allowPendingModelConsent(consent);try await p0Until {model.session?.turns.last?.state == .completed && !model.busy}
  model.allowPendingModelConsent(consent);await Task.yield()
  let counts=await backend.consentInvocationCounts();XCTAssertEqual(counts,[1,1]);await model.deactivate()
 }
 @MainActor func testDeferredConsentCanBeReopenedAndDispatchesOriginalOnce() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0ExperienceBackend(scenario:"p0-ui-consent"),service=ConversationSessionService(repository:repo,backend:backend)
  let model=ConversationFirstModel(repository:repo,service:service);await model.start();model.editDraft("Owned deferred permission")
  model.prepareSend();try await p0Until("deferred-1 first consent",state:{await p0State(model,backend)}) {model.pendingModelConsent != nil}
  model.deferModelConsent(try XCTUnwrap(model.pendingModelConsent));try await p0Until("deferred-2 paused",state:{await p0State(model,backend)}) {model.followups.paused}
  let before=await backend.consentInvocationCounts();XCTAssertEqual(before,[0,0])
  model.requestModelConsentReview();try await p0Until("deferred-3 reopened consent",state:{await p0State(model,backend)}) {model.pendingModelConsent != nil}
  model.allowPendingModelConsent(try XCTUnwrap(model.pendingModelConsent));try await p0Until("deferred-4 completed",state:{await p0State(model,backend)}) {model.session?.turns.last?.state == .completed && !model.busy}
  let after=await backend.consentInvocationCounts();XCTAssertEqual(after,[1,1]);XCTAssertEqual(model.session?.turns.count,1)
  await model.deactivate()
 }
 @MainActor func testChangedConsentRevisionCannotDispatch() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0ExperienceBackend(scenario:"p0-ui-consent"),service=ConversationSessionService(repository:repo,backend:backend)
  let model=ConversationFirstModel(repository:repo,service:service);await model.start();model.editDraft("Owned stale permission")
  model.prepareSend();try await p0Until("changed-1 first consent",state:{await p0State(model,backend)}) {model.pendingModelConsent != nil}
  let review=try XCTUnwrap(model.pendingModelConsent)
  let stale=ConversationModelConsent(conversationID:review.conversationID,title:review.title,body:review.body,routeHash:review.routeHash,expectedRevision:review.expectedRevision+1)
  model.allowPendingModelConsent(stale);await Task.yield()
  let counts=await backend.consentInvocationCounts();XCTAssertEqual(counts,[0,0]);XCTAssertNotNil(model.pendingModelConsent)
  await model.deactivate()
 }
 @MainActor func testColdQueuedPermissionIsPresentedWhileExplicitPauseSurvives() async throws {
  for paused in [false,true] {
   let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=P0ExperienceBackend(scenario:"p0-ui-consent"),service=ConversationSessionService(repository:repo,backend:backend)
   let cid=try await service.create(scope:Profiles.user),queue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid)
   try await queue.enqueue(.init(text:"Owned restored pending"));if paused {try await queue.pause()}
   let model=ConversationFirstModel(repository:repo,service:service);await model.start()
   if paused {try await Task.sleep(nanoseconds:20_000_000);XCTAssertNil(model.pendingModelConsent);XCTAssertTrue(model.followups.paused)}
   else {try await p0Until {model.pendingModelConsent != nil};XCTAssertTrue(model.needsModelConsentReview)}
   let counts=await backend.consentInvocationCounts();XCTAssertEqual(counts,[0,0]);await model.deactivate()
  }
 }
 @MainActor func testReadinessRetriesAreBoundedPublishBeforeImageAndRejectLateAuth() async throws {
  let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=Consent16ReadinessBackend(),service=ConversationSessionService(repository:repo,backend:backend),model=ConversationFirstModel(repository:repo,service:service)
  await model.start();try await p0Until {await backend.waitingForImage()}
  XCTAssertEqual(model.connectionLifecycle,.available);let before=await backend.calls();XCTAssertEqual(before,3)
  model.setNetworkAdmissionAllowed(false);await backend.releaseImage();await Task.yield();await Task.yield()
  XCTAssertFalse(model.networkAdmissionAllowed);XCTAssertEqual(model.connectionLifecycle,.checking)
  let after=await backend.calls();XCTAssertEqual(after,3);await model.deactivate()
 }
 func testReplyEvidenceRequiresValidatedDurableTerminal() async throws {
  for terminal in [true,false] {
   let repo=try Repository(persistence:SelectedConversationTestStorage()),backend=Consent16TerminalBackend(valid:terminal),service=ConversationSessionService(repository:repo,backend:backend)
   let cid=try await service.create(scope:Profiles.user)
   do {_=try await service.send(scope:Profiles.user,conversationID:cid,text:"Owned synthetic terminal",operationID:UUID());XCTAssertTrue(terminal)}
   catch {XCTAssertFalse(terminal)}
   let count=await backend.records(),evidence=await service.recordedReplyEvidence(scope:Profiles.user)
   XCTAssertEqual(count,terminal ? 1 : 0);XCTAssertEqual(evidence != nil,terminal)
   if terminal {XCTAssertNotNil(evidence?.verifiedReplyAt)}
  }
 }

}

private final class SelectedConversationTestStorage: SnapshotPersistence, @unchecked Sendable {
 private let lock = NSLock();private var state = StoreSnapshot();private var reject = false
 func load() throws -> StoreSnapshot { lock.lock();defer { lock.unlock() };return state }
 func rejectNextSave() { lock.lock();reject = true;lock.unlock() }
 func save(_ snapshot:StoreSnapshot) throws { lock.lock();defer { lock.unlock() };if reject { reject = false;throw CatpawError.unavailable("Synthetic selection save rejection") };state = snapshot }
}

/// p89i-4: every wait is named; success prints the stage + wall time, a timeout prints the stage, wall time, iterations and
/// a model state dump so the exact stuck stage is in the log (XCTest output), not just the shared ":416" exit.
@MainActor private func p0Until(_ phase:String = "local lifecycle",state:@MainActor () async -> String = {""},_ body:() async throws -> Bool) async throws {
 let t0=Date()
 for i in 0..<6000 {
  if try await body() { if phase != "local lifecycle" { print("p0wait ok stage=\(phase) iter=\(i) ms=\(Int(Date().timeIntervalSince(t0)*1000))") };return }
  try await Task.sleep(nanoseconds:1_000_000)
 }
 let dump=await state()
 print("p0wait TIMEOUT stage=\(phase) ms=\(Int(Date().timeIntervalSince(t0)*1000)) state=\(dump)")
 throw CatpawError.invalid("P0 \(phase) deadline")
}
@MainActor private func p0State(_ m:ConversationFirstModel,_ b:P0ExperienceBackend? = nil) async -> String {
 let counts=await b?.consentInvocationCounts() ?? []
 return "pendingConsent=\(m.pendingModelConsent != nil) paused=\(m.followups.paused) busy=\(m.busy) enqueueing=\(m.enqueueing) turns=\(m.session?.turns.count ?? -1) last=\(String(describing:m.session?.turns.last?.state)) lifecycle=\(m.connectionLifecycle) admission=\(m.networkAdmissionAllowed) consentCalls=\(counts)"
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

@MainActor private func makeVisionModel() throws -> (ConversationFirstModel,VisionFlowTestBackend,ConversationSessionService,Repository) {
 let repository=try Repository(persistence:SelectedConversationTestStorage()),backend=VisionFlowTestBackend(),service=ConversationSessionService(repository:repository,backend:backend)
 return (ConversationFirstModel(repository:repository,service:service),backend,service,repository)
}
@MainActor private func selectVisionImage(_ model:ConversationFirstModel) async throws -> String {
 await model.start();await model.refreshConnection();model.editDraft("Synthetic image caption")
 let raw=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).pngData{ctx in UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:16,height:16))},ticket=model.imageDraft.beginSelection();model.imageDraft.receiveSelectedData(raw,ticket:ticket)
 try await p0Until("vision-1 image ready",state:{await p0State(model)+" image=\(model.imageDraft.phase)"}) {model.imageDraft.phase == .ready};return try XCTUnwrap(model.imageDraft.attachment?.sha256)
}
@MainActor private func approveVisionImage(_ model:ConversationFirstModel) async throws {
 model.requestImageConsent();try await p0Until("vision-2a image consent shown",state:{await p0State(model)+" imageConsentPending=\(model.pendingImageConsent != nil) checking=\(model.checkingImageConsent)"}) {model.pendingImageConsent != nil};model.allowPendingImageConsent(try XCTUnwrap(model.pendingImageConsent),confirmed:true)
 try await p0Until("vision-2b image consent matches route",state:{await p0State(model)+" matches=\(model.imageGate.imageConsentMatchesCurrentRoute) checking=\(model.checkingImageConsent)"}) {model.imageGate.imageConsentMatchesCurrentRoute && !model.checkingImageConsent}
}
/// Named offline synthetic provider; no URLSession/Auth or actual model request.
private actor VisionFlowTestBackend:ConversationBackend {
 private let route=textHash("P0-only-synthetic-image-route"),body="Synthetic image reply; no real model."
 private var revision=0,posts=0,reads=0,grants=0,eof=false,wrong=false,grantHeld=false,grantWaiting=false
 private var grantWait:CheckedContinuation<Void,Never>?
 private var originals:[UUID:ConversationTurnRequest]=[:]
 func counts()->[Int]{[posts,reads,grants]}
 func expireConsent(){revision += 1}
 func setEOF(){eof=true}
 func setWrongReceipt(){wrong=true}
 func holdGrant(){grantHeld=true}
 func isGrantWaiting()->Bool{grantWaiting}
 func releaseGrant(){grantHeld=false;grantWait?.resume();grantWait=nil}
 func connection(scope:DataScope) async ->ConversationConnection {.init(state:.providerUnverified,provider:"Explicit synthetic offline vision",detail:"No HTTP/Auth/model")}
 func imageCapabilities(scope:DataScope,conversationID:UUID) async throws ->ConversationImageCapability {.init(available:true,liveTransmissionAvailable:true,routeHash:route,state:"injected_synthetic_offline",detail:"No real transmission")}
 func imageConsent(scope:DataScope,conversationID:UUID,previewID:UUID,previewHash:String) async throws ->ConversationImageConsent {
  .init(conversationID:conversationID,previewID:previewID,previewHash:previewHash,routeHash:route,expectedRevision:revision,title:"Synthetic image permission",body:"Offline fixture only; OpenRouter/Google AI Studio, 55 days, possible human review are contract labels; no transmission.",confirmation:"I confirm this synthetic fixture has no sensitive content",allowLabel:"Allow synthetic fixture",denyLabel:"Cancel")
 }
 func allowImageConsent(scope:DataScope,consent:ConversationImageConsent,nonSensitiveConfirmed:Bool) async throws ->Int {
  guard nonSensitiveConfirmed,consent.expectedRevision==revision,consent.routeHash==route else {throw CatpawError.conflict}
  grants += 1
  if grantHeld {grantWaiting=true;await withCheckedContinuation{grantWait=$0}}
  revision += 1;return revision
 }
 private func script(_ r:ConversationTurnRequest,complete:Bool)->[ConversationTurnEvent] {
  let id=stableID("VisionFlowTest-assistant-"+r.operationID.uuidString),ref=r.image!
  let receipt=ConversationVisionProviderReceipt(requested_model:"google/gemma-4-31b-it:free",actual_model:"google/gemma-4-31b-it",actual_provider:wrong ? "Unapproved fixture recipient" : "Google AI Studio",cost:0,image_count:1,image_hashes:[ref.receipt.sha256],image_bytes:ref.receipt.size_bytes,route_hash:ref.routeHash,terminal_validated:true,response_id:"synthetic-only-response")
  var values:[ConversationTurnEvent.Payload]=[.started(requestHash:textHash("VisionFlowTest:"+r.operationID.uuidString),conversationRevision:1,grantEpoch:1,attachmentReceipts:[ref.receipt]),.textDelta(messageID:id,text:body)]
  if complete {values.append(.completed(messageID:id,finalTextHash:textHash(body),visionReceipt:receipt))}
  return values.enumerated().map{.init(operationID:r.operationID,epoch:r.epoch,sequence:$0.offset+1,payload:$0.element)}
 }
 func reply(_ r:ConversationTurnRequest) async throws ->AsyncThrowingStream<ConversationTurnEvent,Error> {
  guard let image=r.image,let bytes=r.imageBytes,image.consentRevision==revision else {throw ConversationDispatchFailure.notSent(reason:"Synthetic image consent expired")}
  try image.validate(bytes,messageID:r.history.last!.id);posts += 1;originals[r.operationID]=r.withImageBytes(nil)
  return AsyncThrowingStream{continuation in for e in script(r,complete:!eof){continuation.yield(e)};continuation.finish()}
 }
 func observe(_ r:ConversationTurnRequest) async throws ->ConversationObservation {
  guard let original=originals[r.operationID],original.image==r.image,r.imageBytes==nil else {throw CatpawError.missing};reads += 1
  return .init(request:r,events:script(r,complete:true),requestHash:textHash("VisionFlowTest:"+r.operationID.uuidString),grantEpoch:1,goals:[])
 }
}

private actor Consent16ReadinessBackend:ConversationBackend {
 private var count=0;private var image:CheckedContinuation<ConversationImageCapability,Never>?
 func connection(scope:DataScope) async -> ConversationConnection {count += 1;return .init(state:count<3 ? .unavailable : .providerUnverified,provider:"Owned synthetic readiness",detail:"No network/model")}
 func imageCapabilities(scope:DataScope,conversationID:UUID) async throws -> ConversationImageCapability {await withCheckedContinuation{image=$0}}
 func waitingForImage()->Bool {image != nil}
 func releaseImage(){image?.resume(returning:.init());image=nil}
 func calls()->Int {count}
 func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {throw ConversationSessionError.notConfigured}
 func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {throw ConversationSessionError.notConfigured}
}
private actor Consent16TerminalBackend:ConversationBackend {
 let valid:Bool;private var count=0;private var evidence:ConversationConnection?
 init(valid:Bool){self.valid=valid}
 func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"Owned terminal fixture",detail:"No network/model")}
 func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
  let valid=self.valid,id=UUID(),body="Owned synthetic response"
  return AsyncThrowingStream {c in
   c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:1,payload:.started(requestHash:textHash("owned"),conversationRevision:1,grantEpoch:1)))
   c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:2,payload:.textDelta(messageID:id,text:body)))
   c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:3,payload:.completed(messageID:id,finalTextHash:textHash(valid ? body : "Invalid terminal"))))
   c.finish()
  }
 }
 func recordCommittedReply(_ request:ConversationTurnRequest) async {count += 1;evidence = .init(state:.connected,provider:"Explicit injected evidence",detail:"Synthetic unit only",verifiedReplyAt:Date())}
 func recordedReplyEvidence(scope:DataScope) async -> ConversationConnection? {evidence}
 func records()->Int {count}
 func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {throw ConversationSessionError.notConfigured}
}
