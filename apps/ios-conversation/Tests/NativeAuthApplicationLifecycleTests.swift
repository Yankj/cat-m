import Foundation
import XCTest
@testable import CatpawM

/// Exercises real composition and teardown with a named offline login remote.
/// The local draft drain is held; no model, HTTP, Keychain or system effect runs.
final class NativeAuthApplicationLifecycleTests:XCTestCase {
    @MainActor func testLogoutClosesAuthorityBeforeLocalDrainAndLaterLoginStillOpens() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-auth-lifecycle-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let configuration=try NativeAuthConfiguration(
            projectURL:URL(string:"https://abcdefghijklmnopqrst.supabase.co")!,
            publishableKey:"sb_publishable_offline_lifecycle_test",
            backendOrigin:URL(string:"https://backend.example.invalid")!,serverScopeID:UUID())
        let subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root)
        let gate=LifecycleLocalDrainGate()
        var refresh:Task<String,Error>?
        var logout:Task<Void,Never>?
        var registeredService:ConversationArtifactEditService?
        var registrationID:UUID?
        do {
            await app.start()
            await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
            try await waitUntil {app.chat != nil}
            let original=try XCTUnwrap(app.chat)
            await original.start()
            XCTAssertTrue(original.loaded)
            XCTAssertEqual(original.trustedSubjectID,subject)
            let partition=AuthenticatedLocalPartition(issuer:configuration.issuer,subject:subject,serverScopeID:try XCTUnwrap(configuration.serverScopeID))
            XCTAssertEqual(original.scope,partition.scope)
            registeredService=original.artifactEditService
            registrationID=original.artifactEditService.registerLocalDraftFlusher {
                await gate.hold()
            }

            // An admitted synthetic rotation is deliberately still waiting when logout begins.
            clock.advance(4000)
            let rotation=Task {try await manager.authorization(subject:subject)}
            refresh=rotation
            try await waitUntil {await remote.refreshIsPending()}
            let signOut=Task {await app.signOut()}
            logout=signOut
            try await waitUntil {await gate.isWaiting()}
            try await waitUntil {(await manager.snapshot()).phase == .signedOut}
            // The manager publishes signedOut before its best-effort remote revocation finishes.
            try await waitUntil {(try? storage.load()) == nil}
            XCTAssertTrue(app.actionBusy,"Local cleanup is still held by the registered drain.")
            XCTAssertNil(app.chat)
            XCTAssertFalse(original.networkAdmissionAllowed)
            XCTAssertTrue(try storage.isSignedOut())
            XCTAssertNil(try storage.load())
            do {
                _=try await manager.authorization(subject:subject)
                XCTFail("Explicit logout must close token authority before local cleanup returns.")
            } catch NativeAuthError.loginRequired { }

            await remote.releaseRefresh()
            do {
                _=try await rotation.value
                XCTFail("The original refresh cannot survive the logout generation change.")
            } catch NativeAuthError.cancelled { }
            catch NativeAuthError.loginRequired { }
            // Give any queued snapshot callback an opportunity to reattach the account.
            for _ in 0..<200 {await Task.yield()}
            XCTAssertNil(app.chat,"A late authenticated snapshot cannot recreate a chat during logout.")
            let drainHeld=await gate.isWaiting(),rotationCounts=await remote.counts()
            XCTAssertTrue(drainHeld)
            XCTAssertEqual(rotationCounts.refreshes,1)
            XCTAssertTrue(try storage.isSignedOut())

            await gate.release()
            await signOut.value
            XCTAssertNil(app.chat)
            XCTAssertEqual(app.state.phase,.signedOut)
            XCTAssertFalse(app.actionBusy)
            XCTAssertFalse(original.loaded)
            if let id=registrationID {original.artifactEditService.unregisterLocalDraftFlusher(id)}
            registeredService=nil;registrationID=nil

            // The dedicated logout fence must clear; ordinary authenticated snapshots still open.
            await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
            try await waitUntil {app.chat != nil}
            let reopened=try XCTUnwrap(app.chat)
            XCTAssertFalse(reopened === original)
            XCTAssertEqual(reopened.scope,partition.scope)
            XCTAssertEqual(reopened.trustedSubjectID,subject)
            XCTAssertEqual(app.state.phase,.authenticated)
            XCTAssertFalse(try storage.isSignedOut())
            _=try await manager.authorization(subject:subject)
            await reopened.start()
            XCTAssertTrue(reopened.loaded)
            await app.signOut()
            XCTAssertNil(app.chat)
            XCTAssertEqual(app.state.phase,.signedOut)
            XCTAssertFalse(reopened.loaded)
            XCTAssertTrue(try storage.isSignedOut())
            let counts=await remote.counts()
            XCTAssertEqual(counts.logins,2)
            XCTAssertEqual(counts.refreshes,1)
            XCTAssertEqual(counts.signOuts,2)
            XCTAssertEqual(counts.revocations,2)
        } catch {
            await remote.releaseRefresh()
            await gate.release()
            _=try? await refresh?.value
            await logout?.value
            if let id=registrationID {registeredService?.unregisterLocalDraftFlusher(id)}
            await app.signOut()
            throw error
        }
    }

    @MainActor private func waitUntil(_ predicate:@escaping @MainActor () async -> Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while ProcessInfo.processInfo.systemUptime<deadline {
            if await predicate() {return}
            try await Task.sleep(nanoseconds:1_000_000)
        }
        throw LifecycleFailure(message:"Named offline lifecycle gate did not reach its expected state.")
    }
}

private struct LifecycleFailure:Error {let message:String}
private final class LifecycleClock:@unchecked Sendable {
    private let lock=NSLock()
    private var value=Date()
    func now()->Date {lock.lock();defer{lock.unlock()};return value}
    func advance(_ seconds:TimeInterval){lock.lock();defer{lock.unlock()};value=value.addingTimeInterval(seconds)}
}
private final class LifecycleStorage:NativeAuthVault,NativeAuthLogoutBarrier,@unchecked Sendable {
    private let lock=NSLock()
    private var credential:NativeAuthCredential?
    private var signedOut=false
    func load() throws -> NativeAuthCredential? {lock.lock();defer{lock.unlock()};return credential}
    func save(_ value:NativeAuthCredential) throws {lock.lock();defer{lock.unlock()};credential=value}
    func clear() throws {lock.lock();defer{lock.unlock()};credential=nil}
    func isSignedOut() throws -> Bool {lock.lock();defer{lock.unlock()};return signedOut}
    func setSignedOut(_ value:Bool) throws {lock.lock();defer{lock.unlock()};signedOut=value}
}
private actor LifecycleLocalDrainGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var released=false
    func hold() async {if released {return};await withCheckedContinuation{continuation=$0}}
    func isWaiting()->Bool {continuation != nil}
    func release(){released=true;continuation?.resume();continuation=nil}
}
private actor LifecycleRemote:NativeAuthRemote {
    struct Counts {let logins:Int,refreshes:Int,signOuts:Int,revocations:Int}
    private let issuer:String,subject:UUID,clock:LifecycleClock
    private var refreshWait:CheckedContinuation<NativeAuthCredential,Error>?
    private var logins=0,refreshes=0,signOuts=0,revocations=0
    init(issuer:String,subject:UUID,clock:LifecycleClock){self.issuer=issuer;self.subject=subject;self.clock=clock}
    private func credential()->NativeAuthCredential {
        .init(issuer:issuer,user:.init(id:subject),accessToken:"offline.lifecycle.signature",refreshToken:"synthetic-lifecycle-only",expiresAt:clock.now().addingTimeInterval(3600))
    }
    func signIn(email:String,password:String) async throws -> NativeAuthCredential {
        guard email=="synthetic@example.invalid",password=="fixture-only" else {throw NativeAuthError.invalidCredentials}
        logins += 1;return credential()
    }
    func user(accessToken:String) async throws -> NativeAuthUser {.init(id:subject)}
    func refresh(refreshToken:String) async throws -> NativeAuthCredential {
        refreshes += 1;return try await withCheckedThrowingContinuation{refreshWait=$0}
    }
    func signOut(accessToken:String) async throws {signOuts += 1}
    func revokeApplicationSession(accessToken:String) async throws {revocations += 1}
    func refreshIsPending()->Bool {refreshWait != nil}
    func releaseRefresh(){refreshWait?.resume(returning:credential());refreshWait=nil}
    func counts()->Counts {.init(logins:logins,refreshes:refreshes,signOuts:signOuts,revocations:revocations)}
}
