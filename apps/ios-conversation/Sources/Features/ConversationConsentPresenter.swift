import SwiftUI
import UIKit

/// Presentation ownership only. Permission and send authority stay in the model
/// and its existing services; releasing a sheet never approves or sends work.
struct ConversationConsentPresentation:Identifiable,Equatable {
    enum Content:Equatable {
        case model(ConversationModelConsent)
        case image(ConversationImageConsent,preview:Data?,caption:String)
        static func ==(lhs:Self,rhs:Self)->Bool {
            switch (lhs,rhs) {
            case (.model(let a),.model(let b)):
                return a.conversationID==b.conversationID && a.routeHash==b.routeHash && a.expectedRevision==b.expectedRevision && a.title==b.title && a.body==b.body
            case (.image(let a,let ap,let ac),.image(let b,let bp,let bc)):return a==b && ap==bp && ac.utf8.elementsEqual(bc.utf8)
            default:return false
            }
        }
    }
    let id:UUID
    let modelIdentity:ObjectIdentifier
    let scope:DataScope
    let content:Content
}

struct ConversationConsentPresentationCoordinator {
    private(set) var active:ConversationConsentPresentation?
    private(set) var closing:UUID?
    private(set) var appeared:UUID?
    private(set) var desired:ConversationConsentPresentation?
    mutating func reconcile(_ next:ConversationConsentPresentation?) {
        desired=next
        guard closing==nil else {return}
        if let active {
            guard active != next else {return}
            if appeared==active.id {closing=active.id;self.active=nil}
            else {self.active=next}
        } else {active=next}
    }
    mutating func didAppear(_ owner:UUID) {
        guard active?.id==owner,closing==nil else {return};appeared=owner
    }
    /// The binding captures the owner of the rendered sheet. A late nil write
    /// from an older sheet cannot cancel the review that replaced it.
    mutating func userDismiss(_ owner:UUID)->ConversationConsentPresentation? {
        guard closing==nil,let active,active.id==owner else {return nil}
        closing=owner;self.active=nil;desired=nil;return active
    }
    mutating func didDismiss(_ owner:UUID) {
        guard closing==owner else {return}
        closing=nil;appeared=nil;active=desired
    }
}

@MainActor struct ConversationConsentPresenter:ViewModifier {
    @ObservedObject var model:ConversationFirstModel
    @State private var presentation=ConversationConsentPresentationCoordinator()
    private var desired:ConversationConsentPresentation? {
        guard model.loaded,model.networkAdmissionAllowed else {return nil}
        if let consent=model.pendingModelConsent,let token=model.modelConsentReviewToken,
           model.matchesModelConsent(consent,reviewToken:token) {
            return .init(id:token,modelIdentity:ObjectIdentifier(model),scope:model.scope,content:.model(consent))
        }
        if let consent=model.pendingImageConsent,let token=model.imageConsentReviewToken,
           model.matchesImageConsent(consent,reviewToken:token) {
            return .init(id:token,modelIdentity:ObjectIdentifier(model),scope:model.scope,
                         content:.image(consent,preview:model.imageDraft.attachment?.thumbnailData,caption:model.draft))
        }
        return nil
    }
    func body(content:Content)->some View {
        let owner=presentation.active?.id ?? presentation.closing
        content.catpawSheet(item:Binding(get:{presentation.active},set:{value in
            guard value==nil,let owner,let dismissed=presentation.userDismiss(owner) else {return}
            cancel(dismissed)
        }),onDismiss:{
            // Re-read current context after the real dismissal, never promote a
            // cached review from before backgrounding, a new image or account.
            presentation.reconcile(desired)
            if let owner {presentation.didDismiss(owner)}
        }) { request in
            Group {switch request.content {
            case .model(let consent):
                ConversationModelConsentView(consent:consent,canAllow:model.canReviewModelConsent && model.matchesModelConsent(consent,reviewToken:request.id),
                    allow:{model.allowPendingModelConsent(consent,reviewToken:request.id)},
                    deferConsent:{_ = model.deferModelConsent(consent,reviewToken:request.id)})
            case .image(let consent,let preview,let caption):
                ConversationImageConsentView(consent:consent,preview:preview,caption:caption,saving:model.checkingImageConsent,
                    allow:{confirmed in model.allowPendingImageConsent(consent,confirmed:confirmed,reviewToken:request.id)},
                    cancel:{_ = model.cancelImageConsent(matching:consent,reviewToken:request.id)})
                    .presentationDetents([.large]).interactiveDismissDisabled(model.checkingImageConsent)
            }}.id(request.id).onAppear {presentation.didAppear(request.id)}
        }.onChange(of:desired,initial:true){_,next in presentation.reconcile(next)}
    }
    private func cancel(_ request:ConversationConsentPresentation) {
        guard request.modelIdentity==ObjectIdentifier(model),request.scope==model.scope else {return}
        switch request.content {
        case .model(let consent):_ = model.deferModelConsent(consent,reviewToken:request.id)
        case .image(let consent,_,_):_ = model.cancelImageConsent(matching:consent,reviewToken:request.id)
        }
    }
}

@MainActor private struct ConversationImageConsentView:View {
    let consent:ConversationImageConsent
    let preview:Data?
    let caption:String
    let saving:Bool
    let allow:(Bool)->Void
    let cancel:()->Void
    @State private var confirmed=false
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    var body:some View {
        NavigationStack {
            ScrollView {VStack(alignment:.leading,spacing:16) {
                if let preview,let image=UIImage(data:preview) {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:192).accessibilityLabel(ui("待确认的图片预览")).accessibilityIdentifier("image.consent.preview")}
                Text(caption).font(CatpawTypography.Role.body.font).textSelection(.enabled)
                Text(ui(consent.body)).font(CatpawTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("image.consent.notice")
                Text(ui("确认后返回输入区，点击发送才会传输图片。")).font(CatpawTypography.Role.caption.font)
            }.padding(20).frame(maxWidth:CatpawLayout.readableWidth,alignment:.leading).frame(maxWidth:.infinity)}
            .accessibilityIdentifier("image.consent.viewport")
            .navigationTitle(ui(consent.title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.cancellationAction){
                Button(action:cancel){Image(systemName:"xmark").font(CatpawTypography.Role.body.font).touchTarget()}
                    .buttonStyle(CatpawPressButtonStyle()).disabled(saving).accessibilityLabel(ui("关闭")).accessibilityIdentifier("image.consent.close")
            }}
            .safeAreaInset(edge:.bottom,spacing:0) {
                VStack(spacing:8) {
                    CatpawConfirmationCheckbox(title:ui(consent.confirmation),isOn:$confirmed).disabled(saving)
                        .accessibilityIdentifier("image.consent.nonSensitive")
                    // v1.1 inline-status SPEC §4.1: the confirmation is stored on this conversation's record only.
                    Text(ui("只对本对话有效")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                        .frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("image.consent.scope")
                    VStack(spacing:4) {
                        Button{allow(confirmed)} label:{Text(ui("本对话允许"))}
                            .buttonStyle(CatpawSheetPrimaryButtonStyle()).disabled(!confirmed || saving).accessibilityIdentifier("image.consent.allow")
                        Button(action:cancel){Text(ui("不发了"))}
                            .buttonStyle(CatpawSheetSecondaryButtonStyle()).disabled(saving).accessibilityIdentifier("image.consent.cancel")
                    }
                    if saving {ProgressView().accessibilityLabel(ui("正在保存确认…"))}
                }.padding(.horizontal,20).padding(.top,12).padding(.bottom,8).frame(maxWidth:CatpawLayout.readableWidth).frame(maxWidth:.infinity)
                    .background(CatpawColors.background).overlay(alignment:.top){CatpawColors.hairline.frame(height:0.5)}
            }.background(CatpawColors.background)
        }.tint(CatpawColors.ink).foregroundStyle(CatpawColors.ink).presentationDragIndicator(.visible)
    }
}
