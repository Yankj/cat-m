import Foundation
#if STRICT_JSON_PORTABLE
import Darwin
@main private enum StrictJSONPortable {
    static func main(){do{try StrictJSONScenarios.run();print("PASS bounded strict JSON scenarios; local bytes only")}catch{print("FAIL \(error)");exit(1)}}
}
#else
import XCTest
@testable import cat
final class ConversationStrictJSONTests:XCTestCase {func testBoundedObjectsEscapedKeysAndMalformedBytes() throws {try StrictJSONScenarios.run()}}
#endif
private enum StrictJSONScenarios {
    struct Failure:Error{}
    static func run() throws {
        let good=Data(#"{"a":[null,true,false,-2.5e+3,{"b":"中文 😺 \"quote\" \u2028"}],"x":{"a":1},"y":{"a":2}}"#.utf8)
        guard try ConversationStrictJSON.object(good).count==3 else {throw Failure()}
        // These are distinct JSON names even though Swift String equality normalizes them.
        _=try ConversationStrictJSON.object(Data(#"{"e\u0301":1,"\u00e9":2}"#.utf8))
        for raw in [#"{"a":1,"a":2}"#,#"{"a":1,"\u0061":2}"#,#"{"x":{"a":1,"a":2}}"#,#"{"x":[{"a":1,"a":2}]}"#,
                    #"{"a":01}"#,#"{"a":1.}"#,#"{"a":1e}"#,#"{"a":+1}"#,#"{"a":true,}"#,#"{"a":[1,]}"#,
                    #"{"a":"\x22"}"#,#"{"a":"unterminated}"#,"{\"a\":\"\n\"}","{\"a\":null}{}","[]",String(repeating:"{\"a\":",count:65)+"0"+String(repeating:"}",count:65)] {
            do {_=try ConversationStrictJSON.object(Data(raw.utf8));throw Failure()}catch is ConversationSessionError {}catch is CocoaError {}
        }
        for bytes in [Data([123,34,97,34,58,34,255,34,125]),Data(#"{"a":"\ud800"}"#.utf8),Data(#"{"a":1e9999}"#.utf8)] {
            do {_=try ConversationStrictJSON.object(bytes);throw Failure()}catch is ConversationSessionError {}catch is CocoaError {}
        }
        do {_=try ConversationStrictJSON.object(good,maxBytes:10);throw Failure()}catch is ConversationSessionError {}
        let legalDepth=Data((String(repeating:"{\"a\":",count:64)+"0"+String(repeating:"}",count:64)).utf8)
        _=try ConversationStrictJSON.object(legalDepth)
    }
}
