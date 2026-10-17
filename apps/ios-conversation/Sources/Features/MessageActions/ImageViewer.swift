import SwiftUI
import Photos
import UIKit

/// Full-screen image viewer: pinch zoom (1–5×), double-tap zoom at point, pan while zoomed, swipe down to dismiss with
/// the backdrop fading, save to Photos and share. Chrome toggles on single tap.
@MainActor struct ImageViewer: View {
    let image: UIImage
    let close: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dismissDrag: CGSize = .zero
    @State private var chrome = true
    @State private var sharing = false
    @State private var toastKey: String?
    @State private var shown = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private var dragProgress: CGFloat { min(1, abs(dismissDrag.height) / 300) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CatpawColors.background.ignoresSafeArea().opacity(shown ? 1 - dragProgress * 0.8 : 0)
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale * (1 - dragProgress * 0.25))
                    .offset(x: offset.width + dismissDrag.width, y: offset.height + dismissDrag.height)
                    .gesture(magnify.simultaneously(with: pan(geo.size)))
                    .onTapGesture(count: 2, perform: { location in doubleTap(at: location, in: geo.size) })
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
                    .accessibilityLabel(Text(ui("图片"))).accessibilityAddTraits(.isImage)
                    .accessibilityAction(named: Text(ui("放大"))) { withAnimation { scale = scale > 1 ? 1 : 2.5; lastScale = scale; offset = .zero; lastOffset = .zero } }
                if chrome && dismissDrag == .zero { controls.transition(.opacity) }
                if let toastKey {
                    Text(ui(toastKey)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule())
                }
            }
        }
        .statusBarHidden(!chrome)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { shown = true } }
        .sheet(isPresented: $sharing) { MessageShareSheet(items: [image]) }
        .accessibilityAction(.escape) { close() }
        .accessibilityIdentifier("chat.imageViewer")
    }

    private var controls: some View {
        VStack {
            HStack {
                circleButton("xmark", "关闭") { close() }.accessibilityIdentifier("chat.imageViewer.close")
                Spacer()
                circleButton("square.and.arrow.down", "保存到照片") { save() }.accessibilityIdentifier("chat.imageViewer.save")
                circleButton("square.and.arrow.up", "分享") { sharing = true }.accessibilityIdentifier("chat.imageViewer.share")
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Spacer()
        }
    }
    private func circleButton(_ symbol: String, _ key: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(CatpawColors.ink)
                .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
        }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(Text(ui(key)))
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = max(0.8, min(5, lastScale * v.magnification)) }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if scale < 1 { scale = 1; offset = .zero; lastOffset = .zero }
                }
                lastScale = scale
            }
    }
    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if scale > 1.01 { offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) }
                else if abs(v.translation.height) > abs(v.translation.width) { dismissDrag = v.translation }
            }
            .onEnded { v in
                if scale > 1.01 { offset = clamp(offset, size); lastOffset = offset; return }
                if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 400 {
                    withAnimation(.easeOut(duration: 0.2)) { dismissDrag.height = v.translation.height > 0 ? size.height : -size.height; shown = false }
                    Task { try? await Task.sleep(for: .milliseconds(200)); close() }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dismissDrag = .zero }
                }
            }
    }
    private func clamp(_ o: CGSize, _ size: CGSize) -> CGSize {
        let mx = size.width * (scale - 1) / 2, my = size.height * (scale - 1) / 2
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }
    private func doubleTap(at p: CGPoint, in size: CGSize) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if scale > 1.01 { scale = 1; offset = .zero }
            else {
                scale = 2.5
                offset = clamp(CGSize(width: (size.width / 2 - p.x) * 1.5, height: (size.height / 2 - p.y) * 1.5), size)
            }
        }
        lastScale = scale; lastOffset = offset
    }
    /// Needs NSPhotoLibraryAddUsageDescription in Info.plist.
    private func save() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { flash("没有照片权限，请在设置中允许"); return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success); flash("已保存到照片")
        }
    }
    private func flash(_ key: String) {
        withAnimation { toastKey = key }
        Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation { toastKey = nil } }
    }
}
