#if DEBUG
import SwiftUI
import UIKit

/// Real Simulator callbacks, not proof of a GPU-presented frame or physical touch down.
@MainActor final class P0ExperienceProbe:ObservableObject {
    static let shared=P0ExperienceProbe()
    @Published private(set) var revision=0
    private var link:CADisplayLink?
    private var active=true,last:Double?
    private var intervals:[Double]=[]
    private var presses:[UUID:Double]=[:]
    private var witnesses:[UUID:WeakWitness]=[:]
    private var samples:[[String:Any]]=[]
    private var identity:[String:Any]=[:]
    private var readingPosition:[String:Any]=[:]
    private var taskReviewStats:[String:Int]=[:]
    private var inputTypography:[String:Any]=[:]
    private var editorVisibility:[String:Any]=[:]
    func recordEditorVisibility(identifier:String,caret:CGRect,visibleBounds:CGRect,selection:NSRange,fontLineHeight:CGFloat) {
        guard enabled,!identifier.isEmpty,!caret.isNull,!visibleBounds.isNull else {return}
        func rect(_ value:CGRect)->[Double] {[Double(value.minX),Double(value.minY),Double(value.width),Double(value.height)]}
        let next:[String:Any]=["editor_field_identifier":identifier,"editor_caret_rect":rect(caret),"editor_visible_bounds":rect(visibleBounds),"editor_selection_utf16":[selection.location,selection.length],"editor_font_line_height":Double(fontLineHeight)]
        guard !NSDictionary(dictionary:next).isEqual(to:editorVisibility) else {return}
        editorVisibility=next;revision += 1
    }
    func recordInputTypography(pointSize:CGFloat,systemCategory:UIContentSizeCategory) {
        guard enabled else {return}
        guard inputTypography["input_font_point_size"] as? Double != Double(pointSize) || inputTypography["input_system_category"] as? String != systemCategory.rawValue else {return}
        inputTypography=["input_font_point_size":Double(pointSize),"input_system_category":systemCategory.rawValue];revision += 1
    }
    func recordTaskReviewStats(_ values:[String:Int]) {taskReviewStats.merge(values){old,new in max(old,new)};revision += 1}
    private var exported=false
    private var callbackPoints:[[String:Any]]=[]
    private struct WeakWitness { weak var view:UIView? }
    var enabled:Bool { P0ExperienceFixture.scenario != nil }
    func start() { guard enabled,link == nil else { return };P0PerformanceLog.shared.startHeartbeat();P0PerformanceLog.shared.mark("probe_start");let l=CADisplayLink(target:self,selector:#selector(tick));l.add(to:.main,forMode:.common);link=l }
    func scene(_ phase:ScenePhase) { P0PerformanceLog.shared.setActive(phase == .active);P0PerformanceLog.shared.mark("scene_"+String(describing:phase));active=phase == .active;last=nil;revision += 1 }
    func pressed(_ id:UUID,at time:Double) { guard enabled else { return };presses[id]=time;P0PerformanceLog.shared.record("press_action",start:time,end:time,main:true) }
    func witness(_ id:UUID,view:UIView) { witnesses[id] = .init(view:view) }
    func update(_ model:ConversationFirstModel) {
        guard enabled else { return }
        P0PerformanceLog.shared.mark("model_update",count:model.session?.messages.last?.content.count ?? 0)
        identity=["conversation_id":model.conversationID?.uuidString ?? "","turn_id":model.session?.turns.last?.id.uuidString ?? "","turn_state":model.session?.turns.last?.state.rawValue ?? "","outgoing_count":model.outgoingMessages.count,"draft_hash":textHash(model.draft),"composition_active":model.isInputComposing,"network_admission":model.networkAdmissionAllowed]
        revision += 1
    }
    @objc private func tick() {
        guard active,!exported else { last=nil;return };let now=ProcessInfo.processInfo.systemUptime
        if let last,intervals.count<1500 { intervals.append((now-last)*1000);callbackPoints.append(["uptime_ns":Int64(now*1e9),"delta_ms":(now-last)*1000,"display_timestamp_ns":Int64((link?.timestamp ?? 0)*1e9)]) };last=now
        for (id,time) in presses {
            guard let view=witnesses[id]?.view,let window=view.window,!view.isHidden,view.alpha>0,view.bounds.width>0,view.bounds.height>0,
                  isVisible(view,in:window) else { continue }
            samples.append(["operation_id":id.uuidString,"press_action_uptime_ns":Int64(time*1e9),"visible_geometry_callback_ns":Int64(now*1e9),"latency_ms":(now-time)*1000]);presses.removeValue(forKey:id)
        }
        if intervals.count % 30 == 0 { revision += 1 }
    }
    private func isVisible(_ view:UIView,in window:UIWindow) -> Bool {
        var visible=view.convert(view.bounds,to:window).intersection(window.bounds),ancestor=view.superview
        while let parent=ancestor {
            if parent.isHidden || parent.alpha == 0 { return false }
            if parent.clipsToBounds { visible=visible.intersection(parent.convert(parent.bounds,to:window)) }
            if visible.isEmpty || visible.isNull { return false };ancestor=parent.superview
        }
        return !visible.isEmpty && !visible.isNull
    }
    func exportMetrics(){exported=true;P0PerformanceLog.shared.freeze();revision += 1}
    func reading(followingLatest:Bool,distance:CGFloat) {
        guard enabled else {return}
        let rounded=Int(distance.rounded())
        guard readingPosition["reading_following_latest"] as? Bool != followingLatest || readingPosition["reading_distance_from_bottom"] as? Int != rounded else {return}
        readingPosition=["reading_following_latest":followingLatest,"reading_distance_from_bottom":rounded];revision += 1
    }
    var json:String {
        let start=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("probe_json_encode",start:start,end:ProcessInfo.processInfo.systemUptime,main:true)}
        var result=identity
        result.merge(readingPosition){_,new in new}
        result.merge(taskReviewStats){_,new in new}
        result.merge(inputTypography){_,new in new}
        result.merge(editorVisibility){_,new in new}
        result["fixture_reality"]="injected_synthetic_offline";result["external_network_enabled"]=false
        result["measurement_kind"]="simulator_action_to_visible_geometry_at_display_link_callback"
        result["is_presented_frame_proof"]=false;result["frame_sample_kind"]="active_main_run_loop_display_link_callback_intervals"
        result["frame_intervals_ms"]=intervals;result["echo_samples"]=samples
        if exported {result["phase_events"]=P0PerformanceLog.shared.snapshot();result["callback_points"]=callbackPoints}
        result["synthetic_consent_calls"]=P0ExperienceFixture.consentCalls;result["synthetic_reply_calls"]=P0ExperienceFixture.replyCalls;result["synthetic_observe_calls"]=P0ExperienceFixture.observeCalls
        return (try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys)).map { String(decoding:$0,as:UTF8.self) } ?? "{}"
    }
}
@MainActor struct P0EchoWitness:UIViewRepresentable {
    let operationID:UUID
    func makeUIView(context:Context)->UIView { let view=UIView();view.isUserInteractionEnabled=false;P0ExperienceProbe.shared.witness(operationID,view:view);return view }
    func updateUIView(_ view:UIView,context:Context){P0ExperienceProbe.shared.witness(operationID,view:view)}
}
#endif
