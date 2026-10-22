import Foundation

public struct OperationReducer: Sendable {
    public let operationID: UUID
    public let attemptEpoch: Int
    public let expectedReality: ExecutionReality
    public private(set) var observedReality: ExecutionReality
    public var epoch: Int
    public var lastSequence = 0
    public var text = ""
    public var messageState: MessageState = .waitingProvider
    public var taskState: WorkState = .queued
    public var messageTerminal = false
    public var taskTerminal = false
    public var error: String?
    public init(operationID: UUID, epoch: Int, expectedReality: ExecutionReality = .simulated) { self.operationID = operationID; self.attemptEpoch = epoch; self.epoch = epoch; self.expectedReality = expectedReality; self.observedReality = expectedReality == .simulated ? .simulated : .unknown }
    @discardableResult public mutating func accept(_ event: ProviderEvent) -> Bool {
        guard event.operationID == operationID, event.runtimeEpoch == epoch, event.sequence > lastSequence,
              [.simulated, .remoteAccepted].contains(expectedReality), !(messageTerminal && taskTerminal) else { return false }
        let isFailure: Bool
        switch event.payload { case .failed, .cancelled, .outcomeUnknown: isFailure = true; default: isFailure = false }
        guard event.reality == expectedReality || (expectedReality == .remoteAccepted && event.reality == .unknown && isFailure) else { return false }
        if expectedReality == .remoteAccepted, observedReality == .unknown, !isFailure {
            guard case .accepted = event.payload else { return false }
        }
        lastSequence = event.sequence
        switch event.payload {
        case .textDelta(let delta):
            guard !messageTerminal else { return false }
            text += delta; messageState = .streaming; if !taskTerminal { taskState = .running }
        case .messageCompleted(let hash, let reason):
            guard !messageTerminal else { return false }
            messageTerminal = true
            if hash != textHash(text) { messageState = .failed; error = "最终文本校验失败。" }
            else if reason == .length { messageState = .failed; error = "回复被截断。" }
            else { messageState = .completed }
        case .taskCompleted:
            guard !taskTerminal, messageTerminal, messageState == .completed else { return false }
            taskTerminal = true; taskState = .succeeded
        case .failed(let failure): fail(failure.displayMessage)
        case .cancelled: cancel()
        case .outcomeUnknown: messageTerminal = true; taskTerminal = true; messageState = .failed; taskState = .outcomeUnknown
        case .progress: if !taskTerminal { taskState = .running }
        case .accepted: observedReality = expectedReality
        case .verified, .result: break
        }
        return true
    }
    public mutating func endOfStream() {
        if !messageTerminal || !taskTerminal { transportFailed("流提前结束，未收到明确完成事件。已有内容已保留。") }
    }
    public mutating func transportFailed(_ reason: String) {
        guard !messageTerminal || !taskTerminal else { return }
        if expectedReality == .remoteAccepted {
            messageState = .failed; taskState = .outcomeUnknown
            messageTerminal = true; taskTerminal = true; error = reason
        } else { fail(reason) }
    }
    public mutating func fail(_ reason: String) {
        if !messageTerminal { messageState = .failed; messageTerminal = true }
        if !taskTerminal { taskState = .failed; taskTerminal = true }
        error = reason
    }
    public mutating func cancel() {
        epoch += 1
        if !messageTerminal { messageState = .cancelled; messageTerminal = true }
        if !taskTerminal { taskState = .cancelled; taskTerminal = true }
    }
}

public enum ScheduleCalculator {
    public static func next(_ spec: ScheduleSpec, after date: Date) throws -> Date {
        guard let tz = TimeZone(identifier: spec.timezoneID), spec.missedRunPolicy == "skip" else { throw catError.invalid("定时规则无效。") }
        if spec.cadence.hasPrefix("interval_"), spec.cadence.hasSuffix("h") {
            guard let hours = Int(spec.cadence.dropFirst(9).dropLast()), hours > 0, hours <= Int.max / 3600 else { throw catError.invalid("间隔需为可表示的正整数小时。") }
            return date.addingTimeInterval(TimeInterval(hours * 3600))
        }
        guard ["daily", "weekly"].contains(spec.cadence), (0...23).contains(spec.localHour), (0...59).contains(spec.localMinute) else { throw catError.invalid("时间规则无效。") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        guard spec.weekdayConvention == nil || spec.weekdayConvention == "iso8601" else { throw catError.invalid("星期编码不支持。") }
        let weekdays = spec.cadence == "weekly" ? ScheduleInput.isoWeekdays(spec) : Array(1...7)
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { throw catError.invalid("请选择有效星期。") }
        let matches = weekdays.compactMap { weekday in
            cal.nextDate(after: date, matching: DateComponents(hour: spec.localHour, minute: spec.localMinute, weekday: ScheduleInput.calendarWeekday(weekday)), matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }
        guard let result = matches.min() else { throw catError.invalid("无法计算下次时间。") }; return result
    }
}
