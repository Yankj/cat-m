import Foundation
import Observation

@Observable
final class AppStore {
    var memories: [MemoryItem] = [
        .init(content: "不吃香菜", kind: .profile),
        .init(content: "周三通常下午有客户会", kind: .procedural),
        .init(content: "上周把周五会议改到了周四", kind: .episodic, confidence: 0.85)
    ]

    var proactiveItems: [ProactiveItem] = [
        .init(
            title: "日程冲突",
            reason: "因为你 15:00 有会议，且当前路况预计延误 12 分钟",
            actionPreview: "建议提前 15 分钟出发，并通知参会人可能晚到 5 分钟",
            risk: .medium
        ),
        .init(
            title: "云端任务完成",
            reason: "因为你早上发起的门店评价分析已完成",
            actionPreview: "查看报告并确认是否推送给团队",
            risk: .low
        )
    ]

    var actionLogs: [ActionLog] = []

    var proactiveEnabled = true
    var doNotDisturb: Bool = false

    func addMemory(_ content: String, kind: MemoryItem.Kind) {
        memories.insert(.init(content: content, kind: kind), at: 0)
    }

    func removeMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
    }

    func confirmProactive(_ item: ProactiveItem) {
        proactiveItems.removeAll { $0.id == item.id }
        actionLogs.insert(
            .init(description: item.title, outcome: "已确认并执行：\(item.actionPreview)"),
            at: 0
        )
    }

    func dismissProactive(_ item: ProactiveItem) {
        proactiveItems.removeAll { $0.id == item.id }
        actionLogs.insert(
            .init(description: item.title, outcome: "已忽略"),
            at: 0
        )
    }
}
