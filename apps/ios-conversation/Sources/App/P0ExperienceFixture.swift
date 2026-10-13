#if DEBUG
import Foundation

@MainActor enum P0ExperienceFixture {
    static var scenario:String? {
        let env=ProcessInfo.processInfo.environment
        guard let id=env["CF_UI_TEST_STORE"],UUID(uuidString:id) != nil,
              let s=env["CF_UI_TEST_SCENARIO"],["p0-ui-echo","p0-ui-consent","p0-ui-ime","p0-ui-lifecycle","p0-ui-large","p0-ui-large-autoplay","p0-ui-reading","p0-ui-queue"].contains(s) else { return nil };return s
    }
    static var replyCalls=0,observeCalls=0,consentCalls=0
}

/// All work here is explicitly in-process synthetic; no Auth, HTTP or provider.
actor P0ExperienceBackend:ConversationBackend {
    let scenario:String
    private var consentGranted=false
    private var grantInvocations=0,replyInvocations=0
    private var requests:[UUID:ConversationTurnRequest]=[:],events:[UUID:[ConversationTurnEvent]]=[:]
    private var streams:[UUID:AsyncThrowingStream<ConversationTurnEvent,Error>.Continuation]=[:]
    init(scenario:String){self.scenario=scenario}
    func connection(scope:DataScope) async -> ConversationConnection { .init(state:.providerUnverified,provider:"P0 synthetic offline",detail:"No HTTP/Auth/model") }
    func modelConsent(scope:DataScope,conversationID:UUID) async throws -> ConversationModelConsent? {
        if scenario == "p0-ui-echo" { try await Task.sleep(nanoseconds:2_000_000_000) }
        if scenario == "p0-ui-consent",!consentGranted {return .init(conversationID:conversationID,title:"Synthetic consent",body:"Explicit offline UI fixture. No HTTP, Auth or model. Confirmation is required before the synthetic reply.",routeHash:textHash("P0 consent route"),expectedRevision:0)}
        return nil
    }
    func allowModelConsent(scope:DataScope,consent:ConversationModelConsent) async throws {
        guard scenario == "p0-ui-consent",consent.routeHash==textHash("P0 consent route"),consent.expectedRevision==0 else {throw ConversationSessionError.invalidEvent}
        consentGranted=true;grantInvocations += 1;await MainActor.run {P0ExperienceFixture.consentCalls += 1}
    }
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        replyInvocations += 1;requests[request.operationID]=request;events[request.operationID]=[]
        await MainActor.run { P0ExperienceFixture.replyCalls += 1 }
        return AsyncThrowingStream { c in
            streams[request.operationID]=c
            c.onTermination={ [weak self] _ in Task { await self?.detach(request.operationID) } }
            Task { await self.produce(request) }
        }
    }
    func consentInvocationCounts()->[Int] {[grantInvocations,replyInvocations]}
    private func detach(_ id:UUID){streams.removeValue(forKey:id)}
    private func emit(_ payload:ConversationTurnEvent.Payload,request r:ConversationTurnRequest) {
        let event=ConversationTurnEvent(operationID:r.operationID,epoch:r.epoch,sequence:(events[r.operationID]?.count ?? 0)+1,payload:payload)
        events[r.operationID,default:[]].append(event);streams[r.operationID]?.yield(event)
    }
    private func produce(_ r:ConversationTurnRequest) async {
        emit(.started(requestHash:textHash("P0-UI:"+r.operationID.uuidString),conversationRevision:1,grantEpoch:1),request:r)
        let message=stableID("P0-UI-assistant-"+r.operationID.uuidString)
        let body=scenario == "p0-ui-reading" ? (1...180).map {"Synthetic reading paragraph \($0). Keep this reading position while new paragraphs arrive.\n\n"}.joined() : (scenario.hasPrefix("p0-ui-large") ? String(repeating:"合成流式正文🐾\n",count:512) : (scenario == "p0-ui-consent" ? String(repeating:"Synthetic streamed segment. ",count:64) : "Synthetic offline reply; no model call."))
        let delay:UInt64=scenario == "p0-ui-lifecycle" ? 10_000_000_000 : (scenario == "p0-ui-queue" && r.epoch == 1 ? 30_000_000_000 : 100_000_000)
        try? await Task.sleep(nanoseconds:delay)
        var remaining=body
        while !remaining.isEmpty {
            let chunk=String(remaining.prefix(128));remaining=String(remaining.dropFirst(chunk.count))
            emit(.textDelta(messageID:message,text:chunk),request:r);try? await Task.sleep(nanoseconds:scenario == "p0-ui-consent" ? 250_000_000 : (scenario == "p0-ui-reading" ? 100_000_000 : 20_000_000))
        }
        emit(.completed(messageID:message,finalTextHash:textHash(body)),request:r);streams[r.operationID]?.finish()
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {
        guard requests[request.operationID] != nil else { throw CatpawError.missing }
        await MainActor.run { P0ExperienceFixture.observeCalls += 1 }
        return .init(request:request,events:events[request.operationID] ?? [],requestHash:textHash("P0-UI:"+request.operationID.uuidString),grantEpoch:1,goals:[])
    }
}
#endif
