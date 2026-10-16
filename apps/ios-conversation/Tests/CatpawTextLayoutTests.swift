import XCTest
import SwiftUI
import UIKit
@testable import CatpawM

/// Rendered-font and UIKit editor regressions. These do not close physical-device UX gates.
final class CatpawTextLayoutTests:XCTestCase {
    /// Regression: 「猫吃什么」 bubble rendered ~2 empty lines tall (trailing newlines from Return/dictation).
    @MainActor func testShortUserBubbleHugsOneLine() {
        XCTAssertEqual(ConversationUserBubbleText.display("猫吃什么\n\n"),"猫吃什么")
        XCTAssertEqual(ConversationUserBubbleText.display("\n 猫吃什么 \n"),"猫吃什么")
        XCTAssertEqual(ConversationUserBubbleText.display("a\n\nb"),"a\n\nb")
        let line=UIFont.preferredFont(forTextStyle:.body,compatibleWith:UITraitCollection(preferredContentSizeCategory:.large)).lineHeight
        for raw in ["猫吃什么","猫吃什么\n\n","猫吃什么\n \n"] {
            let host=UIHostingController(rootView:ConversationUserBubbleText(content:raw).environment(\.dynamicTypeSize,.large))
            let h=host.sizeThatFits(in:CGSize(width:300,height:CGFloat.greatestFiniteMagnitude)).height
            XCTAssertEqual(h,line+18,accuracy:3,"bubble for \(raw.debugDescription) must be one line + 18pt, got \(h)")
        }
    }
    @MainActor func testEverySwiftUITextCategoryMatchesUIKitWithoutImplicitRescaling() {
        let sizes:[DynamicTypeSize]=[.xSmall,.small,.medium,.large,.xLarge,.xxLarge,.xxxLarge,.accessibility1,.accessibility2,.accessibility3,.accessibility4,.accessibility5]
        let categories:[UIContentSizeCategory]=[.extraSmall,.small,.medium,.large,.extraLarge,.extraExtraLarge,.extraExtraExtraLarge,.accessibilityMedium,.accessibilityLarge,.accessibilityExtraLarge,.accessibilityExtraExtraLarge,.accessibilityExtraExtraExtraLarge]
        let roles:[CatpawTypography.Role]=[.appTitle,.title,.heading,.body,.secondary,.caption,.table]
        for (size,category) in zip(sizes,categories) {
            XCTAssertEqual(CatpawTypography.category(size),category)
            for role in roles {
                let expected=UIFont.preferredFont(forTextStyle:role.textStyle,compatibleWith:UITraitCollection(preferredContentSizeCategory:category))
                let actual=CatpawTypography.font(role,size:size)
                XCTAssertEqual(actual.pointSize,expected.pointSize)
                XCTAssertEqual(actual.lineHeight,expected.lineHeight)
            }
        }
        XCTAssertGreaterThan(CatpawTypography.font(size:.accessibility5).pointSize,CatpawTypography.font(size:.large).pointSize)
    }
    @MainActor func testLargeChineseAndEnglishLabelsLeaveAnEditableLineAcrossThreeWidths() {
        let font=CatpawTypography.font(size:.accessibility5),labelFont=CatpawTypography.font(.heading,size:.accessibility5)
        for width:CGFloat in [375,390,430] {
            for title in ["正文","Report content with a longer field label"] {
                let label=UILabel();label.numberOfLines=0;label.text=title;label.font=labelFont
                let labelHeight=label.sizeThatFits(CGSize(width:width-40,height:.greatestFiniteMagnitude)).height
                for viewport:CGFloat in [240,360,500] {
                    let height=CatpawTextViewport.editorHeight(preferred:font.lineHeight*6+16,viewport:viewport,labelHeight:labelHeight,spacing:8,lineHeight:font.lineHeight,textInsets:16)
                    XCTAssertGreaterThanOrEqual(height,font.lineHeight+16,"No font shrinking to fit a label")
                    if viewport-labelHeight-8>=font.lineHeight+16 {
                        XCTAssertLessThanOrEqual(height+labelHeight+8,viewport+0.001,"Actual wrapped label is part of the height budget")
                    }
                }
            }
        }
    }
    func testActualFooterBoundaryIsAppliedBeforeTextHeightBudget() {
        let bounds=CGRect(x:0,y:96,width:375,height:500)
        XCTAssertEqual(CatpawTextViewport.height(bounds:bounds,safeAreaTop:0,safeAreaBottom:34,bottomBoundary:470),374)
        XCTAssertEqual(CatpawTextViewport.height(bounds:bounds,safeAreaTop:20,safeAreaBottom:34,bottomBoundary:nil),446)
        XCTAssertEqual(CatpawTextViewport.height(bounds:bounds,safeAreaTop:20,safeAreaBottom:34,bottomBoundary:100),0)
        XCTAssertEqual(CatpawTextViewport.composerHeight(desired:400,lineHeight:60,textInsets:16,maximumLines:5,availableHeight:136),136)
        XCTAssertEqual(CatpawTextViewport.composerHeight(desired:400,lineHeight:60,textInsets:16,maximumLines:5,availableHeight:30),76,"An impossible viewport requires host chrome to yield, rather than reducing the text")
        XCTAssertEqual(CatpawTextViewport.composerHeight(desired:400,lineHeight:60,textInsets:16,maximumLines:5,availableHeight:0),76,"Explicit zero space must not silently restore the five-line default")
        let safe=CGRect(x:0,y:116,width:402,height:724)
        let full=CatpawTextViewport.visibleBounds(bounds:CGRect(x:0,y:0,width:402,height:874),safeBounds:safe,keyboardTop:545)
        let alreadyInset=CatpawTextViewport.visibleBounds(bounds:CGRect(x:0,y:116,width:402,height:429),safeBounds:safe,keyboardTop:545)
        XCTAssertEqual(full,alreadyInset,"A viewport already shortened by the keyboard is intersected, never deducted twice")
        XCTAssertEqual(full.height,429)
    }
    func testComposerBudgetBoundsLongContextAndYieldsChromeBeforeAnEditableLine() {
        for available:CGFloat in [100,120,208,340,600] {
            let budget=CatpawTextViewport.composerBudget(available:available,lineHeight:60,textInsets:16,targetHeight:52,desiredContextHeight:2_000)
            let chrome:CGFloat=budget.compactPadding ? 0:32
            let target:CGFloat=budget.showsTarget ? 60:0
            let context=budget.contextHeight>0 ? budget.contextHeight+8:0
            XCTAssertGreaterThanOrEqual(budget.maximumTextHeight,76)
            XCTAssertLessThanOrEqual(budget.maximumTextHeight+chrome+target+context+budget.transcriptHeight,available+0.001)
            XCTAssertTrue(budget.contextHeight==0 || budget.contextHeight>=44)
            if available<=120 {
                XCTAssertFalse(budget.showsTarget,"A version/details control in the input row replaces the tall target bar")
                XCTAssertEqual(budget.contextHeight,0)
                XCTAssertTrue(budget.compactPadding)
            }
        }
        let unavailable=CatpawTextViewport.composerBudget(available:0,lineHeight:60,textInsets:16,targetHeight:52,desiredContextHeight:2_000)
        XCTAssertEqual(unavailable.maximumTextHeight,76,"The host offers keyboard dismissal/details rather than shrinking the font")
        XCTAssertEqual(unavailable.contextHeight,0)
    }
    func testCaretCommitExtentUsesPhysicalPixelsAndExcludesDecorativePadding() {
        // Recorded r5 caret=14958.3333, content=14966: adding a desired 8pt
        // margin falsely demanded another viewport commit after pixel rounding.
        XCTAssertFalse(CatpawTextViewport.hasUncommittedCaretExtent(contentHeight:14966,caretBottom:14958.333333333334,screenScale:3))
        for scale:CGFloat in [2,3] {
            let pixel=1/scale
            XCTAssertFalse(CatpawTextViewport.hasUncommittedCaretExtent(contentHeight:300,caretBottom:300+pixel*0.9,screenScale:scale))
            XCTAssertTrue(CatpawTextViewport.hasUncommittedCaretExtent(contentHeight:300,caretBottom:300+pixel*2,screenScale:scale),"Real missing scroll extent still requires a commit")
        }
    }
    @MainActor func testActualUIKitCaretAndExactRawSurviveKeyboardSizedViewportChanges() async throws {
        guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first else {XCTFail("Actual host must supply a window scene");return}
        let previous=scene.windows.first(where:{$0.isKeyWindow})
        let window=UIWindow(windowScene:scene),controller=UIViewController()
        window.rootViewController=controller;window.frame=CGRect(x:0,y:0,width:375,height:700)
        let editor=CatpawEditingTextView(frame:CGRect(x:20,y:90,width:335,height:300))
        editor.font=CatpawTypography.font(size:.accessibility5)
        editor.adjustsFontForContentSizeCategory=false
        editor.textContainerInset=UIEdgeInsets(top:8,left:8,bottom:8,right:8)
        let raw=String(repeating:"中文正文与long English words 🐾\n",count:80)+"VISIBLE-END"
        editor.text=raw;controller.view.addSubview(editor);window.makeKeyAndVisible()
        defer {editor.resignFirstResponder();window.isHidden=true;previous?.makeKey()}
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange=NSRange(location:raw.utf16.count,length:0)
        let original=editor.selectedRange
        for width:CGFloat in [375,390,430] {
            for size:DynamicTypeSize in [.large,.accessibility5] {
                editor.font=CatpawTypography.font(size:size)
                for height:CGFloat in [300,136,220] {
                    editor.frame.size=CGSize(width:width-40,height:height);editor.setNeedsLayout();editor.layoutIfNeeded();editor.keepSelectionVisible()
                    _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
                    _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
                    guard let end=editor.selectedTextRange?.end else {XCTFail("Caret remains available");return}
                    let caret=editor.caretRect(for:end)
                    let metrics=XCTAttachment(string:"width=\(width);type=\(size);height=\(height);observation=two_actual_display_frames_then_UIKit_layout;caret=\(caret);bounds=\(editor.bounds);content_size=\(editor.contentSize);offset=\(editor.contentOffset);selection=\(editor.selectedRange);textkit_usage=\(String(describing:editor.textLayoutManager?.usageBoundsForTextContainer));document_layout_requests=\(editor.requestedDocumentLayouts);viewport_commits=\(editor.completedViewportLayouts)")
                    metrics.name="Synthetic-UIKit-caret-rendered-viewport";metrics.lifetime = .keepAlways;add(metrics)
                    XCTAssertEqual(editor.text.utf8.map{$0},raw.utf8.map{$0})
                    XCTAssertEqual(editor.selectedRange,original,"Resize keeps the user's selection")
                    XCTAssertGreaterThanOrEqual(caret.minY,editor.bounds.minY-1,"Last input is above the text viewport's top")
                    XCTAssertLessThanOrEqual(caret.maxY,editor.bounds.maxY+1,"Caret is inside the visible text viewport")
                    XCTAssertGreaterThan(editor.contentOffset.y,0,"Long documents scroll within the text field")
                }
            }
        }
    }
    @MainActor func testNestedUIKitEditorRecoversAfterCommittedOuterViewportAndMarkedComposition() async throws {
        guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first else {XCTFail("Actual host must supply a window scene");return}
        let previous=scene.windows.first(where:{$0.isKeyWindow})
        let window=UIWindow(windowScene:scene),controller=UIViewController()
        window.rootViewController=controller;window.frame=CGRect(x:0,y:0,width:390,height:700)
        let outer=UIScrollView(frame:CGRect(x:0,y:90,width:390,height:400))
        outer.contentSize=CGSize(width:390,height:1100)
        let interaction=CatpawEditorInteraction()
        let tracker=CatpawEditorScrollTrackingView(frame:.zero);tracker.interaction=interaction
        outer.addSubview(tracker)
        let editor=CatpawEditingTextView(frame:CGRect(x:20,y:600,width:350,height:136))
        editor.font=CatpawTypography.font(size:.large);editor.adjustsFontForContentSizeCategory=false
        editor.textContainerInset=UIEdgeInsets(top:8,left:8,bottom:8,right:8)
        let raw=String(repeating:"中文正文 English exact raw 🐾\n",count:80)+"NESTED-EDIT-END"
        editor.text=raw;outer.addSubview(editor);controller.view.addSubview(outer);window.makeKeyAndVisible()
        defer {interaction.ended(editor);editor.resignFirstResponder();window.isHidden=true;previous?.makeKey()}
        XCTAssertTrue(editor.becomeFirstResponder());editor.selectedRange=NSRange(location:raw.utf16.count,length:0)
        interaction.began(editor);tracker.attach()
        func reportActualViewport(){
            outer.layoutIfNeeded()
            let bounds=outer.convert(outer.bounds,to:window)
            interaction.viewportChanged(.init(bounds:bounds,safeBounds:bounds,keyboardTop:nil))
        }
        func assertActualCaretVisible(file:StaticString=#filePath,line:UInt=#line){
            guard let end=editor.selectedTextRange?.end else {XCTFail("Actual caret remains available",file:file,line:line);return}
            let caret=editor.convert(editor.caretRect(for:end),to:window)
            let visible=outer.convert(outer.bounds.inset(by:outer.adjustedContentInset),to:window).intersection(editor.convert(editor.bounds,to:window))
            let pixel=1/window.screen.scale
            XCTAssertGreaterThanOrEqual(caret.minY,visible.minY-pixel,file:file,line:line)
            XCTAssertLessThanOrEqual(caret.maxY,visible.maxY+pixel,file:file,line:line)
            XCTAssertFalse(interaction.hasPendingReveal,file:file,line:line)
        }
        reportActualViewport()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        assertActualCaretVisible();XCTAssertEqual(editor.text,raw)
        let selection=editor.selectedRange
        // The field's 136pt size does not change. Only the enclosing scroll
        // viewport changes, which the former field-height preference missed.
        outer.frame.size.height=160;reportActualViewport()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        assertActualCaretVisible();XCTAssertEqual(editor.text,raw);XCTAssertEqual(editor.selectedRange,selection)
        editor.setMarkedText("拼音组合待完成",selectedRange:NSRange(location:3,length:0))
        XCTAssertNotNil(editor.markedTextRange)
        let composed=editor.text,composedSelection=editor.selectedRange
        outer.setContentOffset(.zero,animated:false);outer.frame.size.height=220;reportActualViewport()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        XCTAssertTrue(interaction.hasPendingReveal)
        XCTAssertEqual(outer.contentOffset.y,0,"Real marked composition prevents automatic outer scrolling")
        XCTAssertEqual(editor.text,composed);XCTAssertEqual(editor.selectedRange,composedSelection)
        editor.unmarkText() // The shared UITextInput lifecycle resumes pending recovery.
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        assertActualCaretVisible();XCTAssertEqual(editor.text,composed);XCTAssertEqual(editor.selectedRange,composedSelection)
        interaction.ended(editor)
        XCTAssertFalse(interaction.hasPendingReveal,"Ending focus clears every deferred recovery")
        // UIScrollView's tracking/dragging flags are not settable test fixtures.
        // The root UI run must verify a real gutter drag/interactive dismissal.
    }
    @MainActor func testFortyKBContinuousEditingKeepsCaretRawAndCompositionWithMeasuredLayoutCost() async throws {
        guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first else {XCTFail("Actual host must supply a window scene");return}
        let previous=scene.windows.first(where:{$0.isKeyWindow})
        let window=UIWindow(windowScene:scene),controller=UIViewController()
        window.rootViewController=controller;window.frame=CGRect(x:0,y:0,width:390,height:700)
        let outer=UIScrollView(frame:CGRect(x:0,y:90,width:390,height:220))
        outer.contentSize=CGSize(width:390,height:600)
        let editor=CatpawEditingTextView(frame:CGRect(x:20,y:0,width:350,height:136))
        editor.font=CatpawTypography.font(size:.accessibility5);editor.adjustsFontForContentSizeCategory=false
        editor.textContainerInset=UIEdgeInsets(top:8,left:8,bottom:8,right:8)
        let delegate=LayoutEditingDelegate();editor.delegate=delegate
        var raw=String(repeating:"中文长文 English words 🐾 with exact raw content.\n",count:800)
        XCTAssertGreaterThanOrEqual(raw.utf8.count,40*1024)
        editor.text=raw;outer.addSubview(editor);controller.view.addSubview(outer);window.makeKeyAndVisible()
        defer {editor.resignFirstResponder();window.isHidden=true;previous?.makeKey()}
        XCTAssertTrue(editor.becomeFirstResponder());editor.selectedRange=NSRange(location:raw.utf16.count,length:0)
        editor.keepSelectionVisible()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        var durations:[Double]=[]
        var settledDurations:[Double]=[],frameSamples:[String]=[]
        let before=editor.requestedDocumentLayouts
        let beforeViewport=editor.completedViewportLayouts
        // Selection callbacks, layout and the deferred caret pass must reuse a
        // document already prepared at the same text revision/font/width.
        for _ in 0..<20 {editor.keepSelectionVisible()}
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        XCTAssertEqual(editor.requestedDocumentLayouts,before)
        XCTAssertEqual(editor.completedViewportLayouts,beforeViewport,"Unchanged, visible input does not repeat viewport commits because of decorative padding rounding")
        for index in 0..<30 {
            let fragment=index.isMultiple(of:3) ? "中文🐾":index.isMultiple(of:2) ? "\n":" edit"
            let start=ProcessInfo.processInfo.systemUptime
            editor.insertText(fragment);raw+=fragment
            editor.keepSelectionVisible()
            durations.append((ProcessInfo.processInfo.systemUptime-start)*1_000)
            var firstOffset:CGPoint?,firstSize:CGSize?
            // Five milliseconds may be shorter than one display frame. Observe
            // two real frame callbacks, committing pending UIKit layout only;
            // never issue a test-only caret recovery to make the frame pass.
            for sample in 0..<2 {
                let timestamp=await LayoutDisplayFrame.next();editor.layoutIfNeeded()
                XCTAssertEqual(editor.text,raw)
                XCTAssertEqual(editor.selectedRange,NSRange(location:raw.utf16.count,length:0))
                guard let end=editor.selectedTextRange?.end else {XCTFail("Caret remains available while editing");return}
                let caret=editor.caretRect(for:end)
                XCTAssertGreaterThanOrEqual(caret.minY,editor.bounds.minY-1,"Edit \(index), observed frame \(sample)")
                XCTAssertLessThanOrEqual(caret.maxY,editor.bounds.maxY+1,"Edit \(index), observed frame \(sample)")
                XCTAssertGreaterThanOrEqual(editor.contentSize.height,caret.maxY-1,"The caret belongs to the actual committed scroll extent")
                if let firstOffset,let firstSize {
                    XCTAssertEqual(editor.contentOffset.y,firstOffset.y,accuracy:1,"Platform scrolling must not move the corrected caret between frames")
                    XCTAssertEqual(editor.contentSize.height,firstSize.height,accuracy:1,"The observed extent has settled")
                }
                firstOffset=editor.contentOffset;firstSize=editor.contentSize
                frameSamples.append("edit=\(index);sample=\(sample);display_timestamp=\(timestamp);caret=\(caret);bounds=\(editor.bounds);content_size=\(editor.contentSize);offset=\(editor.contentOffset)")
            }
            settledDurations.append((ProcessInfo.processInfo.systemUptime-start)*1_000)
        }
        let interaction=CatpawEditorInteraction();interaction.outerScroll=outer;interaction.began(editor)
        XCTAssertTrue(interaction.permitsAutomaticReveal)
        editor.setMarkedText("拼音尚未完成",selectedRange:NSRange(location:3,length:0))
        XCTAssertNotNil(editor.markedTextRange)
        let markedRaw=editor.text,markedSelection=editor.selectedRange
        let markedViewport=editor.completedViewportLayouts
        XCTAssertFalse(interaction.permitsAutomaticReveal,"Outer recovery must not move an active composition")
        for _ in 0..<10 {editor.keepSelectionVisible()}
        _ = await LayoutDisplayFrame.next();editor.layoutIfNeeded()
        XCTAssertEqual(editor.text,markedRaw);XCTAssertEqual(editor.selectedRange,markedSelection);XCTAssertNotNil(editor.markedTextRange)
        XCTAssertEqual(editor.completedViewportLayouts,markedViewport,"Automatic caret recovery defers to the actual marked-text session")
        editor.unmarkText();interaction.ended(editor)
        XCTAssertFalse(interaction.permitsAutomaticReveal,"Ending focus stops automatic outer positioning")
        let sorted=durations.sorted(),p95=sorted[Int(ceil(Double(sorted.count)*0.95))-1],settled=settledDurations.sorted()
        let metrics=XCTAttachment(string:"reality=actual_UIKit_offline_host;utf8_bytes=\(raw.utf8.count);continuous_edits=\(durations.count);max_type=accessibility5;viewport=\(editor.bounds.size);synchronous_edit_ms=\(durations);median_ms=\(sorted[sorted.count/2]);p95_ms=\(p95);two_display_frame_settled_ms=\(settledDurations);settled_median_ms=\(settled[settled.count/2]);settled_p95_ms=\(settled[Int(ceil(Double(settled.count)*0.95))-1]);document_layout_requests=\(editor.requestedDocumentLayouts-before);viewport_commits=\(editor.completedViewportLayouts);assertion_coverage=exact_raw_selection_caret_scroll_extent_two_frame_stability_and_marked_composition;result_authority=XCTest_method_result\n"+frameSamples.joined(separator:"\n"))
        metrics.name="Actual-UIKit-40KB-continuous-edit-measured-cost";metrics.lifetime = .keepAlways;add(metrics)
    }
}

/// CADisplayLink owns this observer until its one actual frame callback fires.
@MainActor private final class LayoutDisplayFrame:NSObject {
    private var continuation:CheckedContinuation<CFTimeInterval,Never>?
    private var link:CADisplayLink?
    private init(_ continuation:CheckedContinuation<CFTimeInterval,Never>){self.continuation=continuation}
    static func next() async->CFTimeInterval {
        await withCheckedContinuation {continuation in
            let observation=LayoutDisplayFrame(continuation)
            let link=CADisplayLink(target:observation,selector:#selector(observation.observed(_:)))
            observation.link=link;link.add(to:.main,forMode:.common)
        }
    }
    @objc private func observed(_ display:CADisplayLink) {
        let timestamp=display.timestamp
        link?.invalidate();link=nil
        let pending=continuation;continuation=nil;pending?.resume(returning:timestamp)
    }
}

@MainActor private final class LayoutEditingDelegate:NSObject,UITextViewDelegate {
    func textViewDidChange(_ textView:UITextView){(textView as? CatpawEditingTextView)?.noteTextChanged()}
    func textViewDidChangeSelection(_ textView:UITextView){(textView as? CatpawEditingTextView)?.keepSelectionVisible()}
}
