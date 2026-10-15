import Foundation
import CoreFoundation

/// Reuses the current authenticated partition. No account, token or model is
/// created here, and a failed POST is never automatically repeated.
public actor NativeMemoryHTTPBackend:ConversationMemoryBackend {
    private let configuration:NativeChatConfiguration
    private let credentials:any NativeChatSessionCredentials
    private let session:URLSession
    private let conversationAdmission:NativeChatHTTPBackend
    private var closed=false
    public init(configuration:NativeChatConfiguration,credentials:any NativeChatSessionCredentials,sessionConfiguration:URLSessionConfiguration?=nil) throws {
        guard configuration.expectedSubjectID != nil else {throw ConversationMemoryError.unavailable}
        self.configuration=configuration;self.credentials=credentials;conversationAdmission=NativeChatHTTPBackend(configuration:configuration,credentials:credentials,sessionConfiguration:sessionConfiguration)
        let policy=(sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        policy.urlCache=nil;policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        session=URLSession(configuration:policy,delegate:MemoryNoRedirect(),delegateQueue:nil)
    }
    public func close() async {closed=true;session.invalidateAndCancel();await conversationAdmission.close()}
    public func readMemory(_ reference:ConversationMemoryReference) async throws -> ConversationMemorySnapshot {
        let value=try JSONDecoder().decode(ConversationMemorySnapshot.self,from:await wire(reference,suffix:"state"));try value.validate(reference);return value
    }
    public func submitMemory(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt {
        do {try request.command.validate();try check(reference);try Task.checkCancellation()}catch{throw ConversationMemoryError.notSent}
        if [.remember,.correct].contains(request.command.type),let conversationID=request.command.conversation_id,let text=request.command.source_text {
            let provisional=ConversationTurnRequest(scope:reference.scope,conversationID:conversationID,threadID:nil,operationID:request.operation_id,epoch:1,history:[.init(id:stableID("memory-source-review:"+request.id.uuidString),role:.user,content:text)])
            do {try await conversationAdmission.ensureConversationForExplicitSend(provisional);try check(reference);try Task.checkCancellation()}catch{throw ConversationMemoryError.notSent}
        }
        let value=try JSONDecoder().decode(ConversationMemoryReceipt.self,from:await wire(reference,suffix:"commands",body:ConversationMemoryCodec.encoded(request)));try value.validate(reference,request:request);return value
    }
    public func readMemoryOperation(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt {
        let value=try JSONDecoder().decode(ConversationMemoryReceipt.self,from:await wire(reference,suffix:"commands/"+request.operation_id.uuidString.lowercased(),original:true));try value.validate(reference,request:request);return value
    }
    public func readMemorySource(_ reference:ConversationMemoryReference,id:UUID) async throws -> ConversationMemorySource {
        struct Envelope:Decodable {let schema_version:Int,contract:String,scope_id:UUID,subject_id:UUID,source:ConversationMemorySource}
        let envelope=try JSONDecoder().decode(Envelope.self,from:await wire(reference,suffix:"sources/"+id.uuidString.lowercased()))
        guard envelope.schema_version==1,envelope.contract==ConversationMemoryCodec.contract,envelope.scope_id==reference.serverScopeID,envelope.subject_id==reference.subjectID,envelope.source.id==id,envelope.source.text != nil else {throw ConversationMemoryError.invalidResponse}
        try ConversationMemoryCodec.validateSource(envelope.source);return envelope.source
    }
    /// A status alone cannot prove that the original command was not admitted.
    /// Only a maintained typed denial with no prior durable operation may reopen its draft.
    /// memory_operation_conflict explicitly means the original identity already exists.
    private static func isDefiniteRejection(_ data:Data,response:HTTPURLResponse)->Bool {
        guard data.count<=65_536,response.mimeType=="application/json",
              let value=try? ConversationStrictJSON.object(data,maxBytes:65_536),Set(value.keys)==["schema_version","contract","error"],
              let schema=value["schema_version"] as? NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.doubleValue==1,
              value["contract"] as? String==ConversationMemoryCodec.contract,let error=value["error"] as? [String:Any],Set(error.keys)==["code","retryable","reconciliation_required"],
              let retryable=error["retryable"] as? NSNumber,CFGetTypeID(retryable)==CFBooleanGetTypeID(),!retryable.boolValue,
              let reconciliation=error["reconciliation_required"] as? NSNumber,CFGetTypeID(reconciliation)==CFBooleanGetTypeID(),!reconciliation.boolValue,
              let code=error["code"] as? String else {return false}
        return definiteRejectionCodes.contains(code)
    }
    private static let definiteRejectionCodes:Set<String>=["memory_schema_invalid","memory_duplicate_key","memory_request_too_large","memory_disabled","memory_generation_conflict","memory_scope_subject_conflict","scope_forbidden","untrusted_source","source_fenced","sensitive_confirmation_required","sensitive_content_requires_confirmation","credential_text_not_allowed","no_relearn_guard","revision_conflict","evidence_invalid","claim_key_conflict","correction_requires_new_user_source","grant_conflict","schema_invalid"]
    private func check(_ reference:ConversationMemoryReference) throws {
        guard !closed,reference.scope==configuration.localScope,reference.serverScopeID==configuration.serverScopeID,reference.subjectID==configuration.expectedSubjectID else {throw ConversationMemoryError.unavailable}
    }
    private func wire(_ reference:ConversationMemoryReference,suffix:String,body:Data?=nil,original:Bool=false) async throws -> Data {
        try check(reference);try Task.checkCancellation()
        let authorization:String
        do {authorization=try await credentials.authorization(scope:reference.scope)}catch{if body != nil {throw ConversationMemoryError.notSent};throw error}
        try check(reference);try Task.checkCancellation()
        var request=try configuration.makeRequest(route:"/catpaw/memory/v1/scopes/"+reference.serverScopeID.uuidString.lowercased()+"/"+suffix,authorization:authorization)
        request.httpMethod=body==nil ? "GET":"POST";request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response)=try await session.data(for:request);try check(reference);try Task.checkCancellation()
        guard let response=response as? HTTPURLResponse else {throw ConversationMemoryError.invalidResponse}
        if response.statusCode==401 {await credentials.rejected(scope:reference.scope);throw ConversationMemoryError.unavailable}
        if response.statusCode==404 {throw original ? ConversationMemoryError.originalNotFound:ConversationMemoryError.unavailable}
        if body != nil,(400...499).contains(response.statusCode),![408,429].contains(response.statusCode),Self.isDefiniteRejection(data,response:response) {throw ConversationMemoryError.rejected}
        guard response.statusCode==200,response.value(forHTTPHeaderField:"Content-Type")?.lowercased().hasPrefix("application/json")==true,data.count<=2_000_000 else {throw ConversationMemoryError.invalidResponse}
        _=try ConversationStrictJSON.object(data,maxBytes:2_000_000);return data
    }
}
private final class MemoryNoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
