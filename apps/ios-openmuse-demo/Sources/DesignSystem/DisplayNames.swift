import Foundation
extension MessageState {
    var displayName: String { switch self { case .draft: return "草稿"; case .localSaved: return "已保存到本机"; case .waitingProvider: return "等待模拟回复"; case .streaming: return "正在模拟回复"; case .completed: return "回复已完成"; case .failed: return "回复未完成"; case .cancelled: return "已取消" } }
    func displayName(language: AppLanguage) -> String { language.ui(displayName) }
}
extension WorkState {
    var displayName: String { switch self { case .queued: return "等待开始"; case .preparing: return "准备中"; case .running: return "进行中"; case .verifying: return "核验中"; case .succeeded: return "本轮已完成"; case .waitingApproval: return "等待本次确认"; case .waitingDependency: return "等待资料"; case .retryScheduled: return "等待重试"; case .cancelRequested: return "正在取消"; case .cancelled: return "已取消"; case .failed: return "未完成"; case .outcomeUnknown: return "结果未知，先核验" } }
    func displayName(language: AppLanguage) -> String { language.ui(displayName) }
}
extension DelegationState {
    var displayName: String { switch self { case .draft: return "未保存约定"; case .active: return "继续跟进"; case .paused: return "已暂停"; case .completed: return "已结束"; case .cancelled: return "已取消"; case .expired: return "已到期" } }
    func displayName(language: AppLanguage) -> String { language.ui(displayName) }
}
extension ReceiptStatus {
    var displayName: String { switch self { case .notStarted: return "尚未提交"; case .reserved: return "已预约"; case .dispatchCommitted: return "提交中，先核验"; case .accepted: return "已受理，待核验"; case .verified: return "已核验"; case .failedDefinite: return "明确失败"; case .unknown: return "结果未知，先核验"; case .cancelledBeforeDispatch, .cancelledBeforeTransport: return "提交前已取消" } }
    func displayName(language: AppLanguage) -> String { language.ui(displayName) }
}
extension ApprovalStatus {
    var displayName: String { switch self { case .pending: return "等待本次确认"; case .approved: return "本次已允许"; case .rejected: return "本次未允许"; case .expired: return "确认已到期"; case .invalidated: return "稿件已变化，请重新预览"; case .consumed: return "本次确认已使用"; case .revoked: return "已撤销" } }
    func displayName(language: AppLanguage) -> String { language.ui(displayName) }
}
