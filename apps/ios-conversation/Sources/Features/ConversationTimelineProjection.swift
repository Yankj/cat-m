import Foundation

/// Read-only grouping of already persisted transcript facts. Neither a model
/// tool name nor a closed text stream is evidence that a task has completed.
enum ConversationTimelineProjection {
    enum Presentation:Equatable {case message,processPending,fallback}
    enum Issue:String {case invalidToolMetadata,unownedTool,ambiguousTurn,duplicateIdentity,missingCall,missingResult,toolMismatch,invalidOrder,inconsistentToolState,failedMessage,unknownTurn,failedTurn,unadmittedTurn}
    struct Row:Identifiable {
        let id:UUID
        let message:ConversationTranscriptMessage
        let turnID:UUID?
        let presentation:Presentation
        let issue:Issue?
        let sourceMessageIDs:[UUID]
    }
    private struct ToolKey:Hashable {let turn:UUID,call:String}
    private struct ToolOwner {let key:ToolKey,turn:ConversationTurnRecord}

    static func rows(messages:[ConversationTranscriptMessage],turns:[ConversationTurnRecord])->[Row] {
        var owners:[Int:ToolOwner]=[:],issues:[Int:Issue]=[:]
        var calls:[ToolKey:[Int]]=[:],results:[ToolKey:[Int]]=[:]
        let idCounts=Dictionary(grouping:messages,by:{$0.id}).mapValues(\.count)
        for (index,message) in messages.enumerated() {
            guard isTool(message) else {continue}
            if idCounts[message.id] != 1 {issues[index] = .duplicateIdentity;continue}
            guard let call=message.toolCallID,!call.isEmpty,let name=message.toolName,!name.isEmpty,
                  message.role == .assistant || message.role == .tool else {issues[index] = .invalidToolMetadata;continue}
            let matching=turns.filter {turn in
                guard turn.request.operationID==turn.id else {return false}
                return message.id==identity(turn:turn.id,call:call,result:message.role == .tool)
            }
            guard matching.count==1,let turn=matching.first else {
                issues[index] = matching.isEmpty ? .unownedTool:.ambiguousTurn;continue
            }
            let key=ToolKey(turn:turn.id,call:call)
            owners[index] = .init(key:key,turn:turn)
            if message.role == .tool {results[key,default:[]].append(index)}
            else {calls[key,default:[]].append(index)}
        }
        var replacements:[Int:Int]=[:],removed=Set<Int>()
        for (index,owner) in owners {
            let callIndices=calls[owner.key] ?? [],resultIndices=results[owner.key] ?? []
            let group=callIndices+resultIndices
            let issue:Issue?
            if group.contains(where:{messages[$0].failure != nil}) {issue = .failedMessage}
            else if owner.turn.state == .notSent || owner.turn.state == .cancelledBeforeSend {issue = .unadmittedTurn}
            else if callIndices.count>1 || resultIndices.count>1 {issue = .duplicateIdentity}
            else if callIndices.isEmpty {issue = .missingCall}
            else if resultIndices.isEmpty {
                // A lost/failed prose stream cannot erase a known tool result.
                // It only qualifies a call for which no result was received.
                switch owner.turn.state {
                case .unknown:issue = .unknownTurn
                case .failed:issue = .failedTurn
                case .completed:issue = .inconsistentToolState
                default:issue = .missingResult
                }
            }
            else if messages[callIndices[0]].toolName != messages[resultIndices[0]].toolName {issue = .toolMismatch}
            else if callIndices[0]>=resultIndices[0] {issue = .invalidOrder}
            else if !messages[callIndices[0]].complete || !messages[resultIndices[0]].complete {issue = .inconsistentToolState}
            else {issue=nil}
            if let issue {issues[index]=issue}
            else if messages[index].role == .assistant {
                replacements[index]=resultIndices[0];removed.insert(resultIndices[0])
            }
        }
        return messages.enumerated().compactMap {index,message in
            guard !removed.contains(index) else {return nil}
            if let resultIndex=replacements[index] {
                return Row(id:message.id,message:messages[resultIndex],turnID:owners[index]?.key.turn,presentation:.message,issue:nil,sourceMessageIDs:[message.id,messages[resultIndex].id])
            }
            let issue=issues[index]
            let tool=isTool(message)
            let turnID=owners[index]?.key.turn ?? ordinaryOwner(message,turns:turns)
            let presentation:Presentation = !tool ? .message:(issue == .missingResult ? .processPending:.fallback)
            // Corrupt duplicate input must stay visible without duplicate ForEach
            // identities. The original message UUID remains untouched in message.
            let id=idCounts[message.id] == 1 ? message.id:stableID("conversation-timeline-duplicate-\(message.id)-\(index)")
            return Row(id:id,message:message,turnID:turnID,presentation:presentation,issue:issue,sourceMessageIDs:[message.id])
        }
    }
    private static func isTool(_ message:ConversationTranscriptMessage)->Bool {message.role == .tool || message.toolName != nil || message.toolCallID != nil}
    private static func identity(turn:UUID,call:String,result:Bool)->UUID {
        stableID(result ? "conversation-tool-result-\(turn)-\(call)":"conversation-call-\(turn)-\(call)")
    }
    private static func ordinaryOwner(_ message:ConversationTranscriptMessage,turns:[ConversationTurnRecord])->UUID? {
        let matching=turns.filter {turn in
            guard turn.request.operationID==turn.id else {return false}
            if message.role == .user {return message.id==stableID("conversation-user-\(turn.id)")}
            return message.role == .assistant && message.id==turn.assistantMessageID
        }
        return matching.count==1 ? matching[0].id:nil
    }
}
