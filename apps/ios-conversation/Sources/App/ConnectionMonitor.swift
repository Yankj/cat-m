import Foundation
import Network
import Combine

/// Observable connection state source for the R7 status capsule (UI owned by the design lane).
/// Network reachability comes from NWPathMonitor; stream health is reported by
/// ConversationSessionService while it resumes an interrupted turn.
@MainActor public final class ConnectionMonitor: ObservableObject {
    public static let shared = ConnectionMonitor()
    @Published public private(set) var state: ConversationConnectionState = .online
    @Published public private(set) var pathSatisfied = true
    private let monitor = NWPathMonitor()
    private var resumedClear: Task<Void, Never>?
    private var pathWaiters: [CheckedContinuation<Void, Never>] = []

    public init(start: Bool = true) {
        guard start else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "catpaw.connection-monitor"))
    }
    deinit { monitor.cancel() }

    func pathChanged(_ ok: Bool) {
        pathSatisfied = ok
        if !ok { state = .offline; return }
        if state == .offline { state = .online }
        let waiters = pathWaiters; pathWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
    /// Suspends until the network path is usable again (offline attempts are not counted).
    public func waitForPath() async {
        if pathSatisfied { return }
        await withCheckedContinuation { pathWaiters.append($0) }
    }
    public func reconnecting(attempt: Int, retryIn: Double) { state = .reconnecting(attempt: attempt, retryIn: Int(retryIn.rounded())) }
    public func resumed() {
        state = .resumed; resumedClear?.cancel()
        resumedClear = Task { [weak self] in try? await Task.sleep(nanoseconds: 1_400_000_000); if self?.state == .resumed { self?.state = .online } }
    }
    public func unreachable() { state = .unreachable }
    public func busy(retryIn: Int) { state = .busy(retryIn: retryIn) }
    public func syncing() { if pathSatisfied { state = .syncing } }
    public func settled() { if pathSatisfied, state != .resumed { state = .online } else if !pathSatisfied { state = .offline } }
}

/// Bridges the session service (actor) to the main-actor monitor.
public struct ConnectionMonitorResilience: ConversationStreamResilience {
    public init() {}
    public func waitForPath() async { await ConnectionMonitor.shared.waitForPath() }
    public func reconnecting(attempt: Int, retryIn: Double) async { await ConnectionMonitor.shared.reconnecting(attempt: attempt, retryIn: retryIn) }
    public func resumed() async { await ConnectionMonitor.shared.resumed() }
    public func unreachable() async { await ConnectionMonitor.shared.unreachable() }
    public func settled() async { await ConnectionMonitor.shared.settled() }
}
