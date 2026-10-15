import Foundation
import Observation

// Proactive meeting/travel assistant — signal pipeline seam (demo-grade).
// 采集 → 过滤 → 合并 → 决策 → 介入方式. `MockProactiveSignalEngine` runs locally; a real engine
// (server-side or on-device) conforms to `ProactiveSignalEngine` and replaces it via `ProactiveSignalHub.engine`.

struct ProactiveSimulatedMeeting: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var start: Date
    var place: String
    var latitude: Double?
    var longitude: Double?
    init(id: UUID = UUID(), title: String, start: Date, place: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.title = title; self.start = start; self.place = place; self.latitude = latitude; self.longitude = longitude
    }
}

struct ProactiveSimulatedLocation: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var latitude: Double
    var longitude: Double
}

struct ProactiveSignalInput: Equatable, Sendable {
    var now: Date
    var meetings: [ProactiveSimulatedMeeting]
    var location: ProactiveSimulatedLocation?
    /// Calendar permission state; `false` means signals came from the manual-input degrade card.
    var calendarAuthorized: Bool = true
}

enum ProactivePipelineStage: String, CaseIterable, Sendable { case collect, filter, merge, decide, intervene }
enum ProactiveStageStatus: Equatable, Sendable { case idle, running, passed, skipped, failed }

struct ProactiveStageResult: Identifiable, Equatable, Sendable {
    var id: ProactivePipelineStage { stage }
    let stage: ProactivePipelineStage
    var status: ProactiveStageStatus
    var details: [String]
}

/// Output contract for the sibling `proactive_suggestion` card.
struct ProactiveSuggestion: Identifiable, Equatable, Sendable, Codable {
    enum Channel: String, Sendable, Codable { case inAppCard = "in_app_card", banner, push, liveActivity = "live_activity", silent }
    let id: String
    var kind: String            // meeting_departure | meeting_prep | travel
    var title: String
    var body: String
    var channel: Channel
    var meetingTitle: String?
    var meetingStart: Date?
    var place: String?
    var leaveAt: Date?
}

protocol ProactiveSignalEngine: Sendable {
    /// Streams stage updates; the final value carries the suggestion (nil if nothing to do).
    func run(_ input: ProactiveSignalInput, update: @escaping @Sendable (ProactiveStageResult) async -> Void) async -> ProactiveSuggestion?
}

/// Integration hooks: the card PR observes `ProactiveSignalHub.suggestionNotification` (object = ProactiveSuggestion)
/// or sets `ProactiveSignalHub.onSuggestion`. The degrade card posts `manualMeetingNotification` (object = ProactiveSimulatedMeeting).
@MainActor enum ProactiveSignalHub {
    static let suggestionNotification = Notification.Name("catpaw.proactive.suggestion")
    static let manualMeetingNotification = Notification.Name("catpaw.proactive.manualMeeting")
    static var engine: any ProactiveSignalEngine = MockProactiveSignalEngine()
    static var onSuggestion: ((ProactiveSuggestion) -> Void)?
    static func emit(_ suggestion: ProactiveSuggestion) {
        onSuggestion?(suggestion)
        NotificationCenter.default.post(name: suggestionNotification, object: suggestion)
    }
}

struct MockProactiveSignalEngine: ProactiveSignalEngine {
    var stepDelay: Duration = .milliseconds(450)
    /// Rough travel time: 3 min per km straight-line, min 10 min. Real engine: MapKit ETA / server routing.
    static func travelMinutes(from: ProactiveSimulatedLocation?, to m: ProactiveSimulatedMeeting) -> Int {
        guard let from, let lat = m.latitude, let lon = m.longitude else { return 20 }
        let dLat = (lat - from.latitude) * 111, dLon = (lon - from.longitude) * 111 * cos(from.latitude * .pi / 180)
        return max(10, Int((dLat * dLat + dLon * dLon).squareRoot() * 3))
    }

    func run(_ input: ProactiveSignalInput, update: @escaping @Sendable (ProactiveStageResult) async -> Void) async -> ProactiveSuggestion? {
        func step(_ s: ProactivePipelineStage, _ status: ProactiveStageStatus, _ details: [String]) async {
            await update(.init(stage: s, status: .running, details: []))
            try? await Task.sleep(for: stepDelay)
            await update(.init(stage: s, status: status, details: details))
        }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        // 采集
        var collected = ["clock=\(input.now.formatted(f))", "meetings=\(input.meetings.count)", "calendar=\(input.calendarAuthorized ? "authorized" : "manual")"]
        if let l = input.location { collected.append("location=\(l.name) (\(String(format: "%.3f,%.3f", l.latitude, l.longitude)))") }
        await step(.collect, .passed, collected)
        // 过滤: meetings in the next 3 h, not started
        let upcoming = input.meetings.filter { $0.start > input.now && $0.start.timeIntervalSince(input.now) <= 3 * 3600 }.sorted { $0.start < $1.start }
        let dropped = input.meetings.count - upcoming.count
        guard let next = upcoming.first else {
            await step(.filter, .skipped, ["upcoming=0", "dropped=\(dropped) (past or >3h)"])
            for s in [ProactivePipelineStage.merge, .decide, .intervene] { await update(.init(stage: s, status: .skipped, details: ["no candidate"])) }
            return nil
        }
        await step(.filter, .passed, ["upcoming=\(upcoming.count)", "dropped=\(dropped)", "next=\(next.title) @ \(next.start.formatted(f))"])
        // 合并: meeting + location + travel estimate
        let travel = Self.travelMinutes(from: input.location, to: next)
        let leaveAt = next.start.addingTimeInterval(TimeInterval(-(travel + 10) * 60))
        await step(.merge, .passed, ["place=\(next.place)", "travel≈\(travel) min", "leaveAt=\(leaveAt.formatted(f))"])
        // 决策
        let minutesToLeave = Int(leaveAt.timeIntervalSince(input.now) / 60)
        let urgent = minutesToLeave <= 15
        let kind = input.location == nil ? "meeting_prep" : "meeting_departure"
        await step(.decide, .passed, ["kind=\(kind)", "minutesToLeave=\(minutesToLeave)", urgent ? "score=0.9 urgent" : "score=0.6"])
        // 介入方式
        let channel: ProactiveSuggestion.Channel = minutesToLeave < 0 ? .push : (urgent ? .banner : .inAppCard)
        await step(.intervene, .passed, ["channel=\(channel.rawValue)", "quietHours=off", "cap=ok"])
        return ProactiveSuggestion(id: UUID().uuidString, kind: kind, title: next.title,
                                   body: "", channel: channel, meetingTitle: next.title, meetingStart: next.start, place: next.place, leaveAt: leaveAt)
    }
}

@MainActor @Observable final class ProactiveSignalDebugModel {
    static let presets: [ProactiveSimulatedLocation] = [
        .init(name: "家", latitude: 31.2304, longitude: 121.4737),
        .init(name: "公司", latitude: 31.2397, longitude: 121.4998),
        .init(name: "浦东机场", latitude: 31.1443, longitude: 121.8083),
    ]
    var clockOffsetMinutes: Double = 0
    var meetings: [ProactiveSimulatedMeeting] = []
    var location: ProactiveSimulatedLocation? = presets[0]
    var calendarAuthorized = true
    var stages: [ProactiveStageResult] = ProactivePipelineStage.allCases.map { .init(stage: $0, status: .idle, details: []) }
    var suggestion: ProactiveSuggestion?
    var running = false
    private var manualObserver: NSObjectProtocol?

    var now: Date { Date.now.addingTimeInterval(clockOffsetMinutes * 60) }

    init() {
        manualObserver = NotificationCenter.default.addObserver(forName: ProactiveSignalHub.manualMeetingNotification, object: nil, queue: .main) { [weak self] note in
            guard let m = note.object as? ProactiveSimulatedMeeting else { return }
            MainActor.assumeIsolated { self?.meetings.append(m); self?.calendarAuthorized = false; self?.run() }
        }
    }

    func addFakeMeeting(title: String, inMinutes: Int, place: String) {
        let target = Self.presets[1]
        meetings.append(.init(title: title, start: now.addingTimeInterval(TimeInterval(inMinutes * 60)), place: place, latitude: target.latitude, longitude: target.longitude))
    }

    func run() {
        guard !running else { return }
        running = true; suggestion = nil
        stages = ProactivePipelineStage.allCases.map { .init(stage: $0, status: .idle, details: []) }
        let input = ProactiveSignalInput(now: now, meetings: meetings, location: location, calendarAuthorized: calendarAuthorized)
        let engine = ProactiveSignalHub.engine
        Task { @MainActor in
            let result = await engine.run(input) { r in await MainActor.run { self.apply(r) } }
            suggestion = result; running = false
        }
    }

    private func apply(_ r: ProactiveStageResult) { if let i = stages.firstIndex(where: { $0.stage == r.stage }) { stages[i] = r } }
}
