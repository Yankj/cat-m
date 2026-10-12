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
    private struct WeakWitness { weak var view:UIView? }
    var enabled:Bool { P0ExperienceFixture.scenario != nil }
    func start() { guard enabled,link == nil else { return };let l=CADisplayLink(target:self,selector:#selector(tick));l.add(to:.main,forMode:.common);link=l }
    func scene(_ phase:ScenePhase) { active=phase == .active;last=nil;revision += 1 }
    func pressed(_ id:UUID,at time:Double) { guard enabled else { return };presses[id]=time }
    func witness(_ id:UUID,view:UIView) { witnesses[id] = .init(view:view) }
    func update(_ model:ConversationFirstModel) {
        guard enabled else { return }
        identity=["conversation_id":model.conversationID?.uuidString ?? "","turn_id":model.session?.turns.last?.id.uuidString ?? "","turn_state":model.session?.turns.last?.state.rawValue ?? "","outgoing_count":model.outgoingMessages.count,"draft_hash":textHash(model.draft),"composition_active":model.isInputComposing,"network_admission":model.networkAdmissionAllowed]
        revision += 1
    }
    @objc private func tick() {
        guard active else { last=nil;return };let now=ProcessInfo.processInfo.systemUptime
        if let last,intervals.count<1500 { intervals.append((now-last)*1000) };last=now
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
    var json:String {
        var result=identity
        result["fixture_reality"]="injected_synthetic_offline";result["external_network_enabled"]=false
        result["measurement_kind"]="simulator_action_to_visible_geometry_at_display_link_callback"
        result["is_presented_frame_proof"]=false;result["frame_sample_kind"]="active_main_run_loop_display_link_callback_intervals"
        result["frame_intervals_ms"]=intervals;result["echo_samples"]=samples
        result["synthetic_reply_calls"]=P0ExperienceFixture.replyCalls;result["synthetic_observe_calls"]=P0ExperienceFixture.observeCalls
        return (try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys)).map { String(decoding:$0,as:UTF8.self) } ?? "{}"
    }
}
@MainActor struct P0EchoWitness:UIViewRepresentable {
    let operationID:UUID
    func makeUIView(context:Context)->UIView { let view=UIView();view.isUserInteractionEnabled=false;P0ExperienceProbe.shared.witness(operationID,view:view);return view }
    func updateUIView(_ view:UIView,context:Context){P0ExperienceProbe.shared.witness(operationID,view:view)}
}
#endif
