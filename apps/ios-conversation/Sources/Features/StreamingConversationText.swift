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
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=6
        let attributes:[NSAttributedString.Key:Any]=[.font:newFont,.foregroundColor:color,.paragraphStyle:paragraph]
        let selection=selectedRange
        if !changedFont,value.hasPrefix(applied){textStorage.append(NSAttributedString(string:String(value.dropFirst(applied.count)),attributes:attributes))}
        else {textStorage.setAttributedString(NSAttributedString(string:value,attributes:attributes))}
        applied=value;revision += 1;invalidateIntrinsicContentSize()
        selectedRange=NSRange(location:min(selection.location,textStorage.length),length:min(selection.length,max(0,textStorage.length-selection.location)))
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
    func updateUIView(_ view:IncrementalConversationTextView,context:Context){view.apply(text,font:ConversationTypeScale.font(context.environment.dynamicTypeSize),color:UIColor(CatpawColors.ink))}
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:IncrementalConversationTextView,context:Context)->CGSize?{uiView.measured(proposal.width ?? 240)}
}
@MainActor struct StreamingConversationText:View {
    let text:String
    let complete:Bool
    @State private var visible=""
    @State private var pending=""
    @State private var flush:Task<Void,Never>?
    var body:some View {
        IncrementalConversationText(text:visible).frame(maxWidth:.infinity,alignment:.leading)
            .accessibilityElement(children:.ignore).accessibilityLabel(visible)
            .accessibilityIdentifier("chat.assistantMessage").accessibilityAddTraits(.isStaticText)
            .accessibilityAction(named:Text("\u{590D}\u{5236}\u{56DE}\u{590D}")){UIPasteboard.general.string=visible}
            .onAppear {visible=text;pending=text}
            .onChange(of:text){_,value in
                pending=value
                if complete {flush?.cancel();flush=nil;visible=value}
                else if flush == nil {flush=Task {try? await Task.sleep(nanoseconds:50_000_000);guard !Task.isCancelled else{return};visible=pending;flush=nil}}
            }
            .onChange(of:complete){_,finished in if finished {flush?.cancel();flush=nil;visible=text}}
            .onDisappear{flush?.cancel();flush=nil}
    }
}
