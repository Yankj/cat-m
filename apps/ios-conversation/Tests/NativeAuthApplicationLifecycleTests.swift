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

    /// p89i generic park + per-item decision through the REAL logout entry: epoch bump first, then collect (device calls +
    /// ledger), per-item decision, apply, observers — in that order; unanswered = keep; passive (no decider) = keep, logged.
    @MainActor func testLogoutWithInFlightDeviceOperationAsksFirst() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-inflight-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),clock=AuthTestClock(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer,clock:clock)
        try storage.save(await remote.candidate())
        let subject=await remote.id
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.success,.success],accessToken:"synthetic.anon.signature")
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retryClock:LifecycleRetryClock())
        await app.start();try await waitUntil {app.chat?.networkAdmissionAllowed == true}
        let account=try XCTUnwrap(DeviceCallGate.currentAccount())
        let call=DeviceCall(call_id:"inflight-"+UUID().uuidString,tool:"reminder_create",args:["title":.string("买猫粮")],confirm:.card,ttl_sec:600)
        DeviceCallGate.receive(call)
        let suite="xctest.inflight."+UUID().uuidString,defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defaults.set(try JSONEncoder().encode([call.call_id:DeviceCallStore.Record(phase:.running,call:call,updatedAt:.now,account:account)]),forKey:DeviceCallStore.storageKey)
        let callStore=DeviceCallStore(defaults:defaults)
        // a ledger entry for the same account (previously cleared silently on logout)
        let ledgerURL=root.appendingPathComponent("ledger.json")
        let ledger=DeviceLedger(url:ledgerURL,epoch:AccountEpoch.shared,items:nil)
        let rec=DeviceCall(call_id:"ledger-"+UUID().uuidString,tool:"calendar_create",args:["title":.string("复诊")],confirm:.card,ttl_sec:600)
        ledger.record(call:rec,result:.init(call_id:rec.call_id,status:.ok,data:["event_id":.string("evt-1")]),token:try XCTUnwrap(AccountEpoch.shared.capture()))
        AccountParkedItems.register(DeviceCallParkedSource.key,DeviceCallParkedSource(store:callStore))
        AccountParkedItems.register(DeviceLedgerParkedSource.key,DeviceLedgerParkedSource(ledger:ledger))
        defer {AccountParkedItems.unregister(DeviceCallParkedSource.key);AccountParkedItems.unregister(DeviceLedgerParkedSource.key)}
        var lines:[String]=[];AccountParkedItems.sink={lines.append($0)};defer {AccountParkedItems.sink=nil}
        var order:[String]=[];AccountChangeObservers.register("zz-p89i-order"){_,_ in order.append("observers")};defer {AccountChangeObservers.unregister("zz-p89i-order")}
        var seenItems:[AccountParkedItem]=[]
        app.parkedDecider={items in
            order.append("decide");seenItems=items
            XCTAssertNil(AccountEpoch.shared.currentAccount,"1. the epoch was bumped synchronously BEFORE the decision")
            XCTAssertFalse(DeviceCallGate.isLive(call.call_id),"…and the grant is already dead")
            XCTAssertTrue(items.allSatisfy { $0.automatic == nil })
            // only the EXTERNAL item (EventKit entry Catpaw created) is asked; the user picks 撤销
            return ["\(DeviceLedgerParkedSource.key)/\(rec.call_id)":.cancel]
        }
        await app.signOut()
        XCTAssertEqual(order,["decide","observers"],"deterministic order: decision → apply → observers")
        XCTAssertEqual(seenItems.map(\.source),[DeviceLedgerParkedSource.key],"only the external EventKit item is asked; app-internal items are automatic")
        XCTAssertEqual(callStore.phase(call.call_id),DeviceCallStore.Phase.running,"in-flight EventKit write → parked automatically (not run, not deleted)")
        XCTAssertEqual(ledger.entries(account:account).map(\.id),[rec.call_id],"撤销 of an unprovable item → system item kept, entry parked (never a guess)")
        XCTAssertEqual(lines.first,"parked: 2 item(s) for leaving account")
        XCTAssertTrue(lines.contains { $0.hasPrefix("\(DeviceCallParkedSource.key)/running:\(call.call_id) keep (auto):") })
        XCTAssertTrue(lines.contains("\(DeviceLedgerParkedSource.key)/\(rec.call_id) cancel: not provable → system item kept, entry parked"))
        // no decider (passive invalidation) → default keep, logged
        lines=[];AccountEpoch.shared.activate(account:account)
        let passive=await AccountParkedItems.resolve(account:account,decider:nil)
        XCTAssertEqual(passive[1],"no decider → external items default keep");XCTAssertEqual(ledger.entries(account:account).count,1)
        AccountEpoch.shared.activate(account:nil)
        UserDefaults().removePersistentDomain(forName:suite)
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

    /// Codex PR90f #6: the real login / logout path (NativeAuthApplicationModel.signIn / signOut → account barrier →
    /// AccountEpoch → AccountChangeObservers → ProactiveEngine) — not a hand-built snapshot.
    @MainActor func testProactiveDataFollowsRealSignInAndSignOut() async throws {
        ProactiveClock.now={Date(timeIntervalSince1970:1_792_040_400)}   // fixed instant 2026-10-15T05:00Z (no wall clock)
        defer {ProactiveClock.now={Date()}}
        ProactiveEngine.registerAccountObserver()
        func session(_ subject:UUID) async throws -> NativeAuthApplicationModel {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-proactive-"+UUID().uuidString,isDirectory:true)
            let scope=UUID(),clock=LifecycleClock(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
            let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
            let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
            let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.success])
            let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retrySchedule:.init(nominalSeconds:[0],jitter:{$0}))
            await app.start();await app.signIn(email:"synthetic@example.invalid",password:"fixture-only")
            try await waitUntil {AccountEpoch.shared.currentAccount==subject.uuidString}
            return app
        }
        let a=UUID(),b=UUID()
        let appA=try await session(a)
        let card=ProactiveSuggestion(id:"xctest-real-"+UUID().uuidString,title:"t",reason:"r",actions:[.dismiss],status:.pending,createdAt:ProactiveClock.now())
        ProactiveSuggestionStore.shared.adopt(card)
        _=try await ProactiveLocalBackend().perform(.dismiss,on:card.id)
        XCTAssertNotNil(ProactiveLocalBackend.load()[card.id],"A's write landed under A")
        XCTAssertEqual((UserDefaults.standard.object(forKey:ProactiveDataOwner.key) as? String)?.lowercased(),a.uuidString.lowercased())
        await appA.signOut()
        try await waitUntil {AccountEpoch.shared.currentAccount==nil && ProactiveLocalBackend.load()[card.id]==nil}
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains {$0.op.local==card.id},"A's write-backs gone on the real logout")
        let appB=try await session(b)
        let listed=try await ProactiveLocalBackend().list()
        XCTAssertFalse(listed.contains {$0.id==card.id},"B never sees A's card after the real login")
        await appB.signOut()
        try await waitUntil {AccountEpoch.shared.currentAccount==nil}
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

    /// Codex PR91 p91c-3: sign-out stops every Live Activity after the epoch closed and before its first await.
    /// Model constructed directly (no start / lifecycle gate); one deterministic await on signOut().
    @MainActor func testPR91SignOutStopsLiveActivitiesBeforeFirstAwait() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-pr91-signout-order-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root);AccountEpoch.shared.signOut()}
        let app=try pr91Model(root:root),order=PR91CallOrder()
        AccountEpoch.shared.activate(account:UUID().uuidString)
        app.stopLiveActivities={order.add(AccountEpoch.shared.capture()==nil ? "stopAll(epochClosed)" : "stopAll(epochOpen)")}
        app.signOutTrace={order.add($0)}
        await app.signOut()
        XCTAssertEqual(Array(order.calls.prefix(2)),["stopAll(epochClosed)","firstAwait"],"stopAll runs once, after AccountEpoch.signOut(), before the first await: \(order.calls)")
        XCTAssertEqual(order.calls.filter {$0.hasPrefix("stopAll")}.count,1)
    }

    /// Codex PR91 p91c-5: the launch hook hands the composed repository and the signed-in subject to the migrator.
    /// Synchronous: the injected migrator records the call; no lifecycle gate, no polling.
    @MainActor func testPR91LaunchStartsAtRestMemoryMigration() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-pr91-atrest-launch-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let app=try pr91Model(root:root),order=PR91CallOrder()
        // Codex PR91 p91d-4: no signed-in user yet (cold-start warmUp) — the partition alone carries the subject.
        XCTAssertNil(app.state.user)
        app.atRestMigrator={(_:Repository,partition:AuthenticatedLocalPartition) -> Void in order.add(partition.subject.uuidString+"|"+partition.namespace)}
        let partition=AuthenticatedLocalPartition(issuer:"https://issuer.invalid",subject:UUID(),serverScopeID:UUID())
        _=try await app.openAccountStores(partition:partition,directory:root.appendingPathComponent(partition.namespace,isDirectory:true),prepare:true)
        XCTAssertEqual(order.calls,[partition.subject.uuidString+"|"+partition.namespace],"every opened account repository reaches the at-rest hook")
    }

    /// Codex PR91 v2-1: the PRODUCTION default migrator (no seam override) reaches the shared scheduler from the host's
    /// repository open; the scheduler's trace line is the same text the unified log shows (category "atrest").
    @MainActor func testPR91ProductionHostOpenSchedulesAtRestMigration() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-pr91-atrest-host-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let app=try pr91Model(root:root),lines=PR91CallOrder(),scheduler=AtRestMigrationScheduler.shared
        let savedDelays=scheduler.delays;scheduler.delays=[];scheduler.trace={lines.add($0)}
        defer {scheduler.trace=nil;scheduler.delays=savedDelays}
        let partition=AuthenticatedLocalPartition(issuer:"https://issuer.invalid",subject:UUID(),serverScopeID:UUID())
        _=try await app.openAccountStores(partition:partition,directory:root.appendingPathComponent(partition.namespace,isDirectory:true),prepare:true)
        XCTAssertEqual(lines.calls.first,"scheduled","the host open path schedules the at-rest migration through the production default")
        await scheduler.waitIdle()
        XCTAssertTrue(lines.calls.contains{ $0.hasPrefix("waiting sealer") || $0.hasPrefix("complete") },"scheduler ran an attempt: \(lines.calls)")
    }

    /// Codex PR91 p91d-4: every launch path (local receipt, sign-in, offline trial, workspace) opens its repository via
    /// `openAccountStores`, so none can skip the hook. Guard against a new path calling the raw opener.
    func testPR91EveryRepositoryOpenGoesThroughTheAtRestHook() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/App/NativeAuthApplicationModel.swift")
        let text=try String(contentsOf:source,encoding:.utf8)
        XCTAssertEqual(text.components(separatedBy:"Self.openStores(").count-1,1,"only openAccountStores may call the raw store opener")
        XCTAssertEqual(text.components(separatedBy:"Repository(persistence:").count-1,1,"repositories are created only inside openStores")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy:"openAccountStores(partition:").count-1,4,"local receipt, sign-in, offline trial and workspace paths")
        XCTAssertEqual(text.components(separatedBy:"launchAtRestMigration(repository, partition: partition)").count-1,1,"openAccountStores itself calls the at-rest hook")
    }

    @MainActor private func pr91Model(root:URL) throws -> NativeAuthApplicationModel {
        let configuration=try lifecycleConfiguration(scope:UUID()),storage=LifecycleStorage()
        let manager=NativeAuthSessionManager(configuration:configuration,remote:AnonymousTestRemote(issuer:configuration.issuer),vault:storage,barrier:storage)
        return NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root)
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

    /// Launch-loader fix (iPhone 13 white screen, 792587e): onboarding completed + logout barrier closed next to the old
    /// credential with no rotation journal (an interrupted rotation). Before: chat stayed nil forever behind a full-screen
    /// ProgressView. Now a usable account-neutral local chat opens, the restart need is published for the small capsule,
    /// and 「重新开始」 reaches a fresh identity whose own chat replaces the fallback.
    @MainActor func testUnrecoverableSessionOpensLocalChatWithRestartCapsuleNotADeadLoader() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-launch-fallback-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),clock=AuthTestClock(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
        let remote=AnonymousTestRemote(issuer:configuration.issuer,clock:clock)
        try storage.save(await remote.candidate());try storage.setSignedOut(true)
        let subject=await remote.id
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.success,.success],accessToken:"synthetic.anon.signature")
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retrySchedule:.init(nominalSeconds:[0],jitter:{$0}))
        XCTAssertFalse(app.needsOnboarding)
        await app.start()
        XCTAssertTrue(app.localReadFinished)
        XCTAssertNil(app.chat,"the ambiguous partition must not be opened (fail closed)")
        await app.startExperience()   // the launch auto-experience path: refuses to mint a new identity silently
        XCTAssertTrue(app.sessionRestartNeeded)
        let started=ProcessInfo.processInfo.systemUptime
        await app.ensureLaunchChat()
        let fallback=try XCTUnwrap(app.chat,"a usable local chat must open instead of a dead loader")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,2.0,"the fallback never waits on the network")
        XCTAssertTrue(app.chatIsLaunchFallback)
        XCTAssertNotEqual(fallback.trustedSubjectID,subject,"no account data is shown before the account is resolved")
        XCTAssertFalse(fallback.networkAdmissionAllowed)
        XCTAssertTrue(app.sessionRestartNeeded,"the restart capsule stays visible over the fallback chat")
        let before=await remote.counts()
        await app.restartSession()
        try await waitUntil {app.chat?.trustedSubjectID == subject}
        XCTAssertFalse(app.sessionRestartNeeded)
        XCTAssertFalse(app.chatIsLaunchFallback)
        let after=await remote.counts()
        XCTAssertEqual(after.0,before.0+1,"restart mints exactly one fresh experience identity")
        await app.signOut()
    }

    /// Launch-loader fix: 开始使用 / startExperience racing the launch restore gets `.busy` from the manager. That is a
    /// transient state — it must never be mistaken for an ambiguous credential (the old 「这次会话需要重新开始」 flash).
    @MainActor func testStartExperienceDuringLaunchRestoreIsTransientNotARestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-launch-busy-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scope=UUID(),subject=UUID(),clock=LifecycleClock(),storage=LifecycleStorage(),configuration=try lifecycleConfiguration(scope:scope)
        let remote=LifecycleRemote(issuer:configuration.issuer,subject:subject,clock:clock)
        try storage.save(.init(issuer:configuration.issuer,user:.init(id:subject),accessToken:"offline.lifecycle.signature",refreshToken:"synthetic-lifecycle-only",expiresAt:clock.now().addingTimeInterval(-60)))
        let manager=NativeAuthSessionManager(configuration:configuration,remote:remote,vault:storage,barrier:storage,now:{clock.now()})
        let resolver=LifecycleWorkspaceResolver(subject:subject,scope:scope,steps:[.success,.success])
        let app=NativeAuthApplicationModel(configuration:configuration,manager:manager,vault:storage,barrier:storage,root:root,workspaceResolver:resolver,retrySchedule:.init(nominalSeconds:[0],jitter:{$0}))
        let startup=Task {await app.start()}
        try await waitUntil {await remote.refreshIsPending()}
        XCTAssertTrue(try storage.isSignedOut(),"inside the rotation window the barrier is closed")
        let rotating=await manager.rotationInFlight()
        XCTAssertTrue(rotating)
        let tap=Task {await app.startExperience()}
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertFalse(app.requiresSessionRestart,"a tap inside the rotation window is not an ambiguous session")
        await remote.releaseRefresh()
        await tap.value;await startup.value
        try await waitUntil {app.chat?.trustedSubjectID == subject}
        XCTAssertFalse(app.requiresSessionRestart);XCTAssertFalse(app.recoveryImpossible);XCTAssertNil(app.error)
        await app.signOut()
    }

    /// The splash plays on the first run only; every later launch goes straight to the chat's first frame.
    func testLaunchSplashIsFirstRunOnly() throws {
        let suite="xctest.launchgate."+UUID().uuidString,defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        XCTAssertTrue(LaunchMarkGate.isFirstRun(defaults,arguments:[]))
        CatpawOnboarding.markCompleted(defaults)
        XCTAssertFalse(LaunchMarkGate.isFirstRun(defaults,arguments:[]))
        let fresh=try XCTUnwrap(UserDefaults(suiteName:suite+".b"));defer {fresh.removePersistentDomain(forName:suite+".b")}
        XCTAssertFalse(LaunchMarkGate.isFirstRun(fresh,arguments:[CatpawOnboarding.skipArgument]))
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

/// Thread-safe call recorder for the PR91 ordering tests (observers fire from nonisolated code).
private final class PR91CallOrder:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[String]=[]
    func add(_ value:String){lock.lock();values.append(value);lock.unlock()}
    var calls:[String] {lock.lock();defer{lock.unlock()};return values}
}

/// Restored PR91 p91c-1 (appended as an extension so the reviewed scan line pins above stay put).
extension NativeAuthApplicationLifecycleTests {
    /// PR91 p91c-1 (restored from the dropped PR91ProactiveNativeTests): an undo whose account token expired (sign-out /
    /// switch) never deletes a system reminder — the EventKit delete count stays 0.
    @MainActor func testPR91ExpiredTokenNeverDeletesSystemReminder() async throws {
        let id="pr91-stale-"+UUID().uuidString
        AccountEpoch.shared.activate(account:UUID().uuidString)
        defer {AccountEpoch.shared.signOut()}
        ProactiveEngine.shared.recordPendingReminderForTest(id,operationID:"op-"+UUID().uuidString)
        let stale=AccountEpoch.shared.capture()
        XCTAssertNotNil(stale)
        AccountEpoch.shared.signOut()   // token expiry
        XCTAssertFalse(AccountEpoch.shared.isValid(stale))
        let before=ProactiveEngine.shared.reminderDeletes
        var threw=false
        do {try await ProactiveEngine.shared.removeReminderChecked(id,token:stale)} catch {threw=true}
        XCTAssertTrue(threw,"expired token ⇒ not reported as undone")
        XCTAssertEqual(ProactiveEngine.shared.reminderDeletes-before,0,"no EventKit delete with an expired token")
        threw=false
        do {try await ProactiveEngine.shared.removeReminderChecked(id,token:nil)} catch {threw=true}
        XCTAssertTrue(threw)
        XCTAssertEqual(ProactiveEngine.shared.reminderDeletes-before,0,"no EventKit delete when signed out")
    }
}
