import XCTest
import Security
@testable import CatpawM

final class NativeAuthNativeTests: XCTestCase {
    private func awaitGate(_ predicate:@escaping () async -> Bool) async throws {
        for _ in 0..<10000 { if await predicate() { return }; await Task.yield() }
        throw NativeAuthError.unavailable
    }
    func testColdSavedValidationCannotAuthorizeBeforeRejection() async throws {
        let c = try config(), id = UUID(), storage = AuthTestStorage(), remote = NativeAuthBoundaryRemote(issuer:c.issuer,subject:id)
        try storage.save(await remote.candidate())
        let manager = NativeAuthSessionManager(configuration:c,remote:remote,vault:storage,barrier:storage)
        let restore = Task { try await manager.restore() }; try await awaitGate { await remote.pendingUser() }
        do { _ = try await manager.authorization(subject:id); XCTFail("Pending candidate must not authorize") } catch NativeAuthError.loginRequired { }
        let pending = await manager.snapshot(); XCTAssertEqual(pending.phase,.restoring); XCTAssertNil(pending.user)
        await remote.rejectUser(); _ = try? await restore.value
        let closed = await manager.snapshot(); XCTAssertNil(closed.user)
    }
    func testColdExpiredRefreshKeepsIdentityPending() async throws {
        let c = try config(), id = UUID(), storage = AuthTestStorage(), remote = NativeAuthBoundaryRemote(issuer:c.issuer,subject:id)
        try storage.save(.init(issuer:c.issuer,user:.init(id:id),accessToken:"expired.access.signature",refreshToken:"synthetic-expired-only",expiresAt:Date().addingTimeInterval(-1)))
        let manager = NativeAuthSessionManager(configuration:c,remote:remote,vault:storage,barrier:storage)
        let restore = Task { try await manager.restore() }; try await awaitGate { await remote.pendingRefresh() }
        let pending = await manager.snapshot(); XCTAssertEqual(pending.phase,.restoring); XCTAssertNil(pending.user)
        do { _ = try await manager.authorization(subject:id); XCTFail("Pending rotation must not authorize") } catch NativeAuthError.loginRequired { }
        await remote.rejectRefresh(); _ = try? await restore.value
        let closed = await manager.snapshot(); XCTAssertNil(closed.user)
    }
    func testDirectLoginTaskCancellationCannotSaveOrPublish() async throws {
        let c = try config(), storage = AuthTestStorage(), remote = NativeAuthBoundaryRemote(issuer:c.issuer,subject:UUID())
        let manager = NativeAuthSessionManager(configuration:c,remote:remote,vault:storage,barrier:storage)
        let login = Task { try await manager.signIn(email:"synthetic@example.invalid",password:"fixture-only") }
        try await awaitGate { await remote.pendingUser() }; login.cancel(); await remote.acceptUser()
        do { try await login.value; XCTFail("Cancelled task cannot succeed") } catch NativeAuthError.cancelled { }
        let state = await manager.snapshot(); XCTAssertNil(state.user); XCTAssertNil(try storage.load()); XCTAssertTrue(try storage.isSignedOut())
    }
    private func config() throws -> NativeAuthConfiguration { try .init(projectURL:URL(string:"https://abcdefghijklmnopqrst.supabase.co")!,publishableKey:"sb_publishable_test_public_value",backendOrigin:URL(string:"https://backend.example.invalid")!,serverScopeID:UUID()) }
    func testNativeKeychainRoundTripAccessibilityAndExactDeletion() throws {
        let c = try config(), service = "com.example.CatpawM.r7.test."+UUID().uuidString, vault = NativeAuthKeychainVault(service:service,issuer:c.issuer)
        defer { try? vault.clear() }
        let credential = NativeAuthCredential(issuer:c.issuer,user:.init(id:UUID()),accessToken:"fixture.access.signature",refreshToken:"fixture-only",expiresAt:Date().addingTimeInterval(3600))
        let probeService = service+".probe"
        let probe: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:probeService,kSecAttrAccount as String:"fixture-only",kSecValueData as String:Data("fixture-only".utf8),kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let probeStatus = SecItemAdd(probe as CFDictionary,nil)
        defer { SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:probeService] as CFDictionary) }
        XCTAssertEqual(probeStatus,errSecSuccess,"Owned synthetic Keychain probe OSStatus (no token): \(probeStatus)")
        try vault.save(credential); XCTAssertEqual(try vault.load()?.user.id,credential.user.id)
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:textHash(c.issuer),kSecReturnAttributes:true,kSecAttrSynchronizable:false] as CFDictionary,&attributes)
        XCTAssertEqual(status,errSecSuccess)
        XCTAssertEqual((attributes as? [String:Any])?[kSecAttrAccessible as String] as? String,kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try vault.clear(); XCTAssertNil(try vault.load())
    }
    func testLogoutBarrierSurvivesNativeRestartAfterVaultDeletionFailure() async throws {
        let c = try config(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:dir) }
        let vault = AuthTestStorage(), barrier = NativeAuthFileLogoutBarrier(url:dir.appendingPathComponent("barrier")), remote = AuthTestRemote(issuer:c.issuer,id:UUID()), manager = NativeAuthSessionManager(configuration:c,remote:remote,vault:vault,barrier:barrier)
        try await manager.signIn(email:"synthetic@example.invalid",password:"fixture-only"); vault.failures(clear:true)
        do { try await manager.signOut(); XCTFail("Failed deletion cannot emit success") } catch NativeAuthError.storage { }
        let reopened = NativeAuthSessionManager(configuration:c,remote:remote,vault:vault,barrier:NativeAuthFileLogoutBarrier(url:dir.appendingPathComponent("barrier")))
        try await reopened.restore(); let state = await reopened.snapshot()
        XCTAssertEqual(state.phase,.signedOut); XCTAssertNil(state.user); XCTAssertTrue(try barrier.isSignedOut())
    }
    func testConcurrentExpiryRefreshAndCancelledConsumerInsideSimulator() async throws {
        let c = try config(), id = UUID(), clock = AuthTestClock(), storage = AuthTestStorage(), remote = AuthTestRemote(issuer:c.issuer,id:id,clock:clock), manager = NativeAuthSessionManager(configuration:c,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        try await manager.signIn(email:"synthetic@example.invalid",password:"fixture-only"); clock.advance(4000)
        let a = Task { try await manager.authorization(subject:id) }, b = Task { try await manager.authorization(subject:id) }
        try await Task.sleep(nanoseconds:20_000_000); a.cancel(); _ = try await b.value
        do { _ = try await a.value; XCTFail("Cancelled consumer must detach") } catch is CancellationError { }
        let count = await remote.refreshCount(), state = await manager.snapshot()
        XCTAssertEqual(count,1); XCTAssertEqual(state.phase,.authenticated)
    }
    func testAuthenticatedPartitionsUseSeparateSwiftDataStores() async throws {
        let c = try config(), a = AuthenticatedLocalPartition(issuer:c.issuer,subject:UUID(),serverScopeID:c.serverScopeID!), b = AuthenticatedLocalPartition(issuer:c.issuer,subject:UUID(),serverScopeID:c.serverScopeID!)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:dir) }
        let pa = dir.appendingPathComponent(a.namespace+".store"), pb = dir.appendingPathComponent(b.namespace+".store")
        let sa = ConversationSessionService(repository:try Repository(persistence:SwiftDataPersistence(url:pa))), sb = ConversationSessionService(repository:try Repository(persistence:SwiftDataPersistence(url:pb)))
        let ca = try await sa.openLatest(scope:a.scope), cb = try await sb.openLatest(scope:b.scope)
        try await sa.saveDraft(scope:a.scope,conversationID:ca,text:"Only account A")
        let bRead = try await sb.read(scope:b.scope,conversationID:cb); XCTAssertTrue(bRead.messages.isEmpty)
        let aRepo = try Repository(persistence:SwiftDataPersistence(url:pa)), bRepo = try Repository(persistence:SwiftDataPersistence(url:pb))
        let aRecord = try await aRepo.record(ca,scope:a.scope), bRecord = try await bRepo.record(cb,scope:b.scope)
        XCTAssertEqual(aRecord.conversation?.draftText,"Only account A")
        XCTAssertEqual(bRecord.conversation?.draftText,"")
        do { _ = try await aRepo.record(ca,scope:b.scope); XCTFail("Wrong account scope must fail") } catch { }
    }
}
