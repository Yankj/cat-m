#if DEBUG
import Foundation

enum CatpawDebugPresentation {
    static func showFixtureBadge(arguments:[String]=ProcessInfo.processInfo.arguments,environment:[String:String]=ProcessInfo.processInfo.environment)->Bool {
        arguments.contains("-CatpawShowFixtureBadge") || ["1","true","yes"].contains(environment["CatpawShowFixtureBadge"]?.lowercased() ?? "")
    }
}
import SwiftUI

@MainActor enum P0ExperienceFixture {
    static let launchEnvironment=ConversationReviewLaunchConfiguration.resolve(environment:ProcessInfo.processInfo.environment)
    /// Optional QA axis. Scenario names never override the system's text size.
    static var textSizeOverride:DynamicTypeSize? {
        guard scenario != nil else {return nil}
        switch ProcessInfo.processInfo.environment["CATPAW_UI_TEST_TEXT_SIZE"] {
        case "large":return .large
        case "xxxLarge":return .xxxLarge
        case "accessibility5":return .accessibility5
        default:return nil
        }
    }
    static var scenario:String? {
        let env=launchEnvironment
        guard let id=env["CF_UI_TEST_STORE"],UUID(uuidString:id) != nil,
              let s=env["CF_UI_TEST_SCENARIO"],["p0-ui-accepted-work","p0-ui-accepted-work-unknown","p0-ui-echo","p0-ui-consent","p0-ui-consent-handoff","p0-ui-ime","p0-ui-lifecycle","p0-ui-large","p0-ui-large-autoplay","p0-ui-reading","p0-ui-reading-growth","p0-ui-queue","p0-ui-genui","p0-ui-genui-large","p0-ui-genui-table","p0-ui-genui-chart","p0-ui-genui-weighted","p0-ui-plan","p0-ui-plan-pending","p0-ui-plan-unknown","p0-ui-sourced-artifact","p0-ui-large-sourced-artifact","p0-ui-task-action","p0-ui-task-action-unknown","p0-ui-task-action-unavailable","p0-ui-large-task-action","p0-ui-artifact-edit","p0-ui-artifact-edit-unknown","p0-ui-large-artifact-edit","p0-ui-task-control","p0-ui-task-control-unknown","p0-ui-large-task-control","p0-ui-large-task-control-unresolved","p0-ui-acceptance","p0-ui-acceptance-offline"].contains(s) else { return nil };return s
    }
    static var replyCalls=0,observeCalls=0,consentCalls=0
    static var readingGrowthStage=0
}

/// All work here is explicitly in-process synthetic; no Auth, HTTP or provider.
actor P0ExperienceBackend:ConversationBackend {
    let scenario:String
    private var consentGranted=false
    private var grantInvocations=0,replyInvocations=0
    private var requests:[UUID:ConversationTurnRequest]=[:],events:[UUID:[ConversationTurnEvent]]=[:]
    private var streams:[UUID:AsyncThrowingStream<ConversationTurnEvent,Error>.Continuation]=[:]
    private let createdAt=Date()
    init(scenario:String){self.scenario=scenario}
    func connection(scope:DataScope) async -> ConversationConnection {
        // Acceptance offline axis: unavailable for the first N seconds (default 6), then reachable so "retry" recovers.
        if scenario == "p0-ui-acceptance-offline" {
            let window=Double(ProcessInfo.processInfo.environment["CATPAW_ACCEPTANCE_OFFLINE_SECONDS"] ?? "") ?? 6
            if Date().timeIntervalSince(createdAt) < window { return .init(state:.unavailable,provider:"P0 synthetic offline",detail:"Simulated offline window; no HTTP/Auth/model") }
        }
        return .init(state:.providerUnverified,provider:"P0 synthetic offline",detail:"No HTTP/Auth/model")
    }
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
    private func sourcedFixtureArtifact(id:String,version:Int) throws -> ConversationArtifactProjection {
        let urls=["https://www.swift.org/documentation/","https://developer.apple.com/documentation/swift","https://docs.python.org/3/"]
        let hour=version==1 ? "01" : "02"
        let sources=urls.enumerated().map {offset,url->[String:Any] in
            ["source_id":"source-\(offset+1)","read_id":stableID("P0-synthetic-sourced-v\(version)-source\(offset+1)").uuidString.lowercased(),"requested_url":url,"final_url":url,"read_at":"2026-10-14T\(hour):00:00.000Z","content_hash":textHash("Synthetic response bytes v\(version) source\(offset+1); no HTTP request"),"excerpt":"Synthetic fixture excerpt; no HTTP request or webpage reading occurred."]
        }
        let content="Synthetic immutable report version \(version).\n\nThis is a deterministic offline fixture. Source URLs and receipt metadata are simulated; no website was fetched.\n\n[Unverified Markdown link](https://www.swift.org/) remains literal text."
        let title="Synthetic sourced report",summary="Explicit synthetic fixture; no Auth, HTTP, model or real read receipt."
        let data:[String:Any]=["content":content,"source_contract":"sourced-report-v1","updated_at":"2026-10-14T\(hour):01:00.000Z","sources":sources]
        let body=String(decoding:try JSONSerialization.data(withJSONObject:["kind":"report","title":title,"summary":summary,"data":data],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
        return .init(id:id,version:version,contentHash:textHash(body),body:body,title:title,summary:summary,content:content)
    }
    private func produce(_ r:ConversationTurnRequest) async {
        emit(.started(requestHash:textHash("P0-UI:"+r.operationID.uuidString),conversationRevision:1,grantEpoch:1),request:r)
        let message=stableID("P0-UI-assistant-"+r.operationID.uuidString)
        if scenario == "p0-ui-reading-growth" {await produceReadingGrowth(r,message:message);return}
        if scenario.hasPrefix("p0-ui-acceptance") {await produceAcceptance(r,message:message);return}
        if scenario.hasSuffix("sourced-artifact") || scenario.contains("artifact-edit") || scenario.contains("task-action") {
            do {
                let call="synthetic-sourced-"+r.operationID.uuidString,run=stableID(call+"-run"),artifactID=textHash(call+"-artifact")
                let binding=ConversationTaskBinding(scope_id:r.scope.workspaceID,conversation_id:r.conversationID,turn_id:r.operationID,call_id:call,delegation_id:stableID(call+"-delegation"),operation_id:stableID(call+"-operation"),run_id:run,task_id:(scenario.contains("artifact-edit") || scenario.contains("task-action")) ? textHash(call+"-task") : "synthetic-task-"+run.uuidString,request_hash:textHash(call),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+r.scope.workspaceID.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
                let v1=try sourcedFixtureArtifact(id:artifactID,version:1),v2=try sourcedFixtureArtifact(id:artifactID,version:2)
                var first=ConversationGoalProjection(id:binding.task_id,revision:1,title:"Synthetic sourced report",state:.working,summary:"Explicit offline version 1; no real source reading.",updatedAt:Date(timeIntervalSince1970:1791939720));first.binding=binding;first.artifacts=[v1]
                emit(.toolStarted(callID:call,name:"delegate_task",arguments:"{}"),request:r)
                emit(.toolResult(.init(callID:call,name:"delegate_task",content:String(decoding:try JSONEncoder().encode(binding),as:UTF8.self),committedGoals:[first])),request:r)
                var current=ConversationGoalProjection(id:binding.task_id,revision:1,title:"Synthetic sourced report",state:.completed,summary:"Explicit offline version 2; original run and artifact identity retained.",updatedAt:Date(timeIntervalSince1970:1791943320));current.binding=binding;current.artifacts=[v2]
                let statusCall=call+"-status"
                emit(.toolStarted(callID:statusCall,name:"agent_status",arguments:"{}"),request:r)
                emit(.toolResult(.init(callID:statusCall,name:"agent_status",content:"{\"synthetic_fixture\":true,\"tasks\":[]}",committedGoals:[current])),request:r)
            } catch {emit(.failed(message:"Synthetic sourced artifact fixture construction failed",reconciliationRequired:false),request:r);streams[r.operationID]?.finish();return}
        }
        if scenario.hasPrefix("p0-ui-plan") {
            let call="synthetic-plan-"+r.operationID.uuidString,run=stableID(call+"-run")
            let binding=ConversationTaskBinding(scope_id:r.scope.workspaceID,conversation_id:r.conversationID,turn_id:r.operationID,call_id:call,delegation_id:stableID(call+"-delegation"),operation_id:stableID(call+"-operation"),run_id:run,task_id:"synthetic-task-"+run.uuidString,request_hash:textHash(call),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+r.scope.workspaceID.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
            var goal=ConversationGoalProjection(id:binding.task_id,revision:1,title:"Synthetic local report",state:.queued,summary:"Explicit offline plan fixture; no Auth, web, model or server task.",updatedAt:Date());goal.binding=binding
            emit(.toolStarted(callID:call,name:"delegate_plan_v1",arguments:"{}"),request:r)
            let content=String(decoding:(try? JSONEncoder().encode(binding)) ?? Data(),as:UTF8.self)
            emit(.toolResult(.init(callID:call,name:"delegate_plan_v1",content:content,committedGoals:[goal])),request:r)
        }
        if scenario.hasPrefix("p0-ui-genui") {
            let call="synthetic-cgui-"+r.operationID.uuidString
            emit(.toolStarted(callID:call,name:"present_cgui_v1",arguments:"{}"),request:r)
            do {
                let source=CGUISource(id:"fixture",label:"Synthetic fixture; not research or competitor data",kind:.assumption)
                let identity=CGUIIdentity(blockID:call,conversationID:r.conversationID,turnID:r.operationID,dataRevision:1)
                let block:CGUIBlock
                if scenario == "p0-ui-genui-table" {
                    let table=CGUITable(columns:[.init(id:"option",label:"Option"),.init(id:"score",label:"Score",unit:"/100")],rows:try ["80","60","90","40","10","30"].enumerated().map {i,value in
                        .init(id:"row-"+String(i),cells:[.init(text:"Option "+String(i+1),sourceIDs:[source.id]),.init(number:try CGUIDecimal(value),sourceIDs:[source.id])])
                    })
                    block = .init(identity:identity,presentation:.table,title:"Synthetic comparison",summary:"Six artificial rows; local sorting and filtering only.",sources:[source],fallback:.init(text:"Synthetic comparison data"),table:table)
                } else if scenario == "p0-ui-genui-chart" {
                    let chart=CGUIChart(kind:.line,unit:"/100",series:[.init(id:"series",label:"Synthetic series",points:try ["80","60","90"].enumerated().map {i,value in .init(id:"point-"+String(i),label:"Sample "+String(i+1),value:try CGUIDecimal(value),sourceIDs:[source.id])})])
                    block = .init(identity:identity,presentation:.chart,title:"Synthetic chart",summary:"Artificial values, not observed statistics.",sources:[source],fallback:.init(text:"Synthetic chart data"),chart:chart)
                } else if scenario == "p0-ui-genui-weighted" {
                    let weighted=CGUIWeightedComparisonInput(dimensions:[.init(id:"a",label:"Dimension A",weight:try CGUIDecimal("3")),.init(id:"b",label:"Dimension B",weight:try CGUIDecimal("1"))],options:[.init(id:"one",label:"Option One",scores:try ["80","40"].map(CGUIDecimal.init),sourceIDs:[source.id]),.init(id:"two",label:"Option Two",scores:try ["60","90"].map(CGUIDecimal.init),sourceIDs:[source.id])])
                    block = .init(identity:identity,presentation:.calculator,title:"Synthetic weighted comparison",summary:"Artificial scores; no competitor ranking.",sources:[source],fallback:.init(text:"Synthetic weighted comparison"),calculator:.init(weighted:weighted))
                } else {
                    let input=CGUIDurationBudgetInput(total:try CGUIDecimal("60"),reserved:try CGUIDecimal("10"),stepCount:4,perStep:try CGUIDecimal("8"))
                    block = .init(identity:identity,presentation:.calculator,title:"Synthetic time budget",summary:"Local inputs; no calendar or backend effect.",sources:[source],fallback:.init(text:"60 − 10 − 4 × 8 = 18 minutes"),calculator:.init(duration:input))
                }
                let content=String(decoding:try JSONEncoder().encode(block),as:UTF8.self)
                emit(.toolResult(.init(callID:call,name:"present_cgui_v1",content:content)),request:r)
            } catch {emit(.failed(message:"Synthetic CGUI fixture construction failed",reconciliationRequired:false),request:r);streams[r.operationID]?.finish();return}
        }
        let body=(scenario.hasSuffix("sourced-artifact") || scenario.contains("task-action") || scenario.contains("artifact-edit")) ? "Synthetic offline sourced artifact fixture; no model or HTTP call." : (scenario == "p0-ui-reading" ? (1...180).map {"Synthetic reading paragraph \($0). Keep this reading position while new paragraphs arrive.\n\n"}.joined() : (scenario.hasPrefix("p0-ui-genui") ? String(repeating:"Synthetic body continues while local controls remain stable. ",count:24) : (scenario.hasPrefix("p0-ui-large") ? String(repeating:"合成流式正文🐾\n",count:512) : (scenario == "p0-ui-consent" ? String(repeating:"Synthetic streamed segment. ",count:64) : "Synthetic offline reply; no model call."))))
        let delay:UInt64=scenario == "p0-ui-lifecycle" ? 10_000_000_000 : (scenario == "p0-ui-queue" && r.epoch == 1 ? 30_000_000_000 : 100_000_000)
        try? await Task.sleep(nanoseconds:delay)
        var remaining=body
        while !remaining.isEmpty {
            let chunk=String(remaining.prefix(128));remaining=String(remaining.dropFirst(chunk.count))
            emit(.textDelta(messageID:message,text:chunk),request:r);try? await Task.sleep(nanoseconds:scenario.hasPrefix("p0-ui-genui") ? 600_000_000 : (scenario == "p0-ui-consent" ? 250_000_000 : (scenario == "p0-ui-reading" ? 100_000_000 : 20_000_000)))
        }
        emit(.completed(messageID:message,finalTextHash:textHash(body)),request:r);streams[r.operationID]?.finish()
    }
    /// XCUITest acceptance: visible thinking phase, reasoning summary, then a long slow body
    /// (≈12 s) so stop / scroll-to-latest can be exercised mid-stream. Offline, deterministic.
    private func produceAcceptance(_ r:ConversationTurnRequest,message:UUID) async {
        try? await Task.sleep(nanoseconds:2_500_000_000)
        emit(.reasoningSummary(messageID:message,text:"Synthetic acceptance thinking summary.",thinkingMs:2500),request:r)
        let body=(1...60).map {"Synthetic acceptance paragraph \($0). The stream keeps growing so the reader can scroll away and jump back.\n\n"}.joined()
        var remaining=body
        while !remaining.isEmpty {
            if streams[r.operationID] == nil {return}
            let chunk=String(remaining.prefix(48));remaining=String(remaining.dropFirst(chunk.count))
            emit(.textDelta(messageID:message,text:chunk),request:r);try? await Task.sleep(nanoseconds:80_000_000)
        }
        emit(.completed(messageID:message,finalTextHash:textHash(body)),request:r);streams[r.operationID]?.finish()
    }
    /// Controlled native-layout fixture: actual transcript events, no network or model.
    /// Test controls only delivery timing; the production renderer owns every pixel.
    private func produceReadingGrowth(_ r:ConversationTurnRequest,message:UUID) async {
        let upper="reading-upper-"+r.operationID.uuidString,lower="reading-lower-"+r.operationID.uuidString
        emit(.toolStarted(callID:upper,name:"present_cgui_v1",arguments:"{}"),request:r)
        let body=(1...18).map {"Reading checkpoint \($0). This stable paragraph stays at the same screen position when a result above it becomes ready.\n\n"}.joined()
        emit(.textDelta(messageID:message,text:body),request:r)
        emit(.toolStarted(callID:lower,name:"present_cgui_v1",arguments:"{}"),request:r)
        for (stage,call) in [(1,upper),(2,lower)] {
            var ready=false
            for _ in 0..<600 {
                if await MainActor.run(body:{P0ExperienceFixture.readingGrowthStage>=stage}) {ready=true;break}
                try? await Task.sleep(nanoseconds:100_000_000)
            }
            guard ready else {emit(.failed(message:"Synthetic reading fixture gate expired",reconciliationRequired:false),request:r);streams[r.operationID]?.finish();return}
            do {
                let source=CGUISource(id:"fixture",label:"Explicit local layout fixture; no web or model",kind:.assumption)
                let identity=CGUIIdentity(blockID:call,conversationID:r.conversationID,turnID:r.operationID,dataRevision:1)
                let input=CGUIDurationBudgetInput(total:try CGUIDecimal("60"),reserved:try CGUIDecimal("10"),stepCount:4,perStep:try CGUIDecimal("8"))
                let block=CGUIBlock(identity:identity,presentation:.calculator,title:stage==1 ? "Synthetic upper result":"Synthetic lower result",summary:"Actual native calculator from a controlled transcript result. No execution authority.",sources:[source],fallback:.init(text:"60 − 10 − 4 × 8 = 18 minutes"),calculator:.init(duration:input))
                emit(.toolResult(.init(callID:call,name:"present_cgui_v1",content:String(decoding:try JSONEncoder().encode(block),as:UTF8.self))),request:r)
            }catch {emit(.failed(message:"Synthetic reading fixture invalid",reconciliationRequired:false),request:r);streams[r.operationID]?.finish();return}
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
