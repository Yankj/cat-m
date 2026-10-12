import Foundation
import Darwin
@main struct ObservationEpochRunner { static func main() async { do { try await verifySceneObservationReplacement() } catch { print("FAIL: \(error.localizedDescription)");exit(1) } } }
