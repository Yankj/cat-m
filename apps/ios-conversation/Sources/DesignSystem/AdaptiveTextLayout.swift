import SwiftUI
import UIKit

/// SwiftUI's environment is the authority for text size, including an in-app override.
/// UIKit must use that same category, rather than silently reverting to the window's trait.
@MainActor enum CatpawTypography {
    enum Role { case appTitle, title, heading, body, secondary, caption, table
        var font:Font {
            switch self {
            case .appTitle: .largeTitle
            case .title: .title2
            case .heading: .headline
            case .body: .body
            case .secondary: .subheadline
            case .caption: .footnote
            case .table: .callout
            }
        }
        var textStyle:UIFont.TextStyle {
            switch self {
            case .appTitle: .largeTitle
            case .title: .title2
            case .heading: .headline
            case .body: .body
            case .secondary: .subheadline
            case .caption: .footnote
            case .table: .callout
            }
        }
    }
    static func category(_ size:DynamicTypeSize)->UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .extraExtraExtraLarge
        }
    }
    static func font(_ role:Role = .body,size:DynamicTypeSize)->UIFont {
        UIFont.preferredFont(forTextStyle:role.textStyle,compatibleWith:UITraitCollection(preferredContentSizeCategory:category(size)))
    }
}

/// An intrinsic-width row may fit at ordinary size. Otherwise title and metadata
/// use separate full-width lines; metadata never squeezes words into a thin column.
struct CatpawAdaptiveHeader:View {
    let title:String
    var detail:String?=nil
    var symbol:String?=nil
    var titleRole:CatpawTypography.Role = .heading
    var detailRole:CatpawTypography.Role = .caption
    var weight:Font.Weight = .semibold
    @Environment(\.dynamicTypeSize) private var size
    private var titleText:some View {Text(verbatim:title).font(titleRole.font.weight(weight))}
    private var metadata:some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            if let symbol {Image(systemName:symbol).accessibilityHidden(true)}
            if let detail {Text(verbatim:detail).font(detailRole.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true)}
        }
    }
    private var stacked:some View {
        VStack(alignment:.leading,spacing:8) {
            titleText.fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
            metadata
        }
    }
    var body:some View {
        Group {
            if size.isAccessibilitySize {stacked}
            else {
                ViewThatFits(in:.horizontal) {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        if let symbol {Image(systemName:symbol).accessibilityHidden(true)}
                        titleText.fixedSize()
                        if let detail {Text(verbatim:detail).font(detailRole.font).foregroundStyle(CatpawColors.secondary).fixedSize()}
                    }.fixedSize(horizontal:true,vertical:false)
                    stacked
                }
            }
        }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
            .accessibilityElement(children:.ignore).accessibilityLabel(title+(detail.map{"、"+$0} ?? ""))
    }
}

/// Reading titles wrap. Compact association bars may truncate a title, but never
/// spend the version's width on that title. VoiceOver receives the complete value.
struct CatpawVersionedTitle:View {
    enum Arrangement {case reading,compact}
    let title:String
    let version:String
    var layout:Arrangement = .reading
    var titleAccessibilityIdentifier:String? = nil
    var versionAccessibilityIdentifier:String? = nil
    private var titleText:some View {
        Text(verbatim:title).font(layout == .reading ? CatpawTypography.Role.title.font.weight(.semibold) : CatpawTypography.Role.caption.font)
            .accessibilityAddTraits(layout == .reading ? .isHeader : [])
            .accessibilityIdentifier(titleAccessibilityIdentifier ?? "")
    }
    private var versionText:some View {
        Text(verbatim:version).font(layout == .reading ? CatpawTypography.Role.secondary.font : CatpawTypography.Role.caption.font)
            .foregroundStyle(CatpawColors.secondary)
            .accessibilityIdentifier(versionAccessibilityIdentifier ?? "")
    }
    var body:some View {
        if layout == .reading {
            VStack(alignment:.leading,spacing:10) {
                titleText.fixedSize(horizontal:false,vertical:true)
                versionText.fixedSize(horizontal:false,vertical:true)
            }
        } else {
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    titleText.lineLimit(1).truncationMode(.tail).frame(maxWidth:.infinity,alignment:.leading)
                    versionText.fixedSize()
                }
                VStack(alignment:.leading,spacing:4) {
                    titleText.lineLimit(1).truncationMode(.tail)
                    versionText.fixedSize(horizontal:false,vertical:true)
                }
            }.accessibilityElement(children:.ignore).accessibilityLabel(title+" · "+version)
        }
    }
}

/// Keep a control area as a sibling of the scroll viewport. Insetting an overlay
/// into a nested editor can leave a visible text-view frame with a hidden caret.
struct CatpawBottomActionArea<Content:View>:View {
    @ViewBuilder var content:Content
    var body:some View {
        VStack(spacing:8){content}.padding(.horizontal,20).padding(.vertical,10)
            .frame(maxWidth:.infinity).fixedSize(horizontal:false,vertical:true)
            .background(.regularMaterial)
    }
}

struct CatpawAdaptiveActions<Content:View>:View {
    @Environment(\.dynamicTypeSize) private var size
    @ViewBuilder var content:Content
    var body:some View {
        if size.isAccessibilitySize {VStack(alignment:.leading,spacing:12){content}}
        else {
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.firstTextBaseline,spacing:12){content}
                VStack(alignment:.leading,spacing:12){content}
            }
        }
    }
}

/// Modal roots receive the presenting text/locale environment in one place.
/// This also makes an accessibility override behave consistently across a sheet.
private struct CatpawSheetModifier<Sheet:View>:ViewModifier {
    @Binding var isPresented:Bool
    var onDismiss:(()->Void)?
    @ViewBuilder var sheet:()->Sheet
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.locale) private var locale
    func body(content:Content)->some View {
        content.sheet(isPresented:$isPresented,onDismiss:onDismiss) {
            sheet().environment(\.dynamicTypeSize,textSize).environment(\.locale,locale)
        }
    }
}
private struct CatpawItemSheetModifier<Item:Identifiable,Sheet:View>:ViewModifier {
    @Binding var item:Item?
    var onDismiss:(()->Void)?
    @ViewBuilder var sheet:(Item)->Sheet
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.locale) private var locale
    func body(content:Content)->some View {
        content.sheet(item:$item,onDismiss:onDismiss) {item in
            sheet(item).environment(\.dynamicTypeSize,textSize).environment(\.locale,locale)
        }
    }
}
extension View {
    func catpawSheet<Sheet:View>(isPresented:Binding<Bool>,onDismiss:(()->Void)?=nil,@ViewBuilder content:@escaping()->Sheet)->some View {
        modifier(CatpawSheetModifier(isPresented:isPresented,onDismiss:onDismiss,sheet:content))
    }
    func catpawSheet<Item:Identifiable,Sheet:View>(item:Binding<Item?>,onDismiss:(()->Void)?=nil,@ViewBuilder content:@escaping(Item)->Sheet)->some View {
        modifier(CatpawItemSheetModifier(item:item,onDismiss:onDismiss,sheet:content))
    }
}

/// Sizes are derived from rendered font metrics and the actual unobscured area.
/// A field larger than that area scrolls internally; labels may scroll above it.
enum CatpawTextViewport {
    static func hasUncommittedCaretExtent(contentHeight:CGFloat,caretBottom:CGFloat,screenScale:CGFloat)->Bool {
        let pixel=1/max(1,screenScale)
        // Scroll extent must contain the actual caret. Desired decorative
        // padding belongs to scrollRectToVisible, not to commit validity.
        return contentHeight+pixel<caretBottom
    }
    struct ComposerBudget {
        let maximumTextHeight:CGFloat
        let contextHeight:CGFloat
        let transcriptHeight:CGFloat
        let showsTarget:Bool
        let compactPadding:Bool
    }
    static func height(bounds:CGRect,safeAreaTop:CGFloat,safeAreaBottom:CGFloat,bottomBoundary:CGFloat?)->CGFloat {
        let top=bounds.minY+max(0,safeAreaTop)
        let bottom=min(bounds.maxY-max(0,safeAreaBottom),bottomBoundary ?? bounds.maxY)
        return max(0,bottom-top)
    }
    static func visibleBounds(bounds:CGRect,safeBounds:CGRect,keyboardTop:CGFloat?)->CGRect {
        var visible=bounds.intersection(safeBounds)
        guard !visible.isNull else {return .zero}
        if let keyboardTop,keyboardTop.isFinite {
            visible.size.height=max(0,min(visible.maxY,keyboardTop)-visible.minY)
        }
        return visible
    }
    static func editorHeight(preferred:CGFloat,viewport:CGFloat,labelHeight:CGFloat,spacing:CGFloat,lineHeight:CGFloat,textInsets:CGFloat)->CGFloat {
        let minimum=max(0,lineHeight)+max(0,textInsets)
        let available=max(0,viewport-max(0,labelHeight)-max(0,spacing))
        // If even a full line cannot fit, preserve that line and let the outer
        // scroll move the label out of view. Never reduce the user's font.
        return min(max(minimum,preferred),max(minimum,available))
    }
    static func composerHeight(desired:CGFloat,lineHeight:CGFloat,textInsets:CGFloat,maximumLines:Int,availableHeight:CGFloat?)->CGFloat {
        let minimum=max(0,lineHeight)+max(0,textInsets)
        let semanticLimit=lineHeight*CGFloat(max(1,maximumLines))+textInsets
        let available=availableHeight.flatMap{$0.isFinite ? max(0,$0):nil} ?? semanticLimit
        return min(max(minimum,desired),max(minimum,min(semanticLimit,available)))
    }
    /// Allocate scarce height by user need: the editable line and send control,
    /// the current target, then a readable transcript and bounded context.
    /// A context that cannot fit is still available through the details control.
    static func composerBudget(available:CGFloat,lineHeight:CGFloat,textInsets:CGFloat,targetHeight:CGFloat,desiredContextHeight:CGFloat)->ComposerBudget {
        let available=max(0,available),minimumText=max(0,lineHeight)+max(0,textInsets)
        let rowExcess=max(0,44-minimumText)
        let normalChrome:CGFloat=32+rowExcess // input row + outer vertical padding
        let target=max(0,targetHeight),targetSpacing:CGFloat=target>0 ? 8:0
        let compact=available<minimumText+normalChrome+target+targetSpacing
        let chrome=(compact ? 0:32)+rowExcess
        let shownTarget=target>0 && !compact
        let reservedTarget=shownTarget ? target+targetSpacing:0
        let remainder=max(0,available-minimumText-chrome-reservedTarget)
        let minimumReading=min(remainder,max(44,lineHeight))
        // Context never takes more than half the remaining area, and a partial
        // 10pt strip does not pretend to be a readable or tappable control.
        let contextLimit=min(remainder/2,max(0,remainder-minimumReading))
        let context=min(max(0,desiredContextHeight),max(0,contextLimit-8))
        let shownContext=context>=44 ? context:0
        let reservedContext=shownContext>0 ? shownContext+8:0
        let reading=min(max(44,lineHeight*2),max(0,remainder-reservedContext))
        let text=max(minimumText,available-chrome-reservedTarget-reservedContext-reading)
        return .init(maximumTextHeight:text,contextHeight:shownContext,transcriptHeight:reading,showsTarget:shownTarget,compactPadding:compact)
    }
}

struct CatpawVisibleViewport:Equatable {
    let bounds:CGRect
    let safeBounds:CGRect
    let keyboardTop:CGFloat?
    var visibleBounds:CGRect {CatpawTextViewport.visibleBounds(bounds:bounds,safeBounds:safeBounds,keyboardTop:keyboardTop)}
}

/// Observe rendered UIKit boundaries. A SwiftUI GeometryProxy may already be
/// inset by the keyboard, so subtracting its safeAreaInsets again is ambiguous.
@MainActor struct CatpawViewportObserver:UIViewRepresentable {
    var changed:(CatpawVisibleViewport)->Void
    func makeUIView(context:Context)->CatpawViewportTrackingView {
        let view=CatpawViewportTrackingView();view.changed=changed;return view
    }
    func updateUIView(_ view:CatpawViewportTrackingView,context:Context) {view.changed=changed;view.report()}
}
@MainActor final class CatpawViewportTrackingView:UIView {
    var changed:((CatpawVisibleViewport)->Void)?
    private var last:CatpawVisibleViewport?
    private var keyboardFrame:CGRect?
    private var observers:[NSObjectProtocol]=[]
    override init(frame:CGRect) {super.init(frame:frame);isUserInteractionEnabled=false;backgroundColor = .clear}
    required init?(coder:NSCoder) {fatalError("init(coder:) is unavailable")}
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil,observers.isEmpty {
            for name in [UIResponder.keyboardWillChangeFrameNotification,UIResponder.keyboardDidChangeFrameNotification,UIResponder.keyboardWillHideNotification,UIResponder.keyboardDidHideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){[weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else {return}
                        self.keyboardFrame=[UIResponder.keyboardWillHideNotification,UIResponder.keyboardDidHideNotification].contains(note.name) ? nil:(note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                        self.report()
                        DispatchQueue.main.async{[weak self] in self?.report()}
                    }
                })
            }
        } else if window == nil {
            observers.forEach{NotificationCenter.default.removeObserver($0)};observers=[];last=nil;keyboardFrame=nil
        }
        report()
    }
    override func layoutSubviews() {super.layoutSubviews();report()}
    override func safeAreaInsetsDidChange() {super.safeAreaInsetsDidChange();report()}
    func report() {
        guard let window,bounds.width>0,bounds.height>0 else {return}
        let rect=convert(bounds,to:window)
        var safe=convert(safeAreaLayoutGuide.layoutFrame,to:window).intersection(window.safeAreaLayoutGuide.layoutFrame)
        var responder:UIResponder?=self
        while let current=responder {
            if let controller=current as? UIViewController,let nav=controller.navigationController,!nav.navigationBar.isHidden {
                let bottom=nav.navigationBar.convert(nav.navigationBar.bounds,to:window).maxY
                let clipped=max(safe.minY,bottom);safe=CGRect(x:safe.minX,y:clipped,width:safe.width,height:max(0,safe.maxY-clipped));break
            }
            responder=current.next
        }
        let guide=window.keyboardLayoutGuide.layoutFrame
        var keyboardTop:CGFloat?=guide.width>0 && guide.height>0 ? guide.minY:nil
        if let keyboardFrame {
            let frame=window.convert(keyboardFrame,from:window.screen.coordinateSpace)
            let docked=frame.width>=window.bounds.width-1 && frame.maxY>=window.bounds.maxY-1 && frame.minY<window.bounds.maxY
            // A notification's final frame is useful during a guide's first
            // layout. Intersection avoids subtracting either boundary twice.
            if docked {keyboardTop=min(keyboardTop ?? frame.minY,frame.minY)}
        }
        let value=CatpawVisibleViewport(bounds:rect,safeBounds:safe,keyboardTop:keyboardTop)
        guard value != last else {return};last=value
        DispatchQueue.main.async{[weak self] in guard let self,self.window != nil,self.last==value else {return};self.changed?(value)}
    }
    deinit {observers.forEach{NotificationCenter.default.removeObserver($0)}}
}

/// Both chat and document editing preserve UIKit's selection/composition and
/// bring the caret into the text viewport when keyboard or font layout changes.
@MainActor class CatpawEditingTextView:UITextView {
    weak var outerInteraction:CatpawEditorInteraction?
    private struct LayoutKey:Equatable {
        let revision:UInt64
        let viewport:CGSize
        let container:CGSize
        let font:UIFont?
        let insets:UIEdgeInsets
        let fragmentPadding:CGFloat
    }
    private var lastViewport:CGSize = .zero
    private var revealingCaret=false
    private var revealQueued=false
    private var textRevision:UInt64=0
    private var preparedLayout:LayoutKey?
    override var text:String! {didSet{textRevision &+= 1}}
    override var attributedText:NSAttributedString! {didSet{textRevision &+= 1}}
    #if DEBUG
    private(set) var requestedDocumentLayouts=0
    private(set) var completedViewportLayouts=0
    #endif
    func noteTextChanged() {textRevision &+= 1;keepSelectionVisible();outerInteraction?.requestReveal()}
    override func unmarkText(){super.unmarkText();outerInteraction?.flushPendingReveal()}
    override func didMoveToWindow() {
        super.didMoveToWindow();preparedLayout=nil
        if window != nil {setNeedsLayout();keepSelectionVisible()}
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastViewport else {return}
        lastViewport=bounds.size
        keepSelectionVisible()
        outerInteraction?.requestReveal()
    }
    func keepSelectionVisible() {
        guard canRevealCaret,!revealingCaret else {return}
        revealCaret()
        // TextKit updates UITextView's contentSize after realizing the glyphs.
        // Recheck after that layout pass, coalescing requests without resetting
        // selection, composition or a user's in-progress document scroll.
        guard !revealQueued else {return};revealQueued=true
        DispatchQueue.main.async { [weak self] in
            guard let self else {return};self.revealQueued=false
            guard self.canRevealCaret else {return}
            self.revealCaret()
        }
    }
    private var canRevealCaret:Bool {
        window != nil && isFirstResponder && markedTextRange == nil && bounds.height>0 && bounds.width>0 && !isTracking && !isDragging && !isDecelerating
    }
    override func setContentOffset(_ contentOffset:CGPoint,animated:Bool) {
        // UIKit may start an animated selection scroll after the edit delegate
        // returns. For active editing, that animation must not overwrite the
        // already restored caret with intermediate offsets on subsequent frames.
        super.setContentOffset(contentOffset,animated:animated && !canRevealCaret)
    }
    override func scrollRectToVisible(_ rect:CGRect,animated:Bool) {
        super.scrollRectToVisible(rect,animated:animated && !canRevealCaret)
    }
    private func revealCaret() {
        guard canRevealCaret,!revealingCaret,let end=selectedTextRange?.end else {return}
        revealingCaret=true;defer{revealingCaret=false}
        layoutIfNeeded()
        let key=LayoutKey(revision:textRevision,viewport:bounds.size,container:textContainer.size,font:font,insets:textContainerInset,fragmentPadding:textContainer.lineFragmentPadding)
        let documentChanged=preparedLayout != key
        if documentChanged {
            if let manager=textLayoutManager,let content=manager.textContentManager {
                manager.ensureLayout(for:content.documentRange)
            } else {
                // Only an existing TextKit 1 editor uses this path. Never access
                // layoutManager on a TextKit 2 editor and trigger a fallback.
                layoutManager.ensureLayout(for:textContainer)
            }
            preparedLayout=key
            #if DEBUG
            requestedDocumentLayouts += 1
            #endif
        }
        var caret=caretRect(for:end)
        guard !caret.isNull,!caret.isInfinite,caret.height>0,caret.minY.isFinite,caret.maxY.isFinite else {return}
        let notVisible=caret.minY<bounds.minY || caret.maxY>bounds.maxY
        let uncommittedSize=CatpawTextViewport.hasUncommittedCaretExtent(contentHeight:contentSize.height,caretBottom:caret.maxY,screenScale:window?.screen.scale ?? contentScaleFactor)
        if documentChanged || notVisible || uncommittedSize {
            // Glyph layout and UITextView's content-size/rendering transaction
            // are separate. A clean UIView does nothing on layoutIfNeeded alone.
            // Keep UIKit as the viewport delegate and explicitly commit that pass.
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            setNeedsLayout();layoutIfNeeded()
            #if DEBUG
            completedViewportLayouts += 1
            #endif
            caret=caretRect(for:end)
        }
        // A zero-length selectedRange is not a visible rect; scrolling that
        // range can leave its insertion point far outside the viewport.
        let margin=min(max(2,textContainerInset.bottom),max(2,bounds.height/4))
        // Cancel an existing automatic scroll before applying the final rect.
        // No user tracking/deceleration or marked-text session reaches this path.
        super.setContentOffset(contentOffset,animated:false)
        super.scrollRectToVisible(caret.insetBy(dx:0,dy:-margin),animated:false)
        #if DEBUG
        outerInteraction?.recordCommittedVisibility()
        #endif
    }
}

/// The outer page and inner editor share one interaction gate. Layout recovery
/// must not take over a user's outer scroll or an active marked-text composition.
@MainActor final class CatpawEditorInteraction:NSObject,ObservableObject {
    weak var outerScroll:UIScrollView?
    private weak var activeEditor:CatpawEditingTextView?
    private var viewport:CatpawVisibleViewport?
    private(set) var hasPendingReveal=false
    private var revealQueued=false
    private var recovering=false
    private var scrollFrames:CADisplayLink?
    #if DEBUG
    private var visibilityQueued=false
    #endif
    var permitsAutomaticReveal:Bool {
        guard let editor=activeEditor,editor.isFirstResponder,editor.markedTextRange == nil else {return false}
        return !editor.isTracking && !editor.isDragging && !editor.isDecelerating && !(outerScroll.map{$0.isTracking || $0.isDragging || $0.isDecelerating} ?? false)
    }
    func began(_ editor:CatpawEditingTextView){
        if activeEditor !== editor {activeEditor?.outerInteraction=nil}
        activeEditor=editor;editor.outerInteraction=self;requestReveal()
    }
    func ended(_ editor:CatpawEditingTextView){
        guard activeEditor === editor else {return}
        editor.outerInteraction=nil;activeEditor=nil;hasPendingReveal=false;stopScrollObservation()
    }
    func detached(){outerScroll=nil;viewport=nil;hasPendingReveal=false;stopScrollObservation()}
    func viewportChanged(_ value:CatpawVisibleViewport){viewport=value;requestReveal()}
    /// A focus, edit or rendered size change requests one recovery after UIKit
    /// has committed its layout. Unrelated model projections do not request it.
    func requestReveal(){
        guard activeEditor?.isFirstResponder == true else {return}
        hasPendingReveal=true
        guard !revealQueued else {return};revealQueued=true
        DispatchQueue.main.async{[weak self] in guard let self else {return};self.revealQueued=false;self.flushPendingReveal()}
    }
    func flushPendingReveal(){
        guard hasPendingReveal,!recovering,let editor=activeEditor,editor.isFirstResponder,let window=editor.window else {return}
        guard let scroll=outerScroll,scroll.window === window else {stopScrollObservation();return}
        guard permitsAutomaticReveal else {
            // Marked text resumes through the edit/selection delegate. A real
            // drag/deceleration resumes on its first idle display frame, without
            // replacing SwiftUI's scroll delegate or imposing a timed delay.
            if editor.markedTextRange == nil {observeScrollUntilIdle()}
            else {stopScrollObservation()}
            return
        }
        recovering=true;defer{recovering=false}
        stopScrollObservation()
        scroll.layoutIfNeeded();editor.keepSelectionVisible();editor.layoutIfNeeded()
        let scrollFrame=scroll.convert(scroll.bounds,to:window)
        var visible=scrollFrame.intersection(viewport?.visibleBounds ?? window.safeAreaLayoutGuide.layoutFrame)
        guard !visible.isNull,visible.width>0,visible.height>0,let end=editor.selectedTextRange?.end else {return}
        // Content insets and any keyboard/footer boundary are intersected in
        // window coordinates once. The caret then uses that same transaction.
        let contentViewport=scroll.bounds.inset(by:scroll.adjustedContentInset)
        visible=visible.intersection(scroll.convert(contentViewport,to:window))
        guard !visible.isNull,visible.height>0 else {return}
        let caret=editor.caretRect(for:end)
        guard !caret.isNull,!caret.isInfinite,caret.height>0 else {return}
        let caretInWindow=editor.convert(caret,to:window)
        let editorInWindow=editor.convert(editor.bounds,to:window)
        // If the whole field fits, keep it editable rather than leaving only the
        // caret's thin line exposed. An oversized field follows its actual caret.
        let target=editorInWindow.height<=visible.height ? editorInWindow:caretInWindow
        var delta:CGFloat=0
        if target.minY<visible.minY {delta=target.minY-visible.minY}
        else if target.maxY>visible.maxY {delta=target.maxY-visible.maxY}
        let minimum = -scroll.adjustedContentInset.top
        let maximum=max(minimum,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
        let offset=min(maximum,max(minimum,scroll.contentOffset.y+delta))
        if abs(offset-scroll.contentOffset.y)>1/max(1,window.screen.scale) {
            scroll.setContentOffset(CGPoint(x:scroll.contentOffset.x,y:offset),animated:false)
        }
        let actualCaret=editor.convert(editor.caretRect(for:end),to:window)
        let actualEditor=editor.convert(editor.bounds,to:window)
        let pixel=1/max(1,window.screen.scale)
        let caretVisible=actualCaret.minY>=visible.minY-pixel && actualCaret.maxY<=visible.maxY+pixel
        let fieldVisible=actualEditor.height>visible.height || (actualEditor.minY>=visible.minY-pixel && actualEditor.maxY<=visible.maxY+pixel)
        // A not-yet-committed content extent keeps the request until an actual
        // scroll/layout event. Physically impossible height is never font shrink.
        hasPendingReveal = !(caretVisible && fieldVisible)
        #if DEBUG
        recordCommittedVisibility()
        #endif
    }
    #if DEBUG
    func recordCommittedVisibility(){
        guard !visibilityQueued else {return};visibilityQueued=true
        DispatchQueue.main.async{[weak self] in
            guard let self else {return};self.visibilityQueued=false
            guard let editor=self.activeEditor,editor.isFirstResponder,let window=editor.window,let scroll=self.outerScroll,scroll.window === window,let end=editor.selectedTextRange?.end else {return}
            let outer=scroll.convert(scroll.bounds.inset(by:scroll.adjustedContentInset),to:window)
            let inner=editor.convert(editor.bounds,to:window)
            let visible=outer.intersection(self.viewport?.visibleBounds ?? window.safeAreaLayoutGuide.layoutFrame).intersection(inner)
            let caret=editor.convert(editor.caretRect(for:end),to:window)
            P0ExperienceProbe.shared.recordEditorVisibility(identifier:editor.accessibilityIdentifier ?? "",caret:caret,visibleBounds:visible.isNull ? .zero:visible,selection:editor.selectedRange,fontLineHeight:editor.font?.lineHeight ?? 0)
        }
    }
    #endif
    private func observeScrollUntilIdle(){
        guard scrollFrames == nil else {return}
        let frames=CADisplayLink(target:self,selector:#selector(scrollFrame(_:)))
        scrollFrames=frames;frames.add(to:.main,forMode:.common)
    }
    private func stopScrollObservation(){scrollFrames?.invalidate();scrollFrames=nil}
    @objc private func scrollFrame(_ frame:CADisplayLink){
        guard hasPendingReveal,let editor=activeEditor,editor.isFirstResponder,editor.window != nil else {hasPendingReveal=false;stopScrollObservation();return}
        if editor.markedTextRange != nil {stopScrollObservation();return}
        if permitsAutomaticReveal {flushPendingReveal()}
    }
}
@MainActor struct CatpawEditorScrollObserver:UIViewRepresentable {
    let interaction:CatpawEditorInteraction
    func makeUIView(context:Context)->CatpawEditorScrollTrackingView {let view=CatpawEditorScrollTrackingView();view.interaction=interaction;return view}
    func updateUIView(_ view:CatpawEditorScrollTrackingView,context:Context){view.interaction=interaction;view.attach()}
}
@MainActor final class CatpawEditorScrollTrackingView:UIView {
    weak var interaction:CatpawEditorInteraction?
    private weak var observedScroll:UIScrollView?
    private var observations:[NSKeyValueObservation]=[]
    override init(frame:CGRect){super.init(frame:frame);isUserInteractionEnabled=false}
    required init?(coder:NSCoder){fatalError("init(coder:) is unavailable")}
    override func didMoveToSuperview(){super.didMoveToSuperview();attach()}
    override func didMoveToWindow(){super.didMoveToWindow();attach()}
    func attach(){
        guard window != nil else {observations=[];observedScroll=nil;interaction?.detached();return}
        var ancestor=superview
        while let view=ancestor {
            if let scroll=view as? UIScrollView {
                interaction?.outerScroll=scroll
                guard observedScroll !== scroll else {return}
                observations=[];observedScroll=scroll
                observations.append(scroll.observe(\.bounds,options:[.old,.new]){[weak self] _,change in
                    MainActor.assumeIsolated {
                        if change.oldValue?.size != change.newValue?.size {self?.interaction?.requestReveal()}
                        else {self?.interaction?.flushPendingReveal()}
                    }
                })
                observations.append(scroll.observe(\.contentSize,options:[.new]){[weak self] _,_ in MainActor.assumeIsolated{self?.interaction?.flushPendingReveal()}})
                interaction?.requestReveal();return
            }
            ancestor=view.superview
        }
    }
}

@MainActor struct CatpawTextEditor:UIViewRepresentable {
    @Binding var text:String
    @Binding var focused:Bool
    var accessibilityLabel:String
    var accessibilityIdentifier:String
    var enabled=true
    var interaction:CatpawEditorInteraction?=nil
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->CatpawEditingTextView {
        let view=CatpawEditingTextView();view.delegate=context.coordinator
        view.backgroundColor = .clear;view.textColor=UIColor(CatpawColors.ink)
        view.textContainerInset=UIEdgeInsets(top:8,left:8,bottom:8,right:8)
        view.textContainer.lineFragmentPadding=0
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    func updateUIView(_ view:CatpawEditingTextView,context:Context) {
        context.coordinator.parent=self
        view.accessibilityLabel=accessibilityLabel;view.accessibilityIdentifier=accessibilityIdentifier
        view.isEditable=enabled && context.environment.isEnabled
        // The environment's category is already applied. UIKit's independent
        // automatic adjustment must not later replace the explicitly chosen font.
        view.adjustsFontForContentSizeCategory=false
        let font=CatpawTypography.font(size:context.environment.dynamicTypeSize)
        let fontChanged=view.font?.isEqual(font) != true
        if fontChanged {view.font=font}
        var replaced=false
        if view.markedTextRange == nil,view.text != text {
            let selection=view.selectedRange;context.coordinator.replacing=true
            view.text=text;view.selectedRange=NSRange(location:min(selection.location,text.utf16.count),length:0)
            context.coordinator.replacing=false
            replaced=true
        }
        let acquiringFocus=focused && view.isEditable && !view.isFirstResponder
        if acquiringFocus {view.becomeFirstResponder()}
        else if !focused,view.isFirstResponder {view.resignFirstResponder()}
        // An unrelated projection/status update must not undo a user's scroll
        // within a long document. Only editing/layout changes reveal the caret.
        if fontChanged || replaced || acquiringFocus {view.keepSelectionVisible();interaction?.requestReveal()}
    }
    final class Coordinator:NSObject,UITextViewDelegate {
        var parent:CatpawTextEditor
        var replacing=false
        init(_ parent:CatpawTextEditor){self.parent=parent}
        func textViewDidBeginEditing(_ textView:UITextView){if let editor=textView as? CatpawEditingTextView {parent.interaction?.began(editor)};if !parent.focused {parent.focused=true}}
        func textViewDidEndEditing(_ textView:UITextView){if let editor=textView as? CatpawEditingTextView {parent.interaction?.ended(editor)};if parent.focused {parent.focused=false}}
        func textViewDidChange(_ textView:UITextView) {
            guard !replacing else {return};parent.text=textView.text
            (textView as? CatpawEditingTextView)?.noteTextChanged()
        }
        func textViewDidChangeSelection(_ textView:UITextView){(textView as? CatpawEditingTextView)?.keepSelectionVisible();parent.interaction?.flushPendingReveal()}
    }
}
