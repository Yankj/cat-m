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
        view.font=preferredFont(context.environment.dynamicTypeSize);view.adjustsFontForContentSizeCategory=true
        view.textContainerInset=UIEdgeInsets(top:8,left:0,bottom:8,right:0)
        view.textContainer.lineFragmentPadding=0;view.returnKeyType = .default
        view.accessibilityLabel="消息";view.accessibilityIdentifier="chat.input"
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        view.submit=submit;view.compositionChanged={ [weak model] in model?.updateInputComposition($0) }
        #if DEBUG
        ConversationTextView.fixtureEditor=view
        #endif
        return view
    }
    func updateUIView(_ view:ConversationTextView,context:Context) {
        context.coordinator.parent=self;view.submit=submit;view.isEditable=enabled
        view.font=preferredFont(context.environment.dynamicTypeSize)
        guard view.markedTextRange == nil,view.text != model.draft else { return }
        let old=view.selectedRange;context.coordinator.replacing=true;view.text=model.draft
        view.selectedRange=NSRange(location:min(old.location,view.text.utf16.count),length:0)
        context.coordinator.replacing=false
    }
    private func preferredFont(_ size:DynamicTypeSize) -> UIFont {
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
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:ConversationTextView,context:Context) -> CGSize? {
        let width=proposal.width ?? 240,line=uiView.font?.lineHeight ?? 22
        let desired=uiView.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude))
        return CGSize(width:width,height:min(max(line+16,desired.height),line*(context.environment.dynamicTypeSize.isAccessibilitySize ? 3 : 5)+16))
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:NativeConversationComposer
        var replacing=false
        init(_ parent:NativeConversationComposer){self.parent=parent}
        func textViewDidChange(_ textView:UITextView) {
            guard !replacing else { return }
            parent.model.updateInputComposition(textView.markedTextRange != nil)
            parent.model.editDraft(textView.text);textView.invalidateIntrinsicContentSize()
        }
        func textViewDidChangeSelection(_ textView:UITextView) { parent.model.updateInputComposition(textView.markedTextRange != nil) }
    }
}
