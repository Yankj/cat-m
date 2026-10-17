#if DEBUG
import UIKit

/// Opt-in (CATPAW_FRAME_PROBE=1) frame and body-evaluation counter for interaction
/// polish measurements. Records display-link callback intervals and named counters,
/// flushed to Documents/interaction-probe.json once per second. Debug builds only.
@MainActor final class InteractionFrameProbe: NSObject {
    static let shared = InteractionFrameProbe()
    let enabled = ProcessInfo.processInfo.environment["CATPAW_FRAME_PROBE"] == "1"
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var frames: [[Double]] = []          // [uptime_s, delta_ms]
    private var counters: [String: [Double]] = [:] // name -> uptimes
    private var flushTimer: Timer?
    func start() {
        guard enabled, link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common); link = l
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { InteractionFrameProbe.shared.flush() } }
        RunLoop.main.add(t, forMode: .common); flushTimer = t
    }
    /// Count a body evaluation (or any event) under `name`.
    func count(_ name: String) {
        guard enabled else { return }
        counters[name, default: []].append(ProcessInfo.processInfo.systemUptime)
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if let last, frames.count < 60_000 { frames.append([ProcessInfo.processInfo.systemUptime, (now - last) * 1000]) }
        last = now
    }
    private func flush() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let object: [String: Any] = ["frames": frames, "counters": counters]
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: dir.appendingPathComponent("interaction-probe.json"), options: .atomic)
        }
    }
}
#endif
