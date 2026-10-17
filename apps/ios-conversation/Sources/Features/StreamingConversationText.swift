import SwiftUI
import UIKit

/// Reuses TextKit storage/layout instead of recreating a large SwiftUI Text per token.
@MainActor final class IncrementalConversationTextView:UITextView {
    private var applied=""
    private var revision=0
    private var measuredRevision = -1
    private var measuredWidth:CGFloat = -1
    private var measuredSize=CGSize.zero
    init(){
        let storage=NSTextStorage(),layout=NSLayoutManager(),container=NSTextContainer(size:.zero)
        storage.addLayoutManager(layout);layout.addTextContainer(container)
        super.init(frame:.zero,textContainer:container)
        isEditable=false;isSelectable=true;isScrollEnabled=false;backgroundColor = .clear
        textContainerInset = .zero;container.lineFragmentPadding=0
        dataDetectorTypes=[];contentInsetAdjustmentBehavior = .never
        // Expose one bounded host AX element; native per-character AX snapshot of a tall text view is costly.
        isAccessibilityElement=false;accessibilityElementsHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) unavailable")}
    func apply(_ value:String,font newFont:UIFont,color:UIColor){
        #if DEBUG
        let start=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("transcript_apply",start:start,end:ProcessInfo.processInfo.systemUptime,main:true,count:value.utf16.count)}
        #endif
        let changedFont=font?.isEqual(newFont) != true || textColor?.isEqual(color) != true
        if changedFont {font=newFont;textColor=color}
        guard value != applied || changedFont else {return}
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=CatpawTypography.readingLineSpacing(for:newFont)
        let attributes:[NSAttributedString.Key:Any]=[.font:newFont,.foregroundColor:color,.paragraphStyle:paragraph]
        let selection=selectedRange
        if !changedFont,value.hasPrefix(applied){
            let tail=String(value.dropFirst(applied.count))
            let start=textStorage.length
            if UIAccessibility.isReduceMotionEnabled || tail.isEmpty {textStorage.append(NSAttributedString(string:tail,attributes:attributes))}
            else {
                // Fade only the newly appended batch (R7: per-batch tail fade, never re-fade the whole answer).
                var faded=attributes;faded[.foregroundColor]=color.withAlphaComponent(0.2)
                textStorage.append(NSAttributedString(string:tail,attributes:faded))
                fadeTail(NSRange(location:start,length:(tail as NSString).length),color:color)
            }
        }
        else {textStorage.setAttributedString(NSAttributedString(string:value,attributes:attributes))}
        applied=value;revision += 1;invalidateIntrinsicContentSize()
        selectedRange=NSRange(location:min(selection.location,textStorage.length),length:min(selection.length,max(0,textStorage.length-selection.location)))
    }
    private func fadeTail(_ range:NSRange,color:UIColor){
        let steps:[CGFloat]=[0.45,0.7,0.88,1]
        for (i,alpha) in steps.enumerated(){
            DispatchQueue.main.asyncAfter(deadline:.now()+Double(i+1)*0.05){[weak self] in
                guard let self,NSMaxRange(range)<=self.textStorage.length else {return}
                self.textStorage.addAttribute(.foregroundColor,value:color.withAlphaComponent(alpha),range:range)
            }
        }
    }
    func measured(_ width:CGFloat)->CGSize {
        if measuredRevision == revision,measuredWidth == width {return measuredSize}
        #if DEBUG
        let start=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("transcript_layout",start:start,end:ProcessInfo.processInfo.systemUptime,main:true,count:applied.utf16.count)}
        #endif
        textContainer.size=CGSize(width:width,height:.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for:textContainer)
        measuredSize=CGSize(width:width,height:max(1,ceil(layoutManager.usedRect(for:textContainer).height)))
        measuredWidth=width;measuredRevision=revision;return measuredSize
    }
}
@MainActor private struct IncrementalConversationText:UIViewRepresentable {
    let text:String
    func makeUIView(context:Context)->IncrementalConversationTextView{IncrementalConversationTextView()}
    func updateUIView(_ view:IncrementalConversationTextView,context:Context){view.isSelectable=context.environment.catpawInlineSelection;view.apply(text,font:ConversationTypeScale.font(context.environment.dynamicTypeSize),color:UIColor(CatpawColors.ink))}
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:IncrementalConversationTextView,context:Context)->CGSize?{uiView.measured(proposal.width ?? 240)}
}
@MainActor struct StreamingConversationText:View {
    /// Characters/second for the paced reveal given the current backlog.
    static func revealRate(backlog:Int,complete:Bool)->Double {
        let base=60.0
        let adaptive=Double(backlog)*(complete ? 3.0:1.2)   // drain big backlogs in ~1 s (complete) / ~0.8 s
        return min(1200,max(base,adaptive))
    }
    let text:String
    let complete:Bool
    @State private var visible=""
    @State private var pending=""
    @State private var flush:Task<Void,Never>?
    @State private var retract:Task<Void,Never>?
    /// IOS-NOTE rule 6: erase only the revealed part of a retracted live tail, in steps over ~0.3 s (LiveTextRetraction).
    private func runRetraction(_ frames:[String]) async {
        for frame in frames {
            guard !Task.isCancelled else {return}   // a newer text change owns `retract` now
            visible=frame
            try? await Task.sleep(nanoseconds:UInt64(0.3/Double(max(1,frames.count))*1_000_000_000))
        }
        guard !Task.isCancelled else {return}
        retract=nil
        if pending != visible,flush == nil {flush=Task {await pace()}}
    }
    private func pace() async {
        defer {flush=nil}
        var last=ProcessInfo.processInfo.systemUptime, carry=0.0
        while !Task.isCancelled {
            let target=pending
            guard target.hasPrefix(visible) else {visible=target;return}
            let backlog=target.count-visible.count
            if backlog<=0 {return}
            try? await Task.sleep(nanoseconds:33_000_000)
            let now=ProcessInfo.processInfo.systemUptime
            carry+=StreamingConversationText.revealRate(backlog:backlog,complete:complete)*(now-last);last=now
            let n=min(backlog,Int(carry))
            guard n>0 else {continue}
            carry-=Double(n)
            visible=String(target.prefix(visible.count+n))
        }
    }
    var body:some View {
        // r10 §3: rich Markdown body. Completed blocks are cached and never re-laid out; the paced
        // reveal still feeds `visible`, which the incremental parser consumes as an append-only stream.
        MarkdownMessageView(text:visible,complete:complete && visible == text).frame(maxWidth:.infinity,alignment:.leading)
            .accessibilityElement(children:.ignore).accessibilityLabel(visible)
            .accessibilityIdentifier("chat.assistantMessage").accessibilityAddTraits(.isStaticText)
            .accessibilityAction(named:Text("\u{590D}\u{5236}\u{56DE}\u{590D}")){UIPasteboard.general.string=visible}
            .onAppear {visible=text;pending=text}
            .onChange(of:text){_,value in
                pending=value
                retract?.cancel();retract=nil
                if !UIAccessibility.isReduceMotionEnabled,let frames=LiveTextRetraction.frames(revealed:visible,target:value) {
                    flush?.cancel();flush=nil;retract=Task {await runRetraction(frames)};return
                }
                // Paced reveal: even if the provider sends one huge text_delta, release it smoothly
                // (~60 chars/s base, adaptive speed-up for big backlogs). Tail-only fade is applied per append.
                if !value.hasPrefix(visible) || UIAccessibility.isReduceMotionEnabled {flush?.cancel();flush=nil;visible=value;return}
                if flush == nil {flush=Task {await pace()}}
            }
            .onChange(of:complete){_,finished in if finished,flush == nil,retract == nil,visible != text {flush=Task {await pace()}}}
            .onDisappear{flush?.cancel();flush=nil;retract?.cancel();retract=nil}
    }
}
