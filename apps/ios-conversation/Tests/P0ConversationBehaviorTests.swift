import XCTest
@testable import CatpawM

/// Add this file and P0ConversationScenarios.swift to the owner's native test target.
/// Uses isolated temporary stores and a scripted backend; zero real identities/models.
@MainActor final class P0ConversationBehaviorTests:XCTestCase {
 func testP0ConversationBehaviorWithoutNetwork() async throws{
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent("p0-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let results=await P0ConversationScenarios.run(root:dir)
  for result in results{XCTAssertEqual(result["status"] as? String,"PASS",result["case"] as? String ?? "Unknown P0 case")}
  let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:["layer":"native XCTest, scripted backend; no UI/performance pass implied","results":results],options:.sortedKeys),uniformTypeIdentifier:"public.json");proof.name="p0-native-behavior";proof.lifetime = .keepAlways;add(proof)
 }
}
