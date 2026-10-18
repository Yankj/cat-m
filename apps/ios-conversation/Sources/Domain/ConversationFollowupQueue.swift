import Foundation
// State-machine behavior adapted from OpenMuse conversation-queue.ts, MIT.
// Copyright (c) 2026 OpenMuse contributors. Full attribution: docs/conversation-first/upstream-review/LICENSE.
public struct ConversationFollowup:Codable,Sendable,Identifiable,Equatable {
    public let id:UUID
    public let text:String
    public let image:ConversationVisionReference?
    public let continuation:ConversationArtifactContinuationIntent?
    public let acceptedWork:ConversationAcceptedWorkSelection?
    public let revisionWork:ConversationRevisionWorkSelection?
    public init(id:UUID=UUID(),text:String,image:ConversationVisionReference?=nil,continuation:ConversationArtifactContinuationIntent?=nil,acceptedWork:ConversationAcceptedWorkSelection?=nil,revisionWork:ConversationRevisionWorkSelection?=nil) {self.revisionWork=revisionWork;self.id=id;self.text=text;self.image=image;self.continuation=continuation;self.acceptedWork=acceptedWork}
}
public enum FollowupPauseReason:String,Codable,Sendable {case user,background,preflight,recovery}
public struct ConversationFollowupState:Codable,Sendable {
    public var pending:[ConversationFollowup]=[]
    public var paused=false
    public var pauseReason:FollowupPauseReason?
    public var inflight:ConversationFollowup?
    public init() {}
}

/// Image-upload rate-limit fix: automatic busy retries. `Retry-After` wins; otherwise 5 s, 15 s, 30 s; at most 3 tries.
/// nil = no automatic retry left: the turn shows 「发送失败 · 重试 / 删除」.
public enum ConversationBusyRetryPolicy {
    public static let backoff: [TimeInterval] = [5, 15, 30]
    public static let maxAttempts = 3
    /// `attempt` is 1-based.
    public static func delay(attempt: Int, retryAfterSeconds: Int?) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        if let retryAfterSeconds { return TimeInterval(max(1, min(retryAfterSeconds, 3600))) }
        return backoff[attempt - 1]
    }
    /// What the busy card shows: whole seconds, never a countdown that disagrees with the real due time.
    public static func displaySeconds(_ delay: TimeInterval) -> Int { max(0, Int(delay.rounded(.up))) }
}

/// A failed / rate-limited turn never holds the follow-up queue (the server marks it `superseded_by_new_message`
/// when a new message arrives; the client matches that).
public enum ConversationFollowupRecovery {
    /// The server ended the turn without a reply (failed incl. rate_limited, or cancelled before send).
    public static func isTerminalFailure(_ turn: ConversationTurnRecord?) -> Bool {
        guard let turn else { return false }
        return turn.state == .failed || turn.state == .cancelledBeforeSend
    }
    /// A persisted queue paused (`.recovery`) behind a terminal failure, unpaused. nil = leave the state as it is
    /// (user / background / preflight pauses, an unresolved turn, or an in-flight message whose fate is unknown).
    public static func normalized(_ state: ConversationFollowupState, session: ConversationSession?) -> ConversationFollowupState? {
        guard state.paused, state.pauseReason == .recovery, let session, session.unresolved == nil else { return nil }
        if let inflight = state.inflight {
            let turn = session.turns.first(where: { $0.id == inflight.id })
            guard isTerminalFailure(turn) || turn?.state == .completed else { return nil }
        } else {
            guard isTerminalFailure(session.turns.last) else { return nil }
        }
        var next = state
        next.paused = false; next.pauseReason = nil; next.inflight = nil
        return next
    }
}

/// Captions never merge across turns: a failed turn's caption restored into the composer is removed again when the
/// user replaces / removes that image, and it is only ever put into an empty composer.
public enum ConversationCaptionPolicy {
    public static func restored(draft: String, caption: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? caption : draft
    }
    public static func strippingRecovered(draft: String, caption: String?) -> String {
        guard let caption, !caption.isEmpty else { return draft }
        if draft == caption { return "" }
        if draft.hasSuffix(caption) { return String(draft.dropLast(caption.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if draft.hasPrefix(caption) { return String(draft.dropFirst(caption.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return draft
    }
}
