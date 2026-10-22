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
                    Text(verbatim:consent.title).font(catTypography.Role.heading.font)
                        .fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("chat.modelConsent.title")
                    Text(verbatim:consent.body).font(catTypography.Role.body.font)
                        .lineSpacing(catTypography.readingLineSpacing(for:catTypography.font(size:textSize)))
                        .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("chat.modelConsent.body")
                }.padding(20).frame(maxWidth:catLayout.readableWidth,alignment:.leading)
                    .frame(maxWidth:.infinity,alignment:.center)
            }.accessibilityIdentifier("chat.modelConsent.viewport")
                .safeAreaInset(edge:.bottom,spacing:0) {
                    catSheetActions {
                        Button(action:allow) {Text(ui("允许此对话"))}
                            .buttonStyle(catSheetPrimaryButtonStyle()).disabled(!canAllow).accessibilityIdentifier("chat.modelConsent.allow")
                    } secondary: {
                        Button(action:deferConsent) {Text(ui("暂不允许"))}
                            .buttonStyle(catSheetSecondaryButtonStyle()).accessibilityIdentifier("chat.modelConsent.defer")
                    }
                }
                .background(catColors.background)
                .navigationTitle(ui("确认发送许可")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button(action:deferConsent) {Image(systemName:"xmark").font(catTypography.Role.body.font).touchTarget()}
                            .buttonStyle(catPressButtonStyle()).accessibilityLabel(ui("关闭"))
                            .accessibilityIdentifier("chat.modelConsent.close")
                    }
                }
        }.tint(catColors.ink).foregroundStyle(catColors.ink)
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .onAppear {UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)}
    }
}
