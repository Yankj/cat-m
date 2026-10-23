import Foundation

public enum PublicReadoutSample {
    public static let sourceKind = "builtin_public_sample"
    public static let text = "欢迎使用小咪。本段是随应用提供的公开朗读示例，不包含会话、文件或个人资料。你可以主动播放、暂停和停止声音。"
    public static func allows(reference: DocumentReference, sourceKind: String, text: String) -> Bool {
        sourceKind == self.sourceKind && reference.version == 1 && reference.contentHash == textHash(self.text) && textHash(text) == reference.contentHash
    }
    public static let restriction = "设备音频路径与离线表现尚未验收。当前仅允许内置公开示例；导入文件、会话和私有成果的朗读暂不可用。"
}

public enum AudioEventPolicy {
    public static func shouldInterrupt(began: Bool, notificationEpoch: Int, currentEpoch: Int) -> Bool { began && notificationEpoch == currentEpoch }
    // AVAudioSession.RouteChangeReason: unplugged=2, noSuitableRoute=7. Category changes (3) are self configuration.
    public static func shouldInterruptRoute(reason: UInt, notificationEpoch: Int, currentEpoch: Int) -> Bool { [2, 7].contains(reason) && notificationEpoch == currentEpoch }
}

public enum AudioNotificationEvent: Sendable {
    case interruption(began: Bool), routeChanged(reason: UInt)
}
@MainActor public protocol AudioNotificationSource: AnyObject {
    func observe(_ receive: @escaping @MainActor (AudioNotificationEvent) -> Void) -> UUID
    func remove(_ observation: UUID)
}
// A queued callback retains its registration generation, even after its observer is removed.
@MainActor public final class AudioSessionNotifications {
    private let source: any AudioNotificationSource
    private let onInterrupt: @MainActor () -> Void
    private var observation: UUID?
    public private(set) var generation = 0
    public init(source: any AudioNotificationSource, onInterrupt: @escaping @MainActor () -> Void) { self.source = source; self.onInterrupt = onInterrupt }
    public func begin() {
        end()
        let registeredGeneration = generation
        observation = source.observe { [weak self] event in
            guard let self, self.observation != nil, registeredGeneration == self.generation else { return }
            let stop: Bool
            switch event {
            case .interruption(let began): stop = AudioEventPolicy.shouldInterrupt(began: began, notificationEpoch: registeredGeneration, currentEpoch: self.generation)
            case .routeChanged(let reason): stop = AudioEventPolicy.shouldInterruptRoute(reason: reason, notificationEpoch: registeredGeneration, currentEpoch: self.generation)
            }
            if stop { self.end(); self.onInterrupt() }
        }
    }
    public func end() {
        generation += 1
        if let observation { source.remove(observation) }
        observation = nil
    }
}
