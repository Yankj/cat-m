import Foundation

public struct ConversationImageCapability:Sendable,Equatable {
    public var available:Bool
    public var liveTransmissionAvailable:Bool
    public var routeHash:String?
    public var state:String
    public var detail:String
    public init(available:Bool=false,liveTransmissionAvailable:Bool=false,routeHash:String?=nil,state:String="unavailable",detail:String="图片发送暂不可用；所选图片留在本机。") {
        self.available=available;self.liveTransmissionAvailable=liveTransmissionAvailable;self.routeHash=routeHash;self.state=state;self.detail=detail
    }
}
public extension ConversationBackend {
    func imageCapabilities(scope:DataScope,conversationID:UUID) async throws -> ConversationImageCapability { .init() }
}

public struct ConversationImageReceipt:Codable,Sendable,Equatable,Identifiable {
    public let id:UUID
    public let mime_type:String
    public let sha256:String
    public let size_bytes:Int
    public let width:Int
    public let height:Int
    public init(id:UUID,mimeType:String,sha256:String,size:Int,width:Int,height:Int) {
        self.id=id;self.mime_type=mimeType;self.sha256=sha256;self.size_bytes=size;self.width=width;self.height=height
    }
    public var isValid:Bool {
        ["image/png","image/jpeg"].contains(mime_type) && Self.isSHA(sha256) && size_bytes>0 && size_bytes<=5_242_880 && width>0 && width<=2048 && height>0 && height<=2048 && width*height<=4_194_304
    }
    public static func isSHA(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
}
/// Metadata is durable; image bytes are exclusively a local vault / current transport concern.
public struct ConversationVisionReference:Codable,Sendable,Equatable {
    public let receipt:ConversationImageReceipt
    public let routeHash:String
    public let consentRevision:Int
    public init(receipt:ConversationImageReceipt,routeHash:String,consentRevision:Int) {
        self.receipt=receipt;self.routeHash=routeHash;self.consentRevision=consentRevision
    }
    public var isValid:Bool {receipt.isValid && ConversationImageReceipt.isSHA(routeHash) && consentRevision>0}
    public func validate(_ bytes:Data,messageID:UUID) throws {
        guard isValid,receipt.id != messageID,bytes.count==receipt.size_bytes,bytesHash(bytes)==receipt.sha256 else {throw ConversationSessionError.invalidEvent}
        let signature=Array(bytes.prefix(8))
        guard receipt.mime_type=="image/png" ? signature==[137,80,78,71,13,10,26,10] : signature.starts(with:[255,216,255]) else {throw ConversationSessionError.invalidEvent}
    }
    public func wire(_ bytes:Data,messageID:UUID) throws -> [String:String] {
        try validate(bytes,messageID:messageID)
        return ["id":receipt.id.uuidString.lowercased(),"mime_type":receipt.mime_type,"sha256":receipt.sha256,"base64":bytes.base64EncodedString()]
    }
}
public struct ConversationVisionPayload:Sendable {
    public let reference:ConversationVisionReference
    public let bytes:Data
    public init(reference:ConversationVisionReference,bytes:Data){self.reference=reference;self.bytes=bytes}
}
public struct ConversationVisionProviderReceipt:Codable,Sendable,Equatable {
    public let requested_model:String
    public let actual_model:String
    public let actual_provider:String
    public let cost:Double
    public let image_count:Int
    public let image_hashes:[String]
    public let image_bytes:Int
    public let route_hash:String
    public let terminal_validated:Bool
    public let response_id:String?
    public func matches(_ reference:ConversationVisionReference)->Bool {
        requested_model=="google/gemma-4-31b-it:free" && ["google/gemma-4-31b-it:free","google/gemma-4-31b-it"].contains(actual_model) && actual_provider.caseInsensitiveCompare("Google AI Studio") == .orderedSame && cost==0 && image_count==1 && image_hashes==[reference.receipt.sha256] && image_bytes==reference.receipt.size_bytes && route_hash==reference.routeHash && terminal_validated
    }
}
/// Approval binds the exact preview and conversation as well as the server route/revision.
public struct ConversationImageConsent:Sendable,Identifiable,Equatable {
    public let id:UUID
    public let conversationID:UUID
    public let previewID:UUID
    public let previewHash:String
    public let routeHash:String
    public let expectedRevision:Int
    public let title:String
    public let body:String
    public let confirmation:String
    public let allowLabel:String
    public let denyLabel:String
    public init(id:UUID=UUID(),conversationID:UUID,previewID:UUID,previewHash:String,routeHash:String,expectedRevision:Int,title:String,body:String,confirmation:String,allowLabel:String,denyLabel:String) {
        self.id=id;self.conversationID=conversationID;self.previewID=previewID;self.previewHash=previewHash;self.routeHash=routeHash;self.expectedRevision=expectedRevision;self.title=title;self.body=body;self.confirmation=confirmation;self.allowLabel=allowLabel;self.denyLabel=denyLabel
    }
}
public protocol ConversationImageByteStore:Sendable {
    func save(_ payload:ConversationVisionPayload,conversationID:UUID,operationID:UUID) async throws
    func read(reference:ConversationVisionReference,conversationID:UUID,operationID:UUID) async throws -> Data
    func remove(conversationID:UUID,operationID:UUID) async throws
}
public actor MemoryConversationImageByteStore:ConversationImageByteStore {
    private var values:[String:Data]=[:]
    public init(){}
    private func key(_ c:UUID,_ o:UUID)->String {c.uuidString+":"+o.uuidString}
    public func save(_ payload:ConversationVisionPayload,conversationID:UUID,operationID:UUID) throws {
        guard payload.reference.isValid,bytesHash(payload.bytes)==payload.reference.receipt.sha256,payload.bytes.count==payload.reference.receipt.size_bytes else {throw ConversationSessionError.invalidEvent}
        values[key(conversationID,operationID)]=payload.bytes
    }
    public func read(reference:ConversationVisionReference,conversationID:UUID,operationID:UUID) throws -> Data {
        guard let data=values[key(conversationID,operationID)],bytesHash(data)==reference.receipt.sha256,data.count==reference.receipt.size_bytes else {throw catError.missing};return data
    }
    public func remove(conversationID:UUID,operationID:UUID){values.removeValue(forKey:key(conversationID,operationID))}
}
public extension ConversationBackend {
    func imageConsent(scope:DataScope,conversationID:UUID,previewID:UUID,previewHash:String) async throws -> ConversationImageConsent {throw ConversationSessionError.notConfigured}
    func allowImageConsent(scope:DataScope,consent:ConversationImageConsent,nonSensitiveConfirmed:Bool) async throws -> Int {throw ConversationSessionError.notConfigured}
}

/// The published API places vision_contract inside chat_capabilities. Do not infer
/// transmission authority from an unrelated/root-level field or readiness alone.
public struct ConversationImageReadiness:Sendable,Equatable {
    public let available:Bool
    public let state:String
    public static func decode(_ data:Data) throws -> Self {
        struct Contract:Decodable {let schema_version:Int?;let available:Bool?;let state:String?}
        struct Capabilities:Decodable {let image_input:Bool?;let vision_contract:Contract?}
        struct Readiness:Decodable {let ready:Bool?;let chat_capabilities:Capabilities?}
        let envelope=try JSONDecoder().decode(Readiness.self,from:data)
        let contract=envelope.chat_capabilities?.vision_contract
        let supported=contract?.schema_version==2
        return .init(available:envelope.ready==true && envelope.chat_capabilities?.image_input==true && supported && contract?.available==true,state:contract?.state ?? "disabled")
    }
}
