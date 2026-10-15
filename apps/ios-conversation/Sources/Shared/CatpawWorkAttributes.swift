import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app target and the `CatpawWidgets` extension (add this file to both targets).
/// Shape follows design-tokens-r7.json `liveActivity.attributes`. 三角 owns starting/updating/ending + APNs tokens.
struct CatpawWorkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The 7 Live Activity states (design.md §7).
        enum Status: String, Codable, Hashable {
            case queued        // 已受理，排队中
            case running       // 执行中（显示步骤）
            case needsUser     // 需要你确认/回答
            case waiting       // 等待外部（如上传/第三方），非错误
            case reconnecting  // 云端暂时联系不上，自动重试中
            case done          // 已完成（只来自服务端回执）
            case failed        // 失败 / 结果需核对
        }
        var status: Status
        var stepTitle: String
        var stepIndex: Int
        var stepCount: Int
        var needsUserCardID: String?
        var updatedAt: Date
        var needsUser: Bool { status == .needsUser }
    }
    var taskID: String
    var conversationID: String
    var title: String
}
#endif
