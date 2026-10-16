import Foundation
import XCTest
@testable import CatpawM

/// Exercises real composition and teardown with a named offline login remote.
/// The local draft drain is held; no model, HTTP, Keychain or system effect runs.
final class NativeAuthApplicationLifecycleTests:XCTestCase {
    @MainActor func testActiveKnownRotationRecoversAutomaticallyInSameLocalChat() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-active-rotation-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),clock=AuthTestClock(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer,clock:clock)
        try storage.save(await remote.candidate())
        let subject=await remote.id
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.success,.success],accessToken:"synthetic.anon.signature")
        let retryClock=LifecycleRetryClock()
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retryClock:retryClock)
        await app.start();try await waitUntil {app.chat?.networkAdmissionAllowed == true}
        let original=try XCTUnwrap(app.chat)
        clock.advance(4000);await remote.behavior(userUnavailable:true)
        do {_=try await manager.authorization(subject:subject);XCTFail("Unvalidated rotation must not authorize.")}
        catch NativeAuthError.unavailable { }
        try await waitUntil {await retryClock.pendingCount() == 1}
        XCTAssertFalse(original.networkAdmissionAllowed);XCTAssertNil(app.error)
        await remote.behavior();await app.foreground()
        try await waitUntil {app.chat?.networkAdmissionAllowed == true}
        XCTAssertTrue(app.chat === original)
        let counts=await remote.counts()
        XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,1)
        await app.signOut()
    }

    @MainActor func testWorkspaceBackoffGrowsAndCapsWithoutNewLogin() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-workspace-backoff-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.unavailable,.unavailable,.unavailable,.unavailable,.success])
        let retryClock=LifecycleRetryClock()
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retryClock:retryClock,retrySchedule:.init(nominalSeconds:[1,2,4],jitter:{$0}))
        await app.start();await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
        for count in 1...4 {
            try await waitUntil {
                let delays=await retryClock.delays(),pending=await retryClock.pendingCount()
                return delays.count == count && pending == 1
            }
            XCTAssertNil(app.error)
            await retryClock.advance()
        }
        try await waitUntil {app.chat?.networkAdmissionAllowed == true}
        let delays=await retryClock.delays(),counts=await remote.counts()
        XCTAssertEqual(delays,[1_000_000_000,2_000_000_000,4_000_000_000,4_000_000_000])
        XCTAssertEqual(counts.logins,1)
        await app.signOut()
    }

    @MainActor func testKnownRotationRetriesOnlyUserValidationAndPreservesIdentity() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-known-rotation-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),clock=AuthTestClock(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer,clock:clock)
        try storage.save(await remote.candidate(expired:true))
        await remote.behavior(userUnavailable:true)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:await remote.id,scope:scope,steps:[.success],accessToken:"synthetic.anon.signature")
        let retryClock=LifecycleRetryClock()
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retryClock:retryClock)
        let startup=Task {@MainActor in await app.start()}
        try await waitUntil {await retryClock.pendingCount() == 1}
        XCTAssertTrue(try storage.isSignedOut(),"Pending candidate cannot grant HTTP authority.")
        XCTAssertNil(app.error)
        await remote.behavior();await app.foreground();await startup.value
        try await waitUntil {app.chat?.networkAdmissionAllowed == true}
        let counts=await remote.counts()
        XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,1);XCTAssertEqual(counts.2,2)
        XCTAssertFalse(try storage.isSignedOut())
        XCTAssertFalse(app.requiresSessionRestart)
        await app.signOut()
    }

    @MainActor func testLogoutDuringColdRecoveryCancelsRetryAndNeverReopens() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-restore-logout-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer)
        try storage.save(await remote.candidate());await remote.behavior(unavailable:true)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage)
        let retryClock=LifecycleRetryClock()
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,retryClock:retryClock)
        let startup=Task {@MainActor in await app.start()}
        try await waitUntil {await retryClock.pendingCount() == 1}
        await app.signOut();await startup.value
        await remote.behavior();await app.foreground()
        XCTAssertNil(app.chat);XCTAssertNil(try storage.load());XCTAssertEqual(app.state.phase,.signedOut)
        let counts=await remote.counts()
        XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0);XCTAssertEqual(counts.2,1)
    }

    @MainActor func testRejectedWorkspaceStopsWithFriendlyCopyUntilExplicitRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-workspace-rejected-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage)
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.rejected,.success])
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver)
        await app.start();await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
        try await waitUntil {app.requiresSessionRestart}
        XCTAssertEqual(app.error,NativeAuthError.sessionRecoveryRequired.localizedDescription)
        await app.foreground()
        let counts=await resolver.counts()
        XCTAssertEqual(counts.calls,1);XCTAssertNil(app.chat)
        await app.signOut()
    }

    @MainActor func testWorkspace503RetriesSilentlyAndCoalescesUntilSuccess() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-workspace-retry-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.unavailable,.unavailable,.success])
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retrySchedule:.init(nominalSeconds:[0],jitter:{$0}))

        await app.start()
        await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
        try await waitUntil {app.chat != nil && app.chat?.networkAdmissionAllowed == true}

        let resolution=await resolver.counts(),auth=await remote.counts()
        XCTAssertEqual(resolution.calls,3)
        XCTAssertEqual(resolution.maximumConcurrent,1)
        XCTAssertEqual(auth.logins,1,"Workspace retry must not create another identity.")
        XCTAssertNil(app.error)
        XCTAssertFalse(NativeApplicationSessionError(httpStatus:503,code:"auth_key_service_unavailable").localizedDescription.contains("HTTP"))
        XCTAssertFalse(NativeApplicationSessionError(httpStatus:503,code:"auth_key_service_unavailable").localizedDescription.contains("auth_key_service"))
        await app.signOut()
    }

    @MainActor func testReturningLocalChatStaysReadableAndForegroundWakesRetryInPlace() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-workspace-local-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let credential=NativeAuthCredential(issuer:configuration.issuer,user:.init(id:subject),accessToken:"offline.lifecycle.signature",refreshToken:"synthetic-lifecycle-only",expiresAt:clock.now().addingTimeInterval(3600))
        try storage.save(credential)
        let partition=AuthenticatedLocalPartition(issuer:configuration.issuer,subject:subject,serverScopeID:scope)
        let directory=root.appendingPathComponent(partition.namespace,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        _=try Repository(persistence:SwiftDataPersistence(url:directory.appendingPathComponent("local.store")))
        try JSONEncoder().encode(LocalConversationReceipt(issuer:configuration.issuer,subject:subject,serverScopeID:scope)).write(to:root.appendingPathComponent("last-local-workspace.json"),options:.atomic)

        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.unavailable,.success])
        let retryClock=LifecycleRetryClock()
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retryClock:retryClock,retrySchedule:.init(nominalSeconds:[60],jitter:{$0}))

        await app.start()
        try await waitUntil {
            let resolution=await resolver.counts(),pending=await retryClock.pendingCount()
            return app.chat != nil && resolution.calls == 1 && pending == 1
        }
        let preview=try XCTUnwrap(app.chat)
        XCTAssertTrue(preview.loaded)
        XCTAssertFalse(preview.networkAdmissionAllowed)
        XCTAssertNil(app.error,"A retryable scope outage stays silent.")

        await app.foreground()
        await app.foreground()
        try await waitUntil {app.chat?.networkAdmissionAllowed == true}
        XCTAssertTrue(app.chat === preview,"Recovery must admit the existing local partition in place.")
        let counts=await resolver.counts()
        XCTAssertEqual(counts.calls,2)
        XCTAssertEqual(counts.maximumConcurrent,1)
        await app.signOut()
    }

    @MainActor func testReachabilityAndLogoutFenceWorkspaceResolution() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-workspace-fence-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.heldSuccess])
        let monitor=ConnectionMonitor(start:false);monitor.pathChanged(false)
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,connectionMonitor:monitor,retrySchedule:.init(nominalSeconds:[0],jitter:{$0}))

        await app.start()
        await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
        for _ in 0..<100 {await Task.yield()}
        let offlineCounts=await resolver.counts()
        XCTAssertEqual(offlineCounts.calls,0,"An unavailable path must not consume a workspace attempt.")
        monitor.pathChanged(true);monitor.pathChanged(true)
        try await waitUntil {await resolver.isHolding()}
        let waitingCounts=await resolver.counts()
        XCTAssertEqual(waitingCounts.calls,1)

        await app.signOut()
        await resolver.releaseHeldSuccess()
        for _ in 0..<200 {await Task.yield()}
        XCTAssertNil(app.chat)
        XCTAssertEqual(app.state.phase,.signedOut)
        let finalCounts=await resolver.counts()
        XCTAssertEqual(finalCounts.maximumConcurrent,1)
    }

    @MainActor func testColdValidationRetriesSafelyWithoutCreatingAnotherIdentity() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-auth-safe-restore-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),authClock=AuthTestClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer,clock:authClock)
        let subject=await remote.id
        try storage.save(await remote.candidate())
        await remote.behavior(unavailable:true)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{authClock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.success],accessToken:"synthetic.anon.signature")
        let retryClock=LifecycleRetryClock()
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retryClock:retryClock,retrySchedule:.init(nominalSeconds:[60],jitter:{$0}))

        let startup=Task {@MainActor in await app.start()}
        try await waitUntil {await retryClock.pendingCount() == 1}
        XCTAssertNil(app.error)
        await remote.behavior()
        await app.foreground()
        await startup.value
        try await waitUntil {app.chat?.networkAdmissionAllowed == true}

        let counts=await remote.counts()
        XCTAssertEqual(counts.0,0,"Read-only validation retry must not create a replacement anonymous identity.")
        XCTAssertEqual(counts.1,0)
        XCTAssertEqual(counts.2,2)
        XCTAssertNil(app.error)
        await app.signOut()
    }

    @MainActor func testAmbiguousRefreshStopsWithFriendlyRestartCopyAndNoBlindRetry() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-auth-ambiguous-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),authClock=AuthTestClock(),storage=LifecycleStorage()
        let configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer,clock:authClock)
        try storage.save(await remote.candidate(expired:true))
        await remote.behavior(unavailable:true)
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{authClock.now()})
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,retrySchedule:.init(nominalSeconds:[0],jitter:{$0}))

        await app.start()
        XCTAssertTrue(app.requiresSessionRestart)
        XCTAssertEqual(app.error,"这次会话需要重新开始，本机对话仍会保留。")
        XCTAssertNotNil(try storage.load(),"Ambiguous rotation preserves the local credential bytes for explicit reconciliation/reset.")
        XCTAssertTrue(try storage.isSignedOut())
        let before=await remote.counts()
        XCTAssertEqual(before.1,1)
        await app.foreground()
        let after=await remote.counts()
        XCTAssertEqual(after.1,1,"Foregrounding must not replay an uncertain refresh-token rotation.")
        XCTAssertFalse(app.error?.contains("已有会话未能安全恢复") == true)
        await app.signOut()
    }

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
    /// Codex p89g-2: logout completes while the FIRST detached local read (receipt + vault) is suspended. The read returns
    /// old credentials/receipt afterwards; the open must end there (lifecycle snapshot taken at entry), never attach.
    /// Counter-run (no logout) proves the same path attaches, so the refusal is not vacuous.
    @MainActor func testLogoutDuringFirstLocalReadNeverAttachesOldChat() async throws {
        for logout in [true,false] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-first-read-"+UUID().uuidString,isDirectory:true)
            defer {try? FileManager.default.removeItem(at:root);NativeAuthApplicationModel.afterLocalReadHook=nil}
            let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
            let configuration=try lifecycleConfiguration(scope:scope)
            let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
            // Seed a returning user: signed in once → local receipt + store on disk, credential in the vault.
            let seed=NativeAuthApplicationModel(configuration:configuration,manager:NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()}),vault:storage,barrier:storage,root:root)
            await seed.start();await seed.signIn(email:"synthetic@example.invalid",password:"fixture-only")
            try await waitUntil {seed.chat != nil}
            _=await seed.chat?.deactivate()
            let gate=LifecycleLocalDrainGate()
            var reached=false
            NativeAuthApplicationModel.afterLocalReadHook={reached=true;await gate.hold()}
            let app=NativeAuthApplicationModel(configuration:configuration,manager:NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()}),vault:storage,barrier:storage,root:root)
            let startup=Task {@MainActor in await app.start()}
            try await waitUntil {reached}
            XCTAssertNil(app.chat,"suspended inside the first read")
            if logout {
                await app.signOut()
                NativeAuthApplicationModel.afterLocalReadHook=nil
                await gate.release();await startup.value
                XCTAssertNil(app.chat,"the stale first read never re-attaches after logout")
                XCTAssertEqual(app.state.phase,.signedOut)
            } else {
                NativeAuthApplicationModel.afterLocalReadHook=nil
                await gate.release()
                try await waitUntil {app.chat != nil}
                XCTAssertEqual(app.chat?.trustedSubjectID,subject,"counter-run: the same read path attaches when nothing changed")
                await startup.value
                await app.signOut()
            }
        }
    }

    /// Codex p89g-2: the offline-trial "upgrade when the network returns" task is owned and cancelled by logout, and bound
    /// to its lifecycle epoch: network returning AFTER logout never starts an experience. Counter-run proves the path fires.
    @MainActor func testLogoutCancelsOfflineRecoveryTaskBeforeNetworkReturns() async throws {
        defer {NativeAuthApplicationModel.offlineRecoveryWillStartExperience=nil}
        for logout in [true,false] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-offline-recovery-"+UUID().uuidString,isDirectory:true)
            defer {try? FileManager.default.removeItem(at:root)}
            let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage()
            let configuration=try lifecycleConfiguration(scope:scope)
            let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
            let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
            let monitor=ConnectionMonitor(start:false);monitor.pathChanged(false)
            let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,connectionMonitor:monitor)
            var fired=0
            NativeAuthApplicationModel.offlineRecoveryWillStartExperience={fired += 1}
            await app.openOfflineTrialChat(configuration:configuration)
            XCTAssertNotNil(app.chat);let recovery=try XCTUnwrap(app.offlineRecoveryTask)
            if logout {
                await app.signOut()
                XCTAssertNil(app.offlineRecoveryTask,"logout owns and cancels the recovery task")
                monitor.pathChanged(true)
                await recovery.value
                XCTAssertEqual(fired,0,"network returning after logout never starts an experience")
            } else {
                monitor.pathChanged(true)
                await recovery.value
                XCTAssertEqual(fired,1,"counter-run: the recovery path really reaches startExperience")
            }
        }
    }

    private func lifecycleConfiguration(scope:UUID) throws ->NativeAuthConfiguration {
        try NativeAuthConfiguration(projectURL:URL(string:"https://abcdefghijklmnopqrst.supabase.co")!,publishableKey:"sb_publishable_offline_lifecycle_test",backendOrigin:URL(string:"https://backend.example.invalid")!,serverScopeID:scope)
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

private actor LifecycleWorkspaceResolver:NativeApplicationScopeResolving {
    enum Step {case unavailable,rejected,success,heldSuccess}
    struct Counts {let calls:Int,maximumConcurrent:Int}
    private let subject:UUID,scope:UUID,accessToken:String
    private var steps:[Step]
    private var calls=0,active=0,maximumConcurrent=0
    private var held:CheckedContinuation<UUID,Error>?
    init(subject:UUID,scope:UUID,steps:[Step],accessToken:String="offline.lifecycle.signature") {self.subject=subject;self.scope=scope;self.steps=steps;self.accessToken=accessToken}
    func applicationScope(accessToken:String,subject:UUID) async throws ->UUID {
        guard subject == self.subject,accessToken == self.accessToken else {throw NativeAuthError.invalidResponse}
        calls += 1;active += 1;maximumConcurrent=max(maximumConcurrent,active);defer{active -= 1}
        let step=steps.isEmpty ? .success : steps.removeFirst()
        switch step {
        case .unavailable:throw NativeApplicationSessionError(httpStatus:503,code:"auth_key_service_unavailable")
        case .rejected:throw NativeApplicationSessionError(httpStatus:401,code:"invalid_session")
        case .success:return scope
        case .heldSuccess:return try await withCheckedThrowingContinuation {held=$0}
        }
    }
    func counts()->Counts {.init(calls:calls,maximumConcurrent:maximumConcurrent)}
    func isHolding()->Bool {held != nil}
    func releaseHeldSuccess(){held?.resume(returning:scope);held=nil}
}

private actor LifecycleRetryClock:NativeWorkspaceRetryClock {
    private var waiters:[UUID:CheckedContinuation<Void,Error>]=[:]
    private var recordedDelays:[UInt64]=[]
    func sleep(nanoseconds:UInt64) async throws {
        let id=UUID()
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                if Task.isCancelled {continuation.resume(throwing:CancellationError())}
                else {recordedDelays.append(nanoseconds);waiters[id]=continuation}
            }
        },onCancel:{Task {await self.cancel(id)}})
    }
    func pendingCount()->Int {waiters.count}
    func delays()->[UInt64] {recordedDelays}
    func advance() {let pending=waiters.values;waiters.removeAll();pending.forEach{$0.resume()}}
    private func cancel(_ id:UUID){waiters.removeValue(forKey:id)?.resume(throwing:CancellationError())}
}
