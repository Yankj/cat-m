import Foundation

public actor NativeAuthSessionManager {
    private let configuration: NativeAuthConfiguration
    private let remote: any NativeAuthRemote
    private let vault: any NativeAuthVault
    private let barrier: any NativeAuthLogoutBarrier
    private let now: @Sendable () -> Date
    private var logoutInProgress = false
    private var generation = 0
    private var credential: NativeAuthCredential?
    private var refreshFlight: (id: UUID, epoch: Int, task: Task<NativeAuthCredential, Error>)?
    private var pendingPersistence: NativeAuthCredential?
    // A received rotation/signup result can retry read-only user validation in this process.
    // It grants no authority and is discarded on logout; an uncertain refresh is never replayed.
    private var recoveryCandidate: NativeAuthCredential?
    private var value = NativeAuthSnapshot(phase: .signedOut, user: nil, generation: 0, message: nil)
    private var observers: [UUID: AsyncStream<NativeAuthSnapshot>.Continuation] = [:]
    public init(configuration: NativeAuthConfiguration, remote: any NativeAuthRemote, vault: any NativeAuthVault, barrier: any NativeAuthLogoutBarrier, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.remote = remote; self.vault = vault; self.barrier = barrier; self.now = now
    }
    public func snapshot() -> NativeAuthSnapshot { value }
    public func canRetryRecovery() throws -> Bool {
        guard !logoutInProgress, pendingPersistence == nil else { return false }
        if recoveryCandidate != nil { return true }
        return try !barrier.isSignedOut() && vault.load() != nil
    }
    public func restore() async throws {
        try Task.checkCancellation()
        guard !logoutInProgress, value.phase != .restoring, value.phase != .signingIn else { throw NativeAuthError.busy }
        guard pendingPersistence == nil else { throw NativeAuthError.storage }
        if credential != nil { _ = try await authorization(subject: credential!.user.id); return }
        generation += 1; let epoch = generation; publish(.restoring)
        do {
            let saved: NativeAuthCredential
            if let candidate = recoveryCandidate { saved = candidate }
            else {
                guard try !barrier.isSignedOut(), let stored = try vault.load() else { publish(.signedOut); return }
                saved = stored
            }
            guard saved.issuer == configuration.issuer else { try expireLocally(); return }
            // The saved value remains a candidate. Cold restore publishes neither
            // its account nor an authorizable token until remote validation finishes.
            let candidate: NativeAuthCredential
            if recoveryCandidate != nil {
                guard saved.expiresAt > now() else { throw NativeAuthError.loginRequired }
                candidate = saved
            } else if saved.expiresAt <= now().addingTimeInterval(30) {
                try barrier.setSignedOut(true)
                candidate = try await remote.refresh(refreshToken: saved.refreshToken)
                try checkActive(epoch)
                guard candidate.user.id == saved.user.id else { throw NativeAuthError.invalidResponse }
                try validate(candidate, user: candidate.user)
                recoveryCandidate = candidate
            } else { candidate = saved }
            let user = try await remote.user(accessToken: candidate.accessToken)
            try checkActive(epoch)
            try validate(candidate, user: user)
            if recoveryCandidate != nil { try persistVerified(candidate, epoch: epoch) }
            else { try checkActive(epoch); credential = candidate; publish(.authenticated) }
        } catch {
            guard epoch == generation else { throw NativeAuthError.cancelled }
            credential = nil
            if error is CancellationError { try closeLocally(); throw NativeAuthError.cancelled }
            let safe = error as? NativeAuthError ?? .storage
            if safe == .loginRequired || safe == .invalidResponse { try expireLocally() }
            else { publish(safe == .storage ? .storageBlocked : .signedOut, message: safe.localizedDescription) }
            throw safe
        }
    }
    public func signOut() async throws {
        guard !logoutInProgress else { throw NativeAuthError.busy };logoutInProgress = true;defer { logoutInProgress = false }
        let token = credential?.accessToken ?? pendingPersistence?.accessToken
        generation += 1;let epoch = generation;refreshFlight?.task.cancel();refreshFlight = nil;credential = nil;pendingPersistence = nil;recoveryCandidate = nil
        var storageFailure = false,remoteFailure = false
        do { try barrier.setSignedOut(true) } catch { storageFailure = true }
        publish(storageFailure ? .storageBlocked : .signedOut)
        if let token {
            do { try await remote.revokeApplicationSession(accessToken:token) } catch { remoteFailure = true }
            do { try await remote.signOut(accessToken:token) } catch { remoteFailure = true }
        }
        // No network failure/cancellation may skip final local credential removal.
        do { try vault.clear() } catch { storageFailure = true }
        guard epoch == generation else { throw NativeAuthError.cancelled }
        if storageFailure { publish(.storageBlocked,message:NativeAuthError.storage.localizedDescription);throw NativeAuthError.storage }
        publish(.signedOut,message:remoteFailure ? "已在此设备退出；服务端会话撤销未确认。" : nil)
    }
    public func retryPersistence() throws {
        guard let pending = pendingPersistence, value.phase == .storageBlocked else { throw NativeAuthError.loginRequired }
        try validate(pending, user: pending.user)
        do { try vault.save(pending); try barrier.setSignedOut(false) }
        catch { publish(.storageBlocked, message: NativeAuthError.storage.localizedDescription); throw NativeAuthError.storage }
        pendingPersistence = nil; recoveryCandidate = nil; refreshFlight = nil; credential = pending; publish(.authenticated)
    }
    public func cancelLogin() throws { try closeLocally() }
    public func rejectAuthorization(subject: UUID) throws { if credential?.user.id == subject { try expireLocally() } }
    private func closeLocally() throws {
        generation += 1; refreshFlight?.task.cancel(); refreshFlight = nil; credential = nil; pendingPersistence = nil; recoveryCandidate = nil
        do { try barrier.setSignedOut(true); try vault.clear() }
        catch { publish(.storageBlocked, message: NativeAuthError.storage.localizedDescription); throw NativeAuthError.storage }
        publish(.signedOut)
    }
    public func receiveCallback(_ url: URL) throws { throw NativeAuthError.callbackUnsupported }
    public func changes() -> AsyncStream<NativeAuthSnapshot> {
        let id = UUID()
        return AsyncStream { c in observers[id] = c; c.yield(value); c.onTermination = { [weak self] _ in guard let owner = self else { return }; Task { await owner.detach(id) } } }
    }
    private func detach(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish(_ phase: NativeAuthSnapshot.Phase, message: String? = nil) {
        value = NativeAuthSnapshot(phase: phase, user: credential?.user, generation: generation, message: message)
        for observer in observers.values { observer.yield(value) }
    }
    public func signUp(email: String,password: String) async throws -> Bool {
        guard !logoutInProgress,credential == nil,value.phase != .signingIn,value.phase != .restoring else { throw NativeAuthError.busy }
        guard !email.isEmpty,email.utf8.count <= 254,email.contains("@"),password.utf8.count >= 8,password.utf8.count <= 4096 else { throw NativeAuthError.invalidCredentials }
        try Task.checkCancellation();try barrier.setSignedOut(true);generation += 1;let epoch = generation;publish(.signingIn)
        do {
            let result = try await remote.signUp(email:email,password:password);try checkActive(epoch)
            switch result {
            case .emailConfirmationRequired:
                try vault.clear();credential = nil;pendingPersistence = nil;publish(.signedOut);return true
            case .authenticated(let candidate):
                let user = try await remote.user(accessToken:candidate.accessToken);try checkActive(epoch);try validate(candidate,user:user);try persistVerified(candidate,epoch:epoch);return false
            }
        } catch {
            guard epoch == generation else { throw NativeAuthError.cancelled };credential = nil
            if error is CancellationError { try closeLocally();throw NativeAuthError.cancelled }
            let safe = error as? NativeAuthError ?? .unavailable;publish(safe == .storage ? .storageBlocked : .signedOut,message:safe.localizedDescription);throw safe
        }
    }
    public func signIn(email: String, password: String) async throws {
        guard !logoutInProgress, credential == nil, value.phase != .signingIn, value.phase != .restoring else { throw NativeAuthError.busy }
        guard !email.isEmpty, email.utf8.count <= 254, email.contains("@"), !password.isEmpty, password.utf8.count <= 4096 else { throw NativeAuthError.invalidCredentials }
        try Task.checkCancellation()
        do { try barrier.setSignedOut(true) } catch { publish(.storageBlocked, message: NativeAuthError.storage.localizedDescription); throw NativeAuthError.storage }
        generation += 1; let epoch = generation; publish(.signingIn)
        do {
            let candidate = try await remote.signIn(email: email, password: password)
            try checkActive(epoch)
            let user = try await remote.user(accessToken: candidate.accessToken)
            try checkActive(epoch)
            try validate(candidate, user: user)
            try persistVerified(candidate, epoch: epoch)
        } catch {
            guard epoch == generation else { throw NativeAuthError.cancelled }
            credential = nil
            if error is CancellationError { try closeLocally(); throw NativeAuthError.cancelled }
            let safe = error as? NativeAuthError ?? .unavailable
            publish(safe == .storage ? .storageBlocked : .signedOut, message: safe.localizedDescription)
            throw safe
        }
    }
    /// Launch prewarming and the explicit entrance share this identity lifecycle.
    public func startExperience() async throws {
        guard !logoutInProgress,value.phase != .restoring,value.phase != .signingIn else { throw NativeAuthError.busy }
        guard pendingPersistence == nil,value.phase != .storageBlocked else { throw NativeAuthError.storage }
        try Task.checkCancellation()
        if recoveryCandidate != nil {
            try await restore()
            return
        }
        let saved: NativeAuthCredential?
        do { saved = try vault.load() } catch { throw NativeAuthError.storage }
        if credential != nil || saved != nil {
            // A failed/uncertain refresh must never silently create a new identity.
            if credential == nil,try barrier.isSignedOut() { throw NativeAuthError.sessionRecoveryRequired }
            try await restore()
            guard value.phase == .authenticated else { throw NativeAuthError.loginRequired }
            return
        }
        try await restore()
        guard !logoutInProgress,credential == nil,pendingPersistence == nil,value.phase == .signedOut else { throw NativeAuthError.busy }
        do { try barrier.setSignedOut(true) } catch { publish(.storageBlocked,message:NativeAuthError.storage.localizedDescription);throw NativeAuthError.storage }
        generation += 1;let epoch = generation;publish(.signingIn)
        do {
            let candidate = try await remote.signInAnonymously();try checkActive(epoch)
            guard candidate.user.isAnonymous else { throw NativeAuthError.invalidResponse }
            try validate(candidate, user: candidate.user)
            recoveryCandidate = candidate
            let user = try await remote.user(accessToken:candidate.accessToken);try checkActive(epoch)
            try validate(candidate,user:user);try persistVerified(candidate,epoch:epoch)
        } catch {
            guard epoch == generation else { throw NativeAuthError.cancelled };credential = nil
            if error is CancellationError { try closeLocally();throw NativeAuthError.cancelled }
            let safe = error as? NativeAuthError ?? .unavailable
            publish(safe == .storage ? .storageBlocked : .signedOut,message:safe.localizedDescription);throw safe
        }
    }
    private func checkActive(_ epoch: Int) throws {
        guard epoch == generation else { throw NativeAuthError.cancelled }
        try Task.checkCancellation()
    }
    private func persistVerified(_ candidate: NativeAuthCredential, epoch: Int) throws {
        try checkActive(epoch)
        pendingPersistence = candidate
        do {
            try vault.save(candidate); try checkActive(epoch)
            try barrier.setSignedOut(false); try checkActive(epoch)
        } catch is CancellationError { throw CancellationError() }
        catch { throw NativeAuthError.storage }
        pendingPersistence = nil; recoveryCandidate = nil; credential = candidate; publish(.authenticated)
    }
    private func validate(_ c: NativeAuthCredential, user: NativeAuthUser) throws {
        guard c.issuer == configuration.issuer, c.user.id == user.id, c.user.isAnonymous == user.isAnonymous,
              c.accessToken.utf8.count < 8192, c.accessToken.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              !c.refreshToken.isEmpty, c.refreshToken.utf8.count < 8192, c.expiresAt > now() else { throw NativeAuthError.invalidResponse }
    }
    public func authorization(subject: UUID) async throws -> String {
        try Task.checkCancellation()
        guard [.authenticated,.refreshing].contains(value.phase), let credential, credential.user.id == subject else { throw NativeAuthError.loginRequired }
        let epoch = generation
        let current = credential.expiresAt > now().addingTimeInterval(30) ? credential : try await refreshCurrent()
        try Task.checkCancellation()
        guard generation == epoch, [.authenticated,.refreshing].contains(value.phase), self.credential?.user.id == subject else { throw NativeAuthError.loginRequired }
        return "Bearer " + current.accessToken
    }
    private func refreshCurrent() async throws -> NativeAuthCredential {
        guard let original = credential else { throw NativeAuthError.loginRequired }
        let flight: (id: UUID, epoch: Int, task: Task<NativeAuthCredential, Error>)
        if let current = refreshFlight { flight = current }
        else {
            // Crash during rotation must not restore and resubmit an uncertain old refresh token.
            do { try barrier.setSignedOut(true) }
            catch { credential = nil; publish(.storageBlocked, message: NativeAuthError.storage.localizedDescription); throw NativeAuthError.storage }
            let remote = self.remote, epoch = generation
            flight = (UUID(), epoch, Task {
                let next = try await remote.refresh(refreshToken: original.refreshToken)
                try self.checkActive(epoch)
                guard next.user.id == original.user.id else { throw NativeAuthError.invalidResponse }
                try self.validate(next, user: next.user)
                self.recoveryCandidate = next
                let user = try await remote.user(accessToken: next.accessToken)
                try self.checkActive(epoch)
                guard next.user.id == original.user.id, user.id == original.user.id,next.user.isAnonymous == user.isAnonymous else { throw NativeAuthError.invalidResponse }
                return next
            })
            refreshFlight = flight; publish(.refreshing)
        }
        do {
            let next = try await flight.task.value
            try checkActive(flight.epoch)
            if refreshFlight?.id == flight.id {
                try validate(next, user: next.user)
                try persistVerified(next, epoch: flight.epoch)
                refreshFlight = nil
            }
            if pendingPersistence != nil, value.phase == .storageBlocked { throw NativeAuthError.storage }
            guard let current = credential, current.user.id == original.user.id else { throw NativeAuthError.loginRequired }
            return current
        } catch {
            guard generation == flight.epoch else { throw NativeAuthError.cancelled }
            // A cancelled waiter detaches; a surviving waiter owns the same flight.
            if error is CancellationError { throw error }
            refreshFlight = nil
            if error as? NativeAuthError == .storage { credential = nil; publish(.storageBlocked, message: NativeAuthError.storage.localizedDescription); throw NativeAuthError.storage }
            if let safe=error as? NativeAuthError,[.unavailable,.rateLimited].contains(safe),recoveryCandidate != nil {
                credential=nil;publish(.signedOut,message:safe.localizedDescription);throw safe
            }
            try expireLocally()
            throw NativeAuthError.loginRequired
        }
    }
    private func expireLocally() throws {
        generation += 1; refreshFlight?.task.cancel(); refreshFlight = nil; credential = nil; pendingPersistence = nil; recoveryCandidate = nil
        do { try barrier.setSignedOut(true); try vault.clear() }
        catch { publish(.storageBlocked, message: NativeAuthError.storage.localizedDescription); throw NativeAuthError.storage }
        publish(.loginRequired, message: NativeAuthError.loginRequired.localizedDescription)
    }

}
