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
