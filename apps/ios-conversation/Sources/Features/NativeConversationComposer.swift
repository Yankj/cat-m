import SwiftUI
import UIKit

@MainActor final class ConversationTextView: UITextView {
    var submit: (() -> Void)?
    var compositionChanged: ((Bool) -> Void)?
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input:"\r",modifierFlags:.command,action:#selector(commandSubmit))] }
    @objc func commandSubmit() { guard markedTextRange == nil else { return };submit?() }
    override func setMarkedText(_ markedText:String?,selectedRange:NSRange) {
        super.setMarkedText(markedText,selectedRange:selectedRange)
        compositionChanged?(markedTextRange != nil);delegate?.textViewDidChange?(self)
    }
    override func unmarkText() { super.unmarkText();compositionChanged?(false);delegate?.textViewDidChange?(self) }
    #if DEBUG
    static weak var fixtureEditor:ConversationTextView?
    #endif
}

/// UIKit owns marked text and selection; SwiftUI never replaces active composition.
@MainActor struct NativeConversationComposer: UIViewRepresentable {
    @ObservedObject var model:ConversationFirstModel
    var enabled=true
    let submit:() -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> ConversationTextView {
        let view=ConversationTextView();view.delegate=context.coordinator
        view.backgroundColor = .clear;view.textColor=UIColor(CatpawColors.ink)
        view.font=ConversationTypeScale.font(context.environment.dynamicTypeSize);view.adjustsFontForContentSizeCategory=true
        view.textContainerInset=UIEdgeInsets(top:8,left:0,bottom:8,right:0)
        view.textContainer.lineFragmentPadding=0;view.returnKeyType = .default
        view.accessibilityLabel=AppLanguage(locale:context.environment.locale).ui("消息");view.accessibilityIdentifier="chat.input"
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        view.submit=submit;view.compositionChanged={ [weak model] in model?.updateInputComposition($0) }
        #if DEBUG
        ConversationTextView.fixtureEditor=view
        #endif
        return view
    }
    func updateUIView(_ view:ConversationTextView,context:Context) {
        #if DEBUG
        let updateStart=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("composer_update",start:updateStart,end:ProcessInfo.processInfo.systemUptime,main:true)}
        #endif
        context.coordinator.parent=self;view.submit=submit;view.isEditable=enabled
        view.accessibilityLabel=AppLanguage(locale:context.environment.locale).ui("消息")
        let font=ConversationTypeScale.font(context.environment.dynamicTypeSize)
        if view.font?.isEqual(font) != true {view.font=font}
        guard view.markedTextRange == nil,view.text != model.draft else { return }
        let old=view.selectedRange;context.coordinator.replacing=true;view.text=model.draft
        view.selectedRange=NSRange(location:min(old.location,view.text.utf16.count),length:0)
        context.coordinator.replacing=false
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:ConversationTextView,context:Context) -> CGSize? {
        #if DEBUG
        let start=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("composer_size_fit",start:start,end:ProcessInfo.processInfo.systemUptime,main:true)}
        #endif
        let width=proposal.width ?? 240,line=uiView.font?.lineHeight ?? 22
        let desired=uiView.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude))
        return CGSize(width:width,height:min(max(line+16,desired.height),line*(context.environment.dynamicTypeSize.isAccessibilitySize ? 3 : 5)+16))
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:NativeConversationComposer
        var replacing=false
        init(_ parent:NativeConversationComposer){self.parent=parent}
        func textViewDidChange(_ textView:UITextView) {
            #if DEBUG
            let changeStart=ProcessInfo.processInfo.systemUptime
            defer {P0PerformanceLog.shared.record("composer_text_delegate",start:changeStart,end:ProcessInfo.processInfo.systemUptime,main:true)}
            #endif
            guard !replacing else { return }
            parent.model.updateInputComposition(textView.markedTextRange != nil)
            parent.model.editDraft(textView.text);textView.invalidateIntrinsicContentSize()
        }
        func textViewDidChangeSelection(_ textView:UITextView) { parent.model.updateInputComposition(textView.markedTextRange != nil) }
    }
}

@MainActor enum ConversationTypeScale {
    static func font(_ size:DynamicTypeSize) -> UIFont {
        let category:UIContentSizeCategory
        switch size {
        case .xSmall:category = .extraSmall
        case .small:category = .small
        case .medium:category = .medium
        case .large:category = .large
        case .xLarge:category = .extraLarge
        case .xxLarge:category = .extraExtraLarge
        case .xxxLarge:category = .extraExtraExtraLarge
        case .accessibility1:category = .accessibilityMedium
        case .accessibility2:category = .accessibilityLarge
        case .accessibility3:category = .accessibilityExtraLarge
        case .accessibility4:category = .accessibilityExtraExtraLarge
        default:category = .accessibilityExtraExtraExtraLarge
        }
        return UIFont.preferredFont(forTextStyle:.body,compatibleWith:UITraitCollection(preferredContentSizeCategory:category))
    }
}

/// Observe the owning scroll view without replacing SwiftUI's delegate.
/// Layout/content growth reports visibility; only a user's scroll changes following.
@MainActor struct ConversationScrollObserver:UIViewRepresentable {
    var position:(CGFloat,Bool)->Void
    func makeUIView(context:Context)->ConversationScrollTrackingView {
        let view=ConversationScrollTrackingView();view.position=position;return view
    }
    func updateUIView(_ view:ConversationScrollTrackingView,context:Context) {view.position=position;view.attachIfNeeded()}
    static func dismantleUIView(_ view:ConversationScrollTrackingView,coordinator:()) {view.detach()}
}

@MainActor final class ConversationScrollTrackingView:UIView {
    var position:((CGFloat,Bool)->Void)?
    private weak var scroll:UIScrollView?
    private var offsetObservation:NSKeyValueObservation?
    private var sizeObservation:NSKeyValueObservation?
    override init(frame:CGRect) {super.init(frame:frame);isUserInteractionEnabled=false}
    required init?(coder:NSCoder) {fatalError("init(coder:) is unavailable")}
    override func didMoveToWindow() {super.didMoveToWindow();attachIfNeeded()}
    override func didMoveToSuperview() {super.didMoveToSuperview();attachIfNeeded()}
    func attachIfNeeded() {
        guard window != nil else {detach();return}
        var ancestor=superview
        while let view=ancestor {
            if let candidate=view as? UIScrollView {
                guard scroll !== candidate else {return}
                detach();scroll=candidate
                offsetObservation=candidate.observe(\.contentOffset,options:[.new]) { [weak self] _,_ in
                    MainActor.assumeIsolated {self?.report(allowUserScroll:true)}
                }
                sizeObservation=candidate.observe(\.contentSize,options:[.new]) { [weak self] _,_ in
                    MainActor.assumeIsolated {self?.report(allowUserScroll:false)}
                }
                report(allowUserScroll:false);return
            }
            ancestor=view.superview
        }
    }
    func detach() {offsetObservation?.invalidate();sizeObservation?.invalidate();offsetObservation=nil;sizeObservation=nil;scroll=nil}
    private func report(allowUserScroll:Bool) {
        guard let scroll else {return}
        let bottom=scroll.contentSize.height+scroll.adjustedContentInset.bottom
        let distance=max(0,bottom-scroll.contentOffset.y-scroll.bounds.height)
        let userScrolled=allowUserScroll && (scroll.isDragging || scroll.isDecelerating)
        // KVO may run during SwiftUI layout; deliver state after that update.
        DispatchQueue.main.async { [weak self,weak scroll] in
            guard let self,let scroll,self.scroll === scroll,self.window != nil else {return}
            self.position?(distance,userScrolled)
        }
    }
}
