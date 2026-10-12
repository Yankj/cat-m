import Foundation
@main struct QAPortableRunner {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cases=await QAConversationScenarios.run(root),failed=cases.filter {$0["status"] == "FAIL"}.count
        let report:[String:Any] = ["cases":cases,"passed":cases.count-failed,"failed":failed,"layer":"macOS Swift model/service with FilePersistence and synthetic backend","real_model_requests":0,"real_auth_requests":0,"presented_frame_100ms":"NOT_RUN","device_background_5s_30s":"NOT_RUN","real_weak_network":"NOT_RUN","native_IME":"NOT_RUN"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if failed > 0 { Foundation.exit(1) }
    }
}
