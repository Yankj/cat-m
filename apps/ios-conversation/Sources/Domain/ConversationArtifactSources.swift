import Foundation

public struct ConversationArtifactIdentity:Hashable,Codable,Sendable,Identifiable {
    public let artifactID:String
    public let version:Int
    public let contentHash:String
    public var id:String {artifactID+":"+String(version)+":"+contentHash}
    public init(artifactID:String,version:Int,contentHash:String) {self.artifactID=artifactID;self.version=version;self.contentHash=contentHash}
    public init(_ artifact:ConversationArtifactProjection) {self.init(artifactID:artifact.id,version:artifact.version,contentHash:artifact.contentHash)}
}
public enum ConversationArtifactReadError:Error,LocalizedError,Sendable {
    case missingVersion,identityMismatch
    public var errorDescription:String? {
        switch self {
        case .missingVersion:return "此成果版本尚未保存在本机。请返回原工作读取。"
        case .identityMismatch:return "成果版本或内容核对失败，未切换到其他版本。"
        }
    }
}
public struct ConversationArtifactSource:Sendable,Identifiable,Equatable {
    public var id:String {sourceID}
    public let sourceID:String
    public let readID:UUID
    public let requestedURL:URL
    public let finalURL:URL
    public let readAt:Date
    public let contentHash:String
    public let excerpt:String?
}
public struct ConversationArtifactReading:Sendable {
    /// This validates server-produced receipt metadata; it does not independently prove a fetch.
    public enum SourceStatus:Sendable,Equatable {case none,verified,unverified}
    public let identity:ConversationArtifactIdentity
    public let title:String
    public let summary:String
    public let content:String
    public let updatedAt:Date?
    public let observedAt:Date
    public let sources:[ConversationArtifactSource]
    public let sourceStatus:SourceStatus
    public let history:[ConversationArtifactIdentity]
    public static func resolve(goal:ConversationGoalProjection,selected:ConversationArtifactIdentity) throws -> Self {
        let all=goal.artifacts+goal.artifactHistory
        let candidates=all.filter {$0.id==selected.artifactID && $0.version==selected.version}
        guard !candidates.isEmpty else {throw ConversationArtifactReadError.missingVersion}
        guard selected.version>0,!selected.artifactID.isEmpty,selected.artifactID.utf16.count<=200,isHash(selected.contentHash),candidates.allSatisfy({$0.contentHash==selected.contentHash && $0.body==candidates[0].body}),let artifact=candidates.first,artifact.body.utf8.count<=1_000_000,textHash(artifact.body)==selected.contentHash else {throw ConversationArtifactReadError.identityMismatch}
        let object=(try? JSONSerialization.jsonObject(with:Data(artifact.body.utf8))) as? [String:Any]
        let data=object?["data"] as? [String:Any]
        let title=object?["title"] as? String ?? artifact.title
        let summary=object?["summary"] as? String ?? artifact.summary
        let content=data?["content"] as? String ?? artifact.content
        var status:SourceStatus = .none,sources:[ConversationArtifactSource]=[],updated:Date?
        if let marker=data?["source_contract"] {
            if marker as? String == "sourced-report-v1" {
                status = .unverified
                if let parsed=parseSources(data) {status = .verified;sources=parsed.0;updated=parsed.1}
            }
            // Future source contracts retain their report content without guessing link semantics.
        }
        var versions:[ConversationArtifactIdentity]=[]
        for entry in all where entry.id==selected.artifactID {
            let identity=ConversationArtifactIdentity(entry)
            let duplicates=all.filter {$0.id==entry.id && $0.version==entry.version}
            if entry.version>0,isHash(entry.contentHash),entry.body.utf8.count<=1_000_000,textHash(entry.body)==entry.contentHash,duplicates.allSatisfy({$0.contentHash==entry.contentHash && $0.body==entry.body}),!versions.contains(identity) {versions.append(identity)}
        }
        versions.sort {$0.version>$1.version}
        return .init(identity:selected,title:title,summary:summary,content:content,updatedAt:updated,observedAt:goal.updatedAt,sources:sources,sourceStatus:status,history:versions)
    }
    private static func parseSources(_ data:[String:Any]?) -> ([ConversationArtifactSource],Date)? {
        guard let data,let stamp=data["updated_at"] as? String,let updated=utcDate(stamp),let rows=data["sources"] as? [[String:Any]],!rows.isEmpty,rows.count<=3 else {return nil}
        var sources:[ConversationArtifactSource]=[]
        for row in rows {
            let required:Set<String>=["source_id","read_id","requested_url","final_url","read_at","content_hash"]
            guard Set(row.keys)==required || Set(row.keys)==required.union(["excerpt"]),
                  let sourceID=row["source_id"] as? String,sourceID.range(of:"^[a-zA-Z0-9._:-]{1,160}$",options:.regularExpression)==sourceID.startIndex..<sourceID.endIndex,
                  let readString=row["read_id"] as? String,let readID=UUID(uuidString:readString),
                  let requested=row["requested_url"] as? String,let requestedURL=publicHTTPSURL(requested),
                  let final=row["final_url"] as? String,let finalURL=publicHTTPSURL(final),
                  let readStamp=row["read_at"] as? String,let readAt=utcDate(readStamp),readAt<=updated,
                  let hash=row["content_hash"] as? String,isHash(hash),
                  !sources.contains(where:{$0.sourceID==sourceID || $0.readID==readID}) else {return nil}
            let excerpt:String?
            if let raw=row["excerpt"] {guard let value=raw as? String,value.utf16.count<=1000 else {return nil};excerpt=value} else {excerpt=nil}
            sources.append(.init(sourceID:sourceID,readID:readID,requestedURL:requestedURL,finalURL:finalURL,readAt:readAt,contentHash:hash,excerpt:excerpt))
        }
        return (sources,updated)
    }
    public static func utcDate(_ value:String)->Date? {
        guard !value.hasPrefix("0000-"),value.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$",options:.regularExpression) != nil else {return nil}
        let format=ISO8601DateFormatter();format.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let date=format.date(from:value),format.string(from:date)==value else {return nil};return date
    }
    /// Lexical link admission only. The backend separately owns DNS, redirects and fetch authority.
    public static func publicHTTPSURL(_ value:String)->URL? {
        guard !value.isEmpty,value.utf16.count<=2048,!value.unicodeScalars.contains(where:{$0.value<=0x20 || $0.value==0x7f}),value.range(of:"%(?![a-fA-F0-9]{2})",options:.regularExpression)==nil,
              let parts=URLComponents(string:value),parts.scheme?.lowercased()=="https",parts.user==nil,parts.password==nil,parts.port==nil || parts.port==443,
              let host=parts.host?.lowercased(),host.utf8.count<=253,!host.hasSuffix("."),!host.contains(":"),host.contains("."),let url=parts.url else {return nil}
        let labels=host.split(separator:".",omittingEmptySubsequences:false)
        let reserved:Set<String>=["localhost","local","localdomain","internal","intranet","test","invalid","example","lan","home","onion","corp","private","arpa"]
        guard labels.count>=2,labels.allSatisfy({$0.range(of:"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",options:.regularExpression) != nil}),let last=labels.last,last.count>=2,last.contains(where:{$0.isASCII && $0.isLetter}),!reserved.contains(String(last)),!labels.contains(where:{$0=="localhost"}),host != "metadata.google.internal" else {return nil}
        let credentialQueryKeys:Set<String>=["accesstoken","refreshtoken","idtoken","clientsecret","apikey","authorization","auth","password","passwd","token","secret","signature","sig","xamzsignature","xamzcredential","xamzsecuritytoken","xgoogsignature","xgoogcredential","xgoogsecuritytoken","awsaccesskeyid","oauthtoken","oauthsignature","sessiontoken","sastoken"]
        for raw in (parts.percentEncodedQuery ?? "").split(separator:"&",omittingEmptySubsequences:false) {
            let encoded=raw.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)[0]
            guard var key=String(encoded).replacingOccurrences(of:"+",with:" ").removingPercentEncoding else {return nil}
            // Match the backend's once-decoded query keys and two further encoded-key passes.
            for _ in 0..<2 {
                guard key.range(of:"%[a-fA-F0-9]{2}",options:.regularExpression) != nil,let decoded=key.removingPercentEncoding else {break}
                key=decoded
            }
            key=key.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().replacingOccurrences(of:"-",with:"").replacingOccurrences(of:"_",with:"")
            guard !credentialQueryKeys.contains(key) else {return nil}
        }
        return url
    }
    private static func isHash(_ value:String)->Bool {value.utf8.count==64 && value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
}
