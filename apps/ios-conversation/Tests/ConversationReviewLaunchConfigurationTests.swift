import Foundation
import XCTest
@testable import CatpawM

@MainActor final class ConversationReviewLaunchConfigurationTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_792_000_000)
    private let store="A1000000-0000-4000-8000-000000000001"
    private func environment()->[String:String] {
        ["CATPAW_REVIEW_PERSIST":"1","CATPAW_QA_VISUAL_REVIEW":"1","CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CF_UI_TEST_STORE":store,"CATPAW_ACCEPTED_WORK_PORT":"8772","CATPAW_REVIEW_EXPIRES_AT":"1792000300"]
    }
    private func isolated(_ body:(UserDefaults,String)throws->Void)rethrows {
        let suite="catpaw.review.launch.tests."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        try body(defaults,suite)
    }
    private func save(_ defaults:UserDefaults) { _=ConversationReviewLaunchConfiguration.resolve(environment:environment(),defaults:defaults,now:now) }
    func testExplicitOptInStoresOnlyFourNonSensitiveFieldsAndPlainLaunchRestoresOriginalContext()throws {
        try isolated {defaults,suite in
            let env=environment();XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now),env)
            let bytes=try XCTUnwrap(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey)),object=try ConversationStrictJSON.object(bytes)
            XCTAssertEqual(Set(object.keys),["schema_version","store","port","expires_at"])
            XCTAssertEqual(Set(defaults.persistentDomain(forName:suite)?.keys.map{$0} ?? []),[ConversationReviewLaunchConfiguration.storageKey])
            let restored=ConversationReviewLaunchConfiguration.resolve(environment:[:],defaults:defaults,now:now.addingTimeInterval(100))
            XCTAssertEqual(restored,["CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CF_UI_TEST_STORE":store,"CATPAW_ACCEPTED_WORK_PORT":"8772","CATPAW_QA_VISUAL_REVIEW":"1","CATPAW_REVIEW_EXPIRES_AT":"1792000300"])
            XCTAssertEqual(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey),bytes,"Restoring does not rewrite or extend expiry")
        }
    }
    func testAnyExplicitQAStoreOrScenarioWinsIncludingEmptyAndInvalidSelections()throws {
        try isolated {defaults,_ in
            save(defaults);let original=defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey)
            for env in [["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-reading-growth"],["CF_UI_TEST_SCENARIO":""],["CF_UI_TEST_STORE":"invalid"]] {
                XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now),env)
                XCTAssertEqual(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey),original)
            }
        }
    }
    func testMissingOptInOrVisualModeOrExactScenarioNeverPersists() {
        isolated {defaults,_ in
            for key in ["CATPAW_REVIEW_PERSIST","CATPAW_QA_VISUAL_REVIEW","CATPAW_REVIEW_EXPIRES_AT"] {
                var env=environment();env.removeValue(forKey:key)
                XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now),env)
                XCTAssertNil(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey))
            }
            var env=environment();env["CF_UI_TEST_SCENARIO"]="p0-ui-accepted-work-unknown"
            _=ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now);XCTAssertNil(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey))
        }
    }
    func testInitialPortStoreAndExpiryValidationRejectsCoercionOverflowAndMoreThanSixHours() {
        isolated {defaults,_ in
            let cases:[String:[String]]=["CATPAW_ACCEPTED_WORK_PORT":["1023","65536","8772.0","8.772e3","+8772","08772","true","-1","9223372036854775808"],"CF_UI_TEST_STORE":["bad","",store+"/other"],"CATPAW_REVIEW_EXPIRES_AT":["1792000000","1791999999","1792021601","1792000300.0","1792e6","-1","true","01792000300","9223372036854775808"]]
            for (key,values) in cases {for value in values {var env=environment();env[key]=value;_=ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now);XCTAssertNil(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey),key+"="+value)}}
        }
    }
    func testSixHourBoundaryIsAllowedAndOriginalIntegerExpiryIsPreserved() {
        isolated {defaults,_ in
            var env=environment();env["CATPAW_REVIEW_EXPIRES_AT"]="1792021600"
            _=ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now)
            XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:[:],defaults:defaults,now:now)["CATPAW_REVIEW_EXPIRES_AT"],"1792021600")
        }
    }
    func testExpiredDescriptorIsDroppedAndNormalLaunchProceeds() {
        isolated {defaults,_ in
            for elapsed:TimeInterval in [300,301,86400] {
                save(defaults)
                let value=ConversationReviewLaunchConfiguration.resolve(environment:["OTHER_LOCAL_OPTION":"keep"],defaults:defaults,now:now.addingTimeInterval(elapsed))
                XCTAssertEqual(value,["OTHER_LOCAL_OPTION":"keep"]);XCTAssertNil(value["CF_UI_TEST_SCENARIO"]);XCTAssertNil(value["CATPAW_REVIEW_EXPIRED"])
                XCTAssertNil(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey))
            }
        }
    }
    func testDisableOnlyBlocksFallbackAndDoesNotDeleteTheOriginalDescriptor() {
        isolated {defaults,_ in
            save(defaults);let original=defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey),env=["CATPAW_REVIEW_DISABLE":"1","OTHER_LOCAL_OPTION":"keep"]
            XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now),env)
            XCTAssertEqual(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey),original)
            XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:[:],defaults:defaults,now:now)["CF_UI_TEST_STORE"],store)
        }
    }
    func testBadJSONVersionFieldsTypesUUIDPortAndExpiryAreNotRestored()throws {
        try isolated {defaults,_ in
            save(defaults);let valid=try XCTUnwrap(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey)),object=try ConversationStrictJSON.object(valid)
            var invalid=[Data("{bad".utf8),Data("[]".utf8),Data(String(repeating:" ",count:2049).utf8)]
            let mutations:[(String,Any)]=[("schema_version",2),("schema_version",true),("store","bad"),("port",1023),("port",65536),("port",true),("expires_at",true),("expires_at",-1),("expires_at",1_792_021_601),("expires_at","1792000300")]
            for (key,value) in mutations {
                var candidate=object;candidate[key]=value;invalid.append(try JSONSerialization.data(withJSONObject:candidate,options:.sortedKeys))
            }
            var extra=object;extra["unexpected_field"]="synthetic-only";invalid.append(try JSONSerialization.data(withJSONObject:extra,options:.sortedKeys))
            var missing=object;missing.removeValue(forKey:"port");invalid.append(try JSONSerialization.data(withJSONObject:missing,options:.sortedKeys))
            let text=String(decoding:valid,as:UTF8.self)
            for number in ["1792000300.0","1.7920003e9","9223372036854775808"] {invalid.append(Data(text.replacingOccurrences(of:"1792000300",with:number).utf8))}
            invalid.append(Data(text.replacingOccurrences(of:"\"port\":8772",with:"\"port\":8772,\"port\":8772").utf8))
            for bytes in invalid {defaults.set(bytes,forKey:ConversationReviewLaunchConfiguration.storageKey);XCTAssertTrue(ConversationReviewLaunchConfiguration.resolve(environment:[:],defaults:defaults,now:now).isEmpty)}
        }
    }
    func testUnrelatedEnvironmentSecretsAreNeverStoredAndFallbackPreservesUnrelatedOptions()throws {
        try isolated {defaults,_ in
            var env=environment();env["CATPAW_PRIVATE_MODEL_KEY"]="offline-unused";env["OTHER_LOCAL_OPTION"]="keep"
            XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:env,defaults:defaults,now:now),env)
            let bytes=try XCTUnwrap(defaults.data(forKey:ConversationReviewLaunchConfiguration.storageKey)),text=String(decoding:bytes,as:UTF8.self)
            XCTAssertFalse(text.contains("CATPAW_PRIVATE_MODEL_KEY"));XCTAssertFalse(text.contains("offline-unused"));XCTAssertFalse(text.contains("OTHER_LOCAL_OPTION"))
            XCTAssertEqual(ConversationReviewLaunchConfiguration.resolve(environment:["OTHER_LOCAL_OPTION":"keep"],defaults:defaults,now:now)["OTHER_LOCAL_OPTION"],"keep")
        }
    }
}
