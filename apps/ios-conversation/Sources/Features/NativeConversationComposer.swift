import SwiftUI
import UIKit

@MainActor final class ConversationTextView: CatpawEditingTextView {
    private let placeholderLabel=UILabel()
    var submit: (() -> Void)?
    var addAttachments: (([ComposerAttachment]) -> Void)?
    var compositionChanged: ((Bool) -> Void)?
    var lineCountChanged: ((Int) -> Void)?
    private var reportedLineCount = 0
    static weak var current:ConversationTextView?
    /// Mic/voice MVP: focus the editor so the keyboard dictation key is one tap away.
    static func focusComposer(){ current?.becomeFirstResponder() }
    func setPlaceholder(_ value:String,font:UIFont) {
        if placeholderLabel.superview == nil {
            placeholderLabel.isUserInteractionEnabled=false;placeholderLabel.isAccessibilityElement=false
            addSubview(placeholderLabel)
        }
        placeholderLabel.text=value;placeholderLabel.font=font;placeholderLabel.textColor=UIColor(CatpawColors.secondary)
        refreshPlaceholder();setNeedsLayout()
    }
    func refreshPlaceholder() {placeholderLabel.isHidden = !text.isEmpty;accessibilityValue=text.isEmpty ? placeholderLabel.text:nil}
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input:"\r",modifierFlags:.command,action:#selector(commandSubmit))] }
    @objc func commandSubmit() { guard markedTextRange == nil else { return };submit?() }
    override func paste(_ sender: Any?) {
        if let addAttachments, ComposerPasteHandling.intercept(add: addAttachments) { return }
        super.paste(sender)
    }
    override func setMarkedText(_ markedText:String?,selectedRange:NSRange) {
        super.setMarkedText(markedText,selectedRange:selectedRange)
        compositionChanged?(markedTextRange != nil);delegate?.textViewDidChange?(self)
    }
    override func unmarkText() { super.unmarkText();compositionChanged?(false);delegate?.textViewDidChange?(self) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let x=textContainerInset.left+textContainer.lineFragmentPadding
        placeholderLabel.frame=CGRect(x:x,y:textContainerInset.top,width:max(0,bounds.width-x-textContainerInset.right-textContainer.lineFragmentPadding),height:placeholderLabel.font.lineHeight)
        reportLineCount()
    }
    func reportLineCount() {
        layoutManager.ensureLayout(for:textContainer)
        let range=layoutManager.glyphRange(for:textContainer)
        var count=0
        layoutManager.enumerateLineFragments(forGlyphRange:range) { _,_,_,_,_ in count += 1 }
        count=max(1,count)
        guard count != reportedLineCount else {return}
        reportedLineCount=count
        let changed=lineCountChanged
        DispatchQueue.main.async {changed?(count)}
    }
    #if DEBUG
    static weak var fixtureEditor:ConversationTextView?
    #endif
}

/// UIKit owns marked text and selection; SwiftUI never replaces active composition.
@MainActor struct NativeConversationComposer: UIViewRepresentable {
    @ObservedObject var model:ConversationFirstModel
    var enabled=true
    /// The host may supply the remaining viewport after association/status chrome.
    /// A finite SwiftUI proposal is also respected; the text itself then scrolls.
    var maximumVisibleHeight:CGFloat? = nil
    var placeholder:String = ""
    var lineCountChanged:((Int)->Void)? = nil
    var addAttachments:(([ComposerAttachment])->Void)? = nil
    let submit:() -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> ConversationTextView {
        let view=ConversationTextView();view.delegate=context.coordinator
        view.backgroundColor = .clear;view.textColor=UIColor(CatpawColors.ink)
        view.font=ConversationTypeScale.font(context.environment.dynamicTypeSize);view.adjustsFontForContentSizeCategory=false
        view.textContainerInset=UIEdgeInsets(top:7,left:6,bottom:7,right:6)
        view.textContainer.lineFragmentPadding=0;view.returnKeyType = .default
        view.accessibilityLabel=AppLanguage(locale:context.environment.locale).ui("消息");view.accessibilityIdentifier="chat.input"
        view.setPlaceholder(AppLanguage(locale:context.environment.locale).ui(placeholder),font:ConversationTypeScale.font(context.environment.dynamicTypeSize))
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        view.submit=submit;view.addAttachments=addAttachments;view.lineCountChanged=lineCountChanged;view.compositionChanged={ [weak model] in model?.updateInputComposition($0) }
        #if DEBUG
        ConversationTextView.fixtureEditor=view
        #endif
        ConversationTextView.current=view
        return view
    }
    func updateUIView(_ view:ConversationTextView,context:Context) {
        #if DEBUG
        let updateStart=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("composer_update",start:updateStart,end:ProcessInfo.processInfo.systemUptime,main:true)}
        #endif
        context.coordinator.parent=self;view.submit=submit;view.addAttachments=addAttachments;view.lineCountChanged=lineCountChanged;view.isEditable=enabled
        view.accessibilityLabel=AppLanguage(locale:context.environment.locale).ui("消息")
        let font=ConversationTypeScale.font(context.environment.dynamicTypeSize)
        let fontChanged=view.font?.isEqual(font) != true
        if fontChanged {view.font=font}
        view.setPlaceholder(AppLanguage(locale:context.environment.locale).ui(placeholder),font:font)
        #if DEBUG
        let renderedPointSize=font.pointSize,systemCategory=view.traitCollection.preferredContentSizeCategory
        DispatchQueue.main.async {P0ExperienceProbe.shared.recordInputTypography(pointSize:renderedPointSize,systemCategory:systemCategory)}
        #endif
        guard view.markedTextRange == nil,view.text != model.draft else {if fontChanged {view.keepSelectionVisible()};view.reportLineCount();return}
        let old=view.selectedRange;context.coordinator.replacing=true;view.text=model.draft
        view.selectedRange=NSRange(location:min(old.location,view.text.utf16.count),length:0)
        context.coordinator.replacing=false
        view.refreshPlaceholder();view.keepSelectionVisible();view.reportLineCount()
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:ConversationTextView,context:Context) -> CGSize? {
        #if DEBUG
        let start=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("composer_size_fit",start:start,end:ProcessInfo.processInfo.systemUptime,main:true)}
        #endif
        let width=proposal.width ?? 240,line=uiView.font?.lineHeight ?? 22
        // SwiftUI probes several proposals per layout pass (and every keystroke re-lays
        // out the whole host). A full TextKit measure per probe showed up as the top app
        // frame in keyboard/typing stalls, so reuse it while text, font and width match.
        let desired:CGSize
        let cache=context.coordinator.measured
        if let cache,cache.width==width,cache.pointSize==(uiView.font?.pointSize ?? 0),cache.text==uiView.text {desired=cache.size}
        else {
            desired=uiView.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude))
            context.coordinator.measured=(width,uiView.font?.pointSize ?? 0,uiView.text,desired)
        }
        let available=[maximumVisibleHeight,proposal.height].compactMap{$0}.filter{$0.isFinite}.map{max(0,$0)}.min()
        return CGSize(width:width,height:CatpawTextViewport.composerHeight(desired:desired.height,lineHeight:line,textInsets:16,maximumLines:5,availableHeight:available))
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:NativeConversationComposer
        var replacing=false
        var measured:(width:CGFloat,pointSize:CGFloat,text:String,size:CGSize)?
        init(_ parent:NativeConversationComposer){self.parent=parent}
        func textViewDidChange(_ textView:UITextView) {
            #if DEBUG
            let changeStart=ProcessInfo.processInfo.systemUptime
            defer {P0PerformanceLog.shared.record("composer_text_delegate",start:changeStart,end:ProcessInfo.processInfo.systemUptime,main:true)}
            #endif
            guard !replacing else { return }
            parent.model.updateInputComposition(textView.markedTextRange != nil)
            parent.model.editDraft(textView.text);textView.invalidateIntrinsicContentSize();(textView as? ConversationTextView)?.refreshPlaceholder();(textView as? ConversationTextView)?.reportLineCount()
            (textView as? CatpawEditingTextView)?.noteTextChanged()
        }
        func textViewDidChangeSelection(_ textView:UITextView) {
            parent.model.updateInputComposition(textView.markedTextRange != nil)
            (textView as? CatpawEditingTextView)?.keepSelectionVisible()
        }
    }
}

@MainActor enum ConversationTypeScale {
    static func font(_ size:DynamicTypeSize) -> UIFont {
        CatpawTypography.font(size:size)
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
