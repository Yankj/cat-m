import SwiftUI

#if DEBUG
#Preview("In-app banner") {
    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        .catpawInAppBanner()
        .task { catInAppBannerCenter.shared.show(.init(title: "提醒：喝水", body: "该起来活动一下啦", deepLink: URL(string: "catpawm://"))) }
}
#endif
