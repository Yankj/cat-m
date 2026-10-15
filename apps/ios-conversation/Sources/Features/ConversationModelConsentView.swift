import SwiftUI
import UIKit

/// The original conversation/route/revision remains the decision authority.
/// A readable native sheet keeps long notices and both actions in one hit tree.
@MainActor struct ConversationModelConsentView:View {
    let consent:ConversationModelConsent
    let canAllow:Bool
    let allow:()->Void
    let deferConsent:()->Void
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text(verbatim:consent.title).font(CatpawTypography.Role.heading.font)
                        .fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("chat.modelConsent.title")
                    Text(verbatim:consent.body).font(CatpawTypography.Role.body.font)
                        .lineSpacing(CatpawTypography.readingLineSpacing(for:CatpawTypography.font(size:textSize)))
                        .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("chat.modelConsent.body")
                }.padding(20).frame(maxWidth:CatpawLayout.readableWidth,alignment:.leading)
                    .frame(maxWidth:.infinity,alignment:.center)
            }.accessibilityIdentifier("chat.modelConsent.viewport")
                .safeAreaInset(edge:.bottom,spacing:0) {
                    CatpawSheetActions {
                        Button(action:allow) {Text(ui("允许此对话"))}
                            .buttonStyle(CatpawSheetPrimaryButtonStyle()).disabled(!canAllow).accessibilityIdentifier("chat.modelConsent.allow")
                    } secondary: {
                        Button(action:deferConsent) {Text(ui("暂不允许"))}
                            .buttonStyle(CatpawSheetSecondaryButtonStyle()).accessibilityIdentifier("chat.modelConsent.defer")
                    }
                }
                .background(CatpawColors.background)
                .navigationTitle(ui("确认发送许可")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button(action:deferConsent) {Image(systemName:"xmark").font(CatpawTypography.Role.body.font).touchTarget()}
                            .buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("关闭"))
                            .accessibilityIdentifier("chat.modelConsent.close")
                    }
                }
        }.tint(CatpawColors.ink).foregroundStyle(CatpawColors.ink)
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .onAppear {UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)}
    }
}
