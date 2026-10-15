import SwiftUI
import UIKit

/// Inline thumbnail for a sent image (bytes from the local image store). Falls back to the old "附带图片" label when the
/// bytes are gone (the store drops them after the turn resolves). Long-press opens the image menu.
@MainActor struct MessageImageThumbnail: View {
    let id: String
    let load: @MainActor () async -> Data?
    var onReply: ((String) -> Void)? = nil
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var viewerOpen = false
    @ScaledMetric(relativeTo: .body) private var maxSide: CGFloat = 220
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let image {
                thumb(image)
                    .messageLongPress(id: id + ".image", content: .image(image), alignment: .trailing, onReply: onReply) { thumb(image) }
                    .onTapGesture { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { viewerOpen = true } }
                    .accessibilityAddTraits(.isImage).accessibilityLabel(Text(AppLanguage(locale: locale).ui("附带图片")))
            } else if loaded {
                Label(AppLanguage(locale: locale).ui("附带图片"), systemImage: "photo").font(CatpawTypography.Role.caption.font)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CatpawColors.panel).frame(width: 120, height: 90)
            }
        }
        .accessibilityIdentifier("chat.message.image")
        .task(id: id) {
            if let data = await load(), let img = UIImage(data: data) { image = img }
            loaded = true
        }
        .modifier(MessageImageViewerHook(image: image, isPresented: $viewerOpen))
    }

    private func thumb(_ image: UIImage) -> some View {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        let w = ratio >= 1 ? maxSide : maxSide * ratio, h = ratio >= 1 ? maxSide / ratio : maxSide
        return Image(uiImage: image).resizable().scaledToFill().frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Presents `ImageViewer` without the system slide (the viewer fades its own backdrop).
struct MessageImageViewerHook: ViewModifier {
    let image: UIImage?
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { isPresented }, set: { v in var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { isPresented = v } })) {
            if let image {
                ImageViewer(image: image) { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { isPresented = false } }
                    .presentationBackground(.clear)
            }
        }
    }
}
