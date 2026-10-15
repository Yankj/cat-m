import SwiftUI

/// catpaw.ui.v1 sample payloads (as they would arrive in a ```catpaw-card fence or `render_ui` arguments).
/// Used by previews and `GenerativeBlockCodecTests`; also a reference for the backend proposal.
enum GenerativeBlockFixtures {
    static let choices = #"{"block":{"id":"fx-choices","kind":"choices","title":"周末想做什么？","selection":"single","allowOther":true,"items":[{"id":"hike","label":"徒步","icon":"figure.hiking"},{"id":"movie","label":"看电影","icon":"film"},{"id":"rest","label":"在家休息","detail":"什么都不安排","icon":"sofa"}]}}"#
    static let multiple = #"{"id":"fx-multi","kind":"choices","title":"选择提醒渠道","selection":"multiple","items":[{"id":"push","label":"通知"},{"id":"live","label":"实时活动"},{"id":"mail","label":"邮件"}],"actions":[{"id":"save","label":"保存","style":"primary"}]}"#
    static let confirm = #"{"id":"fx-confirm","kind":"confirm","title":"删除 3 条提醒？","body":"删除后无法恢复。","actions":[{"id":"delete","label":"删除","style":"destructive"},{"id":"keep","label":"保留","style":"secondary"}]}"#
    static let form = #"{"id":"fx-form","kind":"form","title":"新建提醒","fields":[{"id":"title","type":"text","label":"标题","required":true,"placeholder":"例如：交房租"},{"id":"when","type":"datetime","label":"时间"},{"id":"repeat","type":"select","label":"重复","options":["不重复","每天","每周"]},{"id":"loud","type":"toggle","label":"响铃","default":true}]}"#
    static let longForm = #"{"id":"fx-form-sheet","kind":"form","title":"旅行偏好","fields":[{"id":"city","type":"text","label":"目的地","required":true},{"id":"from","type":"date","label":"出发"},{"id":"to","type":"date","label":"返回"},{"id":"people","type":"stepper","label":"人数","default":2},{"id":"budget","type":"number","label":"预算"},{"id":"notes","type":"multiline","label":"备注"}]}"#
    static let card = #"{"id":"fx-card","kind":"card","title":"明早 9:00 提醒你交房租","body":"已加入**提醒**，到时会通知你。","actions":[{"id":"open","label":"查看","style":"primary"},{"id":"snooze","label":"稍后","style":"secondary"}]}"#
    static let list = #"{"id":"fx-list","kind":"list","title":"今天的任务","items":[{"id":"t1","label":"交房租","detail":"09:00","icon":"bell"},{"id":"t2","label":"回复邮件","detail":"14:00","icon":"envelope"}],"actions":[{"id":"open_task","label":"打开"}]}"#
    static let progress = #"{"id":"fx-progress","kind":"progress","title":"正在整理周报","steps":[{"id":"s1","label":"读取本周对话","state":"done"},{"id":"s2","label":"归纳要点","state":"running"},{"id":"s3","label":"生成草稿","state":"pending"}]}"#
    static let sheet = #"{"id":"fx-sheet","kind":"sheet","content":"choices","title":"选择一个主题","items":[{"id":"warm","label":"暖色"},{"id":"cool","label":"冷色"}]}"#
    static let invalid = #"{"id":"fx-bad","kind":"carousel","title":"不支持的组件","body":"降级为卡片显示"}"#
    static let expired = #"{"id":"fx-expired","kind":"confirm","title":"同步日历？","expiresAt":"2020-01-01T00:00:00Z"}"#
    static let all = [choices, multiple, confirm, form, longForm, card, list, progress, sheet, invalid, expired]
}

#if DEBUG
@MainActor struct GenerativeBlockGallery: View {
    @StateObject private var store = GenerativeBlockStore(defaults: nil)
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Array(GenerativeBlockFixtures.all.enumerated()), id: \.offset) { _, json in
                    GenerativeBlockAdapter.view(payload: Data(json.utf8), closed: true, store: store)
                }
                GenerativeBlockAdapter.view(payload: Data(#"{"id":"stream","kind":"choi"#.utf8), closed: false, store: store)
            }.padding(20)
        }
    }
}

#Preview("catpaw.ui.v1 blocks") { GenerativeBlockGallery() }
#Preview("catpaw.ui.v1 blocks · en") { GenerativeBlockGallery().environment(\.locale, Locale(identifier: "en")) }
#endif
