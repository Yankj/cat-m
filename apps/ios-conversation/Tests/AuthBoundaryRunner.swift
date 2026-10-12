import Foundation
import Darwin

// Memory vault only; no Keychain calls, no token strings in output.
actor QAAuthRemote: NativeAuthRemote {
    let issuer: String; let subject: UUID
    private var userWait: CheckedContinuation<NativeAuthUser, Error>?
    private var refreshWait: CheckedContinuation<NativeAuthCredential, Error>?
    init(issuer: String, subject: UUID) { self.issuer = issuer; self.subject = subject }
    func signIn(email: String, password: String) async throws -> NativeAuthCredential { candidate() }
    func candidate() -> NativeAuthCredential { .init(issuer: issuer, user: .init(id: subject), accessToken: "qa.access.signature", refreshToken: "qa-refresh-not-a-credential", expiresAt: Date().addingTimeInterval(3600)) }
    func user(accessToken: String) async throws -> NativeAuthUser { try await withCheckedThrowingContinuation { userWait = $0 } }
    func refresh(refreshToken: String) async throws -> NativeAuthCredential { try await withCheckedThrowingContinuation { refreshWait = $0 } }
    func signOut(accessToken: String) async throws { }
    func pendingUser() -> Bool { userWait != nil }
    func pendingRefresh() -> Bool { refreshWait != nil }
    func rejectUser() { userWait?.resume(throwing: NativeAuthError.loginRequired); userWait = nil }
    func rejectRefresh() { refreshWait?.resume(throwing: NativeAuthError.loginRequired); refreshWait = nil }
    func acceptUser() { userWait?.resume(returning: .init(id: subject)); userWait = nil }
}
@main struct AuthBoundaryRunner {
    static func main() async throws {
        let config = try NativeAuthConfiguration(projectURL: URL(string: "https://abcdefghijklmnopqrst.supabase.co")!, publishableKey: "sb_publishable_qa_public_value", backendOrigin: URL(string: "https://backend.example.invalid")!, serverScopeID: UUID())
        var results: [[String: Any]] = []
        func awaitGate(_ condition: @escaping () async -> Bool) async throws {
            for _ in 0..<10000 { if await condition() { return }; await Task.yield() }
            throw NativeAuthError.unavailable
        }
        // Validity is deliberately still UNKNOWN at the gate. The remote later rejects.
        do {
            let subject = UUID(), storage = AuthTestStorage(), remote = QAAuthRemote(issuer: config.issuer, subject: subject)
            try storage.save(.init(issuer: config.issuer, user: .init(id: subject), accessToken: "qa.saved.signature", refreshToken: "qa-saved-not-a-credential", expiresAt: Date().addingTimeInterval(3600)))
            let manager = NativeAuthSessionManager(configuration: config, remote: remote, vault: storage, barrier: storage)
            let restoration = Task { try await manager.restore() }; try await awaitGate { await remote.pendingUser() }
            var granted = false
            do { _ = try await manager.authorization(subject: subject); granted = true } catch { }
            let pending = await manager.snapshot(); await remote.rejectUser(); _ = try? await restoration.value
            let closed = await manager.snapshot()
            let good = !granted && closed.user == nil
            results.append(["case": "A01 authorization while saved-session user validation is pending", "passed": good, "authorization_granted_before_validation": granted, "pending_phase": String(describing: pending.phase), "eventual_rejection_closed_identity": closed.user == nil, "external_requests": 0])
            print("\(good ? "PASS" : "FAIL"): A01 no authorization before saved user validation; granted=\(granted)")
        }
        do {
            let subject = UUID(), storage = AuthTestStorage(), remote = QAAuthRemote(issuer: config.issuer, subject: subject)
            try storage.save(.init(issuer: config.issuer, user: .init(id: subject), accessToken: "qa.expired.signature", refreshToken: "qa-expired-not-a-credential", expiresAt: Date().addingTimeInterval(-1)))
            let manager = NativeAuthSessionManager(configuration: config, remote: remote, vault: storage, barrier: storage)
            let restoration = Task { try await manager.restore() }; try await awaitGate { await remote.pendingRefresh() }
            let pending = await manager.snapshot()
            // EXACT NativeAuthApplicationModel.receive admission predicate, recorded as
            // source-derived UI exposure risk; no claim that this runner executed SwiftUI.
            let appWouldOpen = [.authenticated, .refreshing].contains(pending.phase) && pending.user != nil
            await remote.rejectRefresh(); _ = try? await restoration.value
            let closed = await manager.snapshot(), good = !appWouldOpen && closed.user == nil
            results.append(["case": "A02 expired cold restore cannot expose unvalidated account", "passed": good, "phase": String(describing: pending.phase), "user_present": pending.user != nil, "source_app_partition_predicate": appWouldOpen, "SwiftUI_executed": false, "eventual_rejection_closed_identity": closed.user == nil])
            print("\(good ? "PASS" : "FAIL"): A02 no account publication during cold restore refresh; source_app_partition_predicate=\(appWouldOpen)")
        }
        do {
            let subject = UUID(), storage = AuthTestStorage(), remote = QAAuthRemote(issuer: config.issuer, subject: subject)
            let manager = NativeAuthSessionManager(configuration: config, remote: remote, vault: storage, barrier: storage)
            let login = Task { try await manager.signIn(email: "qa@example.invalid", password: "synthetic-only") }
            try await awaitGate { await remote.pendingUser() }; login.cancel(); await remote.acceptUser()
            var succeeded = false; do { try await login.value; succeeded = true } catch { }
            let state = await manager.snapshot(), persisted = try storage.load()
            let good = !succeeded && state.user == nil && persisted == nil
            results.append(["case": "A03 caller Task cancellation during user revalidation cannot persist login", "passed": good, "cancelled_task_returned_success": succeeded, "authenticated": state.phase == .authenticated, "credential_persisted": (try storage.load()) != nil, "manager_cancelLogin_called": false])
            print("\(good ? "PASS" : "FAIL"): A03 cancelled login Task cannot publish/persist credential; succeeded=\(succeeded)")
            try await manager.signOut()
        }
        let failed = results.filter { $0["passed"] as? Bool == false }.count
        try JSONSerialization.data(withJSONObject: ["results": results, "passed": results.count - failed, "failed": failed, "keychain_calls": 0, "external_requests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        if failed > 0 { exit(1) }
    }
}
