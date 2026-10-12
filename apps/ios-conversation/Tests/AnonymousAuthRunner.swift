import Foundation
@main struct AnonymousAuthRunner {
 static func main() async throws { try await AnonymousAuthScenarios.run();print("Anonymous auth boundary suite complete; real HTTP calls: 0") }
}
