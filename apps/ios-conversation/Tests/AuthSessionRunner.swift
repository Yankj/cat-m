import Foundation
@main struct AuthSessionRunner {
    static func main() async throws {
        let config = try NativeAuthConfiguration(projectURL: URL(string:"https://abcdefghijklmnopqrst.supabase.co")!, publishableKey:"sb_publishable_test_public_value", backendOrigin:URL(string:"https://backend.example.invalid")!,serverScopeID:UUID())
        try authCheck(config.issuer == "https://abcdefghijklmnopqrst.supabase.co/auth/v1", "explicit public configuration is accepted without identity or secret inference")
        let storage = AuthTestStorage(), id = UUID(), remote = AuthTestRemote(issuer: config.issuer, id: id)
        let manager = NativeAuthSessionManager(configuration: config, remote: remote, vault: storage, barrier: storage)
        try await manager.signIn(email: "synthetic@example.invalid", password: "not-a-real-password")
        let state = await manager.snapshot()
        try authCheck(state.phase == .authenticated && state.user?.id == id && (try storage.load())?.user.id == id, "explicit password login validates user before secure persistence and authenticated event")
        let clock = AuthTestClock(), v2 = AuthTestStorage(), r2 = AuthTestRemote(issuer: config.issuer, id: id, clock: clock)
        let m2 = NativeAuthSessionManager(configuration: config, remote: r2, vault: v2, barrier: v2, now: { clock.now() })
        try await m2.signIn(email:"synthetic@example.invalid",password:"test-only")
        clock.advance(4000)
        async let a = m2.authorization(subject:id); async let b = m2.authorization(subject:id)
        let tokens = try await [a,b], refreshCount = await r2.refreshCount()
        try authCheck(tokens[0] == tokens[1] && refreshCount == 1, "concurrent expired-token consumers share exactly one rotating refresh request")
        let restarted = NativeAuthSessionManager(configuration: config, remote: r2, vault: v2, barrier: v2, now: { clock.now() })
        try await restarted.restore()
        let restored = await restarted.snapshot()
        try authCheck(restored.user?.id == id && restored.phase == .authenticated, "restart revalidates persisted user before exposing account")
        try await restarted.signOut()
        let signedOut = await restarted.snapshot(), after = NativeAuthSessionManager(configuration: config, remote: r2, vault: v2, barrier: v2)
        try await after.restore()
        let afterState = await after.snapshot()
        try authCheck(signedOut.user == nil && afterState.phase == .signedOut && (try v2.load()) == nil, "explicit logout persists its barrier and cannot restore the previous account")
        let failing = AuthTestStorage(), r3 = AuthTestRemote(issuer:config.issuer,id:id), m3 = NativeAuthSessionManager(configuration:config,remote:r3,vault:failing,barrier:failing)
        failing.failures(save:true)
        do { try await m3.signIn(email:"synthetic@example.invalid",password:"test-only"); throw NativeAuthError.invalidResponse } catch NativeAuthError.storage { }
        let blocked = await m3.snapshot()
        try authCheck(blocked.phase == .storageBlocked && blocked.user == nil && (try failing.load()) == nil, "failed secure save emits no authenticated identity")
        failing.failures(); try await m3.retryPersistence(); let count = await r3.counts()
        let s3 = await m3.snapshot()
        try authCheck(count == 1 && s3.phase == .authenticated, "persistence retry does not duplicate login submission")
        failing.failures(clear:true)
        do { try await m3.signOut(); throw NativeAuthError.invalidResponse } catch NativeAuthError.storage { }
        let m4 = NativeAuthSessionManager(configuration:config,remote:r3,vault:failing,barrier:failing); try await m4.restore()
        try authCheck((await m4.snapshot()).user == nil && (try failing.isSignedOut()), "durable logout barrier fences failed Keychain deletion on restart")
        let v5 = AuthTestStorage(), r5 = AuthTestRemote(issuer:config.issuer,id:id), m5 = NativeAuthSessionManager(configuration:config,remote:r5,vault:v5,barrier:v5)
        await r5.behavior(lateLogin:true)
        let login = Task { try await m5.signIn(email:"synthetic@example.invalid",password:"test-only") }
        try await Task.sleep(nanoseconds:20_000_000); try await m5.cancelLogin()
        do { try await login.value; throw NativeAuthError.invalidResponse } catch NativeAuthError.cancelled { }
        try authCheck((await m5.snapshot()).user == nil && (try v5.load()) == nil, "cancel epoch blocks late login callback from restoring account")
        let v6 = AuthTestStorage(), r6 = AuthTestRemote(issuer:config.issuer,id:id,clock:clock), m6 = NativeAuthSessionManager(configuration:config,remote:r6,vault:v6,barrier:v6,now:{clock.now()})
        try await m6.signIn(email:"synthetic@example.invalid",password:"test-only"); clock.advance(4000)
        let cancelled = Task { try await m6.authorization(subject:id) }, survivor = Task { try await m6.authorization(subject:id) }
        try await Task.sleep(nanoseconds:20_000_000); cancelled.cancel(); _ = try await survivor.value
        do { _ = try await cancelled.value; throw NativeAuthError.invalidResponse } catch is CancellationError { }
        let c6 = await r6.refreshCount(), s6 = await m6.snapshot()
        try authCheck(c6 == 1 && s6.phase == .authenticated, "one cancelled waiter cannot cancel the shared rotating refresh")
        clock.advance(4000); await r6.behavior(failRefresh:true)
        do { _ = try await m6.authorization(subject:id); throw NativeAuthError.invalidResponse } catch NativeAuthError.loginRequired { }
        do { _ = try await m6.authorization(subject:id); throw NativeAuthError.invalidResponse } catch NativeAuthError.loginRequired { }
        try authCheck((await r6.refreshCount()) == 2 && (try v6.isSignedOut()), "ambiguous rotated refresh failure requires login and is never blindly retried")
        do { try await m6.receiveCallback(URL(string:"catpaw://login#access_token=synthetic")!); throw NativeAuthError.invalidResponse } catch NativeAuthError.callbackUnsupported { }
        try authCheck((await m6.snapshot()).phase == .loginRequired, "external callback cannot inject a session; no OAuth URL scheme is registered")
        let pA = AuthenticatedLocalPartition(issuer:config.issuer,subject:id,serverScopeID:config.serverScopeID!), pB = AuthenticatedLocalPartition(issuer:config.issuer,subject:UUID(),serverScopeID:config.serverScopeID!)
        try authCheck(pA.namespace != pB.namespace && pA.scope != pB.scope && pA.scope.profileID != id, "account partitions derive local IDs and do not equate local identity with server owner")
        let transport = AuthTestHTTPTransport(id:id), http = NativeAuthHTTPRemote(configuration:config,transport:transport)
        let httpSession = try await http.signIn(email:"synthetic@example.invalid",password:"fixture-only")
        _ = try await http.user(accessToken:httpSession.accessToken); _ = try await http.refresh(refreshToken:httpSession.refreshToken); try await http.signOut(accessToken:httpSession.accessToken)
        let requests = await transport.captured(), passwordBody = try JSONSerialization.jsonObject(with:requests[0].httpBody!) as! [String:String], refreshBody = try JSONSerialization.jsonObject(with:requests[2].httpBody!) as! [String:String]
        try authCheck(requests.count == 4 && requests[0].url?.path == "/auth/v1/token" && requests[0].url?.query == "grant_type=password" && passwordBody["email"] == "synthetic@example.invalid" && passwordBody["password"] == "fixture-only", "HTTP password contract is one explicit POST with no implicit account creation")
        try authCheck(requests[1].httpMethod == "GET" && requests[1].value(forHTTPHeaderField:"Authorization") == "Bearer fixture.http.signature" && requests[1].value(forHTTPHeaderField:"apikey") == config.publishableKey, "GET user uses public apikey plus user JWT and verifies the returned subject")
        try authCheck(refreshBody.count == 1 && refreshBody["refresh_token"] == "synthetic-refresh-only" && requests[2].url?.query == "grant_type=refresh_token" && requests[3].url?.query == "scope=local", "refresh and device-local logout follow official HTTP contracts")
        await transport.response(status:500)
        do { _ = try await http.refresh(refreshToken:"synthetic"); throw NativeAuthError.invalidResponse } catch NativeAuthError.unavailable { }
        let callsAfterError = await transport.captured()
        try authCheck(callsAfterError.count == 5 && !NativeAuthError.unavailable.localizedDescription.contains("never-show-sensitive-body"), "transport failure performs no blind retry and exposes no raw response")
        await transport.response(anonymous:true)
        var rejectedAnonymous = false
        do { _ = try await http.signIn(email:"synthetic@example.invalid",password:"fixture-only") } catch NativeAuthError.invalidResponse { rejectedAnonymous = true }
        let anonymousCalls = await transport.captured()
        try authCheck(rejectedAnonymous && anonymousCalls.count == 6, "password login rejects an unexpected anonymous identity")
        do { _ = try NativeAuthConfiguration(projectURL:config.projectURL,publishableKey:"sb_secret_test_only",backendOrigin:config.backendOrigin,serverScopeID:config.serverScopeID!); throw NativeAuthError.invalidResponse } catch NativeAuthError.invalidConfiguration { }
        try authCheck(try NativeAuthConfiguration.read([:]) == nil, "missing public config fails closed and secret-role keys are never accepted")
        let s7 = AuthTestStorage(), r7 = AuthTestRemote(issuer:config.issuer,id:id), m7 = NativeAuthSessionManager(configuration:config,remote:r7,vault:s7,barrier:s7)
        await r7.behavior(lateLogin:true); let oneLogin = Task { try await m7.signIn(email:"synthetic@example.invalid",password:"fixture-only") }
        try await Task.sleep(nanoseconds:20_000_000)
        do { try await m7.signIn(email:"synthetic@example.invalid",password:"fixture-only"); throw NativeAuthError.invalidResponse } catch NativeAuthError.busy { }
        try await oneLogin.value; let oneCount = await r7.counts()
        try authCheck(oneCount == 1, "double login taps cannot submit two password grants")
        let s8 = AuthTestStorage(), r8 = AuthTestRemote(issuer:config.issuer,id:id,clock:clock), m8 = NativeAuthSessionManager(configuration:config,remote:r8,vault:s8,barrier:s8,now:{clock.now()})
        try await m8.signIn(email:"synthetic@example.invalid",password:"fixture-only"); clock.advance(4000)
        let rotating = Task { try await m8.authorization(subject:id) }; try await Task.sleep(nanoseconds:20_000_000)
        let restartDuringRotation = NativeAuthSessionManager(configuration:config,remote:r8,vault:s8,barrier:s8,now:{clock.now()}); try await restartDuringRotation.restore()
        let rotationRestart = await restartDuringRotation.snapshot()
        try authCheck(rotationRestart.user == nil && (try s8.isSignedOut()), "crash during refresh rotation cannot restore and resend the old token")
        try await m8.signOut()
        do { _ = try await rotating.value; throw NativeAuthError.invalidResponse } catch NativeAuthError.cancelled { }
        let logoutState = await m8.snapshot()
        try authCheck(logoutState.user == nil && (try s8.load()) == nil, "logout epoch prevents refresh completion from reviving the account")
        let s9 = AuthTestStorage(), r9 = AuthTestRemote(issuer:config.issuer,id:id,clock:clock), m9 = NativeAuthSessionManager(configuration:config,remote:r9,vault:s9,barrier:s9,now:{clock.now()})
        try await m9.signIn(email:"synthetic@example.invalid",password:"fixture-only"); clock.advance(4000); s9.failures(save:true)
        let waiters = (0..<2).map { _ in Task { try await m9.authorization(subject:id) } }
        var storageErrors = 0
        for waiter in waiters { do { _ = try await waiter.value } catch NativeAuthError.storage { storageErrors += 1 } }
        let blockedRefresh = await m9.snapshot(); try authCheck(storageErrors == 2 && blockedRefresh.user == nil, "both refresh waiters observe failed persistence without authenticated success")
        s9.failures(); try await m9.retryPersistence(); let rotationCount = await r9.refreshCount()
        try authCheck(rotationCount == 1, "retrying known rotated credential persistence never repeats the refresh grant")
    }
}
