import XCTest
@testable import CatpawM
@MainActor final class QAIndependentTests: XCTestCase {
    func root() throws -> URL { let p=FileManager.default.temporaryDirectory.appendingPathComponent("qa-dialogue-"+UUID().uuidString);try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true);return p }
    func testHeldConsentStableFeedback() async throws { try await QAConversationScenarios.consentFeedback(root()) }
    func testDuplicateTapsAndIdenticalIntentFIFO() async throws { try await QAConversationScenarios.duplicateTapAndIntentFIFO(root()) }
    func testHeldReadDedupAndUnknownRecovery() async throws { try await QAConversationScenarios.repeatedReadRecoversUnknownOnce(root()) }
    func testReadIndependentOfReadiness() async throws { try await QAConversationScenarios.foregroundReadIndependentOfReadiness(root()) }
    func testLateObserverCannotClearReplacement() async throws { try await QAConversationScenarios.staleReadCannotClearReplacement(root()) }
    func testSwiftDataUserPauseAndExactDraftReopen() async throws { try await QAConversationScenarios.userPauseAndDraftSurviveReopen(root()) }
    func testCompositionModelGuard() async throws { try await QAConversationScenarios.compositionGuard(root()) }
    func testSwiftDataFailedAdmissionRollback() async throws { try await QAConversationScenarios.swiftDataAdmissionRollback(root()) }
    func testLegacyEightScenariosOnFrozenPending() async throws {
        let directory=try root();let cases=await P0ConversationScenarios.run(root:directory)
        XCTAssertEqual(cases.count,8)
        for c in cases { XCTAssertEqual(c["status"] as? String,"PASS",c["case"] as? String ?? "missing case") }
    }
}
