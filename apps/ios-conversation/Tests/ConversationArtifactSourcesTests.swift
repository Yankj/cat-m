import Foundation
#if ARTIFACT_SOURCES_PORTABLE
import Darwin
@main private enum ConversationArtifactSourcesPortableRunner {
    static func main() {
        do {
            for (name,test) in ArtifactSourceScenarios.cases {try test();print("PASS "+name)}
            print("PASS \(ArtifactSourceScenarios.cases.count) actual immutable-artifact parser scenarios; synthetic data only, no HTTP/Auth/model/device")
        } catch {print("FAIL "+String(describing:error));exit(1)}
    }
}
#else
import XCTest
@testable import CatpawM
final class ConversationArtifactSourcesTests:XCTestCase {
    func testReceiptMetadataAndLiteralReport() throws {try ArtifactSourceScenarios.validReceipt();try ArtifactSourceScenarios.optionalExcerpt()}
    func testLegacyUnsupportedAndMalformedMetadataFallBack() throws {try ArtifactSourceScenarios.legacy();try ArtifactSourceScenarios.unsupported();try ArtifactSourceScenarios.malformed();try ArtifactSourceScenarios.extraReceiptKeys()}
    func testSourceIDsReceiptsTimesAndBoundsAreStrict() throws {try ArtifactSourceScenarios.identity();try ArtifactSourceScenarios.time();try ArtifactSourceScenarios.bounds();try ArtifactSourceScenarios.duplicateSources()}
    func testPublicHTTPSLinksUseLexicalAdmission() throws {try ArtifactSourceScenarios.urls()}
    func testSelectedVersionNeverFollowsLatest() throws {try ArtifactSourceScenarios.history();try ArtifactSourceScenarios.missing();try ArtifactSourceScenarios.conflict();try ArtifactSourceScenarios.bodyHash()}
}
#endif
private enum ArtifactSourceScenarios {
    struct Failure:Error {let message:String}
    static let cases:[(String,() throws -> Void)]=[
        ("typed receipt metadata + literal report text",validReceipt),("optional receipt excerpt",optionalExcerpt),
        ("legacy local report has no-source fallback",legacy),("unsupported source contract never opens guessed links",unsupported),
        ("supported malformed source data keeps readable report",malformed),("receipt rejects added authority-shaped fields",extraReceiptKeys),
        ("source/read/hash identity checks",identity),("real UTC calendar and publication ordering",time),("metadata bounds",bounds),
        ("duplicate source/read receipts rejected",duplicateSources),("public HTTPS lexical admission",urls),
        ("immutable older version + deduplicated history",history),("missing version does not follow latest",missing),
        ("same id/version collision rejected",conflict),("artifact body hash is verified again",bodyHash)
    ]
    private static let content="Literal [unverified](https://www.swift.org/)\n<script>ignored as text</script>\n![embedded](https://www.swift.org/image.png)"
    private static func check(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    private static func row(_ updates:[String:Any]=[:])->[String:Any] {
        var value:[String:Any]=["source_id":"source-1","read_id":"11111111-2222-4333-8444-555555555555","requested_url":"https://www.swift.org/documentation/?q=swift%20url","final_url":"https://www.swift.org/documentation/","read_at":"2026-10-14T01:00:00.000Z","content_hash":textHash("explicit synthetic raw HTTP bytes")]
        value.merge(updates){_,new in new};return value
    }
    private static func artifact(version:Int=1,id:String="fixture-artifact",data:[String:Any]?=nil) throws -> ConversationArtifactProjection {
        let payload=data ?? ["content":content,"source_contract":"sourced-report-v1","updated_at":"2026-10-14T01:01:00.000Z","sources":[row()]]
        let bytes=try JSONSerialization.data(withJSONObject:["kind":"report","title":"Offline fixture report","summary":"Synthetic source metadata, not a fetched webpage","data":payload],options:[.sortedKeys,.withoutEscapingSlashes]),body=String(decoding:bytes,as:UTF8.self)
        return .init(id:id,version:version,contentHash:textHash(body),body:body,title:"Offline fixture report",summary:"Synthetic source metadata, not a fetched webpage",content:content)
    }
    private static func goal(_ current:[ConversationArtifactProjection],history:[ConversationArtifactProjection]=[])->ConversationGoalProjection {
        var value=ConversationGoalProjection(id:"fixture-task",revision:1,title:"Offline report",state:.completed,summary:"Synthetic parser fixture only",updatedAt:Date(timeIntervalSince1970:1791939660));value.artifacts=current;value.artifactHistory=history;return value
    }
    private static func reading(data:[String:Any]) throws -> ConversationArtifactReading {
        let value=try artifact(data:data);return try .resolve(goal:goal([value]),selected:.init(value))
    }
    private static func sourced(_ rows:[[String:Any]],updated:String="2026-10-14T01:01:00.000Z")->[String:Any] { ["content":content,"source_contract":"sourced-report-v1","updated_at":updated,"sources":rows] }
    private static func unverified(_ data:[String:Any]) throws {let value=try reading(data:data);try check(value.sourceStatus == .unverified && value.sources.isEmpty && value.content==content,"Malformed metadata changed text or enabled source links")}
    static func validReceipt() throws {
        let value=try reading(data:sourced([row()]));try check(value.sourceStatus == .verified && value.sources.count==1 && value.content==content,"Valid receipt metadata or literal text mismatch")
        try check(value.sources[0].sourceID=="source-1" && value.sources[0].finalURL.absoluteString=="https://www.swift.org/documentation/" && value.updatedAt != nil,"Pinned metadata missing")
        let three=try reading(data:sourced([row(),row(["source_id":"source-2","read_id":UUID().uuidString]),row(["source_id":"source-3","read_id":UUID().uuidString])]))
        try check(three.sources.map(\.sourceID)==["source-1","source-2","source-3"],"Three-source catalog order changed")
    }
    static func optionalExcerpt() throws {let value=try reading(data:sourced([row(["excerpt":"<b>literal excerpt</b>"])]));try check(value.sources[0].excerpt=="<b>literal excerpt</b>","Excerpt was transformed")}
    static func legacy() throws {let value=try reading(data:["content":content,"source":"model_local_output"]);try check(value.sourceStatus == .none && value.sources.isEmpty && value.content==content,"Routine local report became faulty or linked")}
    static func unsupported() throws {let value=try reading(data:["content":content,"source_contract":"future-report-v2","sources":[row()]]);try check(value.sourceStatus == .none && value.sources.isEmpty && value.content==content,"Future contract guessed URL semantics")}
    static func malformed() throws {try unverified(["content":content,"source_contract":"sourced-report-v1","sources":[row()]]);try unverified(sourced([]));try unverified(sourced([row(["read_at":42])]))}
    static func extraReceiptKeys() throws {try unverified(sourced([row(["execute":true])]))}
    static func identity() throws {
        for updates in [["source_id":"source 1"],["source_id":"source-1\n"],["read_id":"not-a-uuid"],["content_hash":String(repeating:"A",count:64)],["content_hash":String(repeating:"a",count:64)+"\n"]] {try unverified(sourced([row(updates)]))}
    }
    static func time() throws {
        for stamp in ["2026-02-30T00:00:00.000Z","0000-01-01T00:00:00.000Z","2026-10-14T01:00:00Z","2026-10-14T01:00:00.000+00:00","2026-10-14T02:00:00.000Z"] {try unverified(sourced([row(["read_at":stamp])]))}
    }
    static func bounds() throws {try unverified(sourced([row(["excerpt":String(repeating:"x",count:1001)])]));try unverified(sourced([row(["source_id":String(repeating:"x",count:161)])]));try unverified(sourced([row(["final_url":"https://www.swift.org/"+String(repeating:"x",count:2048)])]));try unverified(sourced([row(),row(),row(),row()]))}
    static func duplicateSources() throws {
        try unverified(sourced([row(),row(["read_id":UUID().uuidString])]))
        try unverified(sourced([row(),row(["source_id":"source-2"])]))
    }
    static func urls() throws {
        for url in ["https://www.swift.org/","https://developer.apple.com/documentation/swift?x=a%20b#intro","https://docs.example.com:443/public","https://www.swift.org/documentation/?hl=en&page=2&q=access_token"] {try check(ConversationArtifactReading.publicHTTPSURL(url) != nil,"Rejected public HTTPS lexical URL")}
        for url in ["http://www.swift.org/","javascript:alert(1)","file:///tmp/private","https://user:pass@www.swift.org/","https://localhost/","https://a.local/","https://a.internal/","https://singlelabel/","https://127.0.0.1/","https://192.168.1.2/","https://[::1]/","https://0x7f000001/","https://www.swift.org:8443/","https://www.swift.org/path with space","https://www.swift.org/%xx","https://a.invalid/","https://a.home.arpa/"] {try check(ConversationArtifactReading.publicHTTPSURL(url)==nil,"Unsafe or malformed URL enabled")}
        let credentialKeys=["access_token","refresh_token","id_token","client_secret","api_key","authorization","auth","password","passwd","token","secret","signature","sig","X-Amz-Signature","X-Amz-Credential","X-Amz-Security-Token","X-Goog-Signature","X-Goog-Credential","X-Goog-Security-Token","AWSAccessKeyId","oauth_token","oauth_signature","session_token","sas_token","%61ccess_token","%2561ccess_token","%252561ccess_token","PASSWORD","+password+"]
        for key in credentialKeys {
            let url="https://www.swift.org/documentation/?hl=en&"+key+"=synthetic-fake-value"
            try check(ConversationArtifactReading.publicHTTPSURL(url)==nil,"Credential-shaped query key enabled")
            for field in ["requested_url","final_url"] {try unverified(sourced([row([field:url])]))}
        }
    }
    static func history() throws {
        let old=try artifact(),new=try artifact(version:2,data:["content":"New result","source":"model_local_output"])
        let value=try ConversationArtifactReading.resolve(goal:goal([new],history:[old,old,new]),selected:.init(old))
        try check(value.identity.version==1 && value.content==content && value.history.map(\.version)==[2,1],"History followed latest or duplicated immutable version")
    }
    static func missing() throws {
        let new=try artifact(version:2)
        do {_ = try ConversationArtifactReading.resolve(goal:goal([new]),selected:.init(artifactID:new.id,version:1,contentHash:new.contentHash));throw Failure(message:"Missing version followed latest")}catch ConversationArtifactReadError.missingVersion {}
    }
    static func conflict() throws {
        let original=try artifact(),other=try artifact(data:["content":"Conflicting bytes"])
        do {_ = try ConversationArtifactReading.resolve(goal:goal([original],history:[other]),selected:.init(original));throw Failure(message:"Conflicting same version accepted")}catch ConversationArtifactReadError.identityMismatch {}
    }
    static func bodyHash() throws {
        let original=try artifact(),broken=ConversationArtifactProjection(id:original.id,version:1,contentHash:original.contentHash,body:original.body+" ",title:original.title,summary:original.summary,content:original.content)
        do {_ = try ConversationArtifactReading.resolve(goal:goal([broken]),selected:.init(broken));throw Failure(message:"Hash mismatch accepted")}catch ConversationArtifactReadError.identityMismatch {}
    }
}
