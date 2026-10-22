import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "+" floating popover (Grok-style): blurred material card with 相机 / 照片 / 文件 tiles and an inline
/// recent-photos grid (PHAsset); bottom capsule "已选择 N · 添加". Standalone: the composer (Mac worker) owns
/// placement. Integration: `.composerAttachPopover(isPresented:remaining:onAdd:)` on the composer, toggled by "+".
@MainActor struct ComposerAttachPopoverView: View {
    let remaining: Int
    let onAdd: ([ComposerAttachment]) -> Void
    let onDismiss: () -> Void
    @State private var library = RecentPhotoLibrary()
    @State private var selected: [String] = []          // PHAsset localIdentifiers, in tap order
    @State private var adding = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showFullPicker = false
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 76
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                tile(ui("相机"), "camera", id: "camera") { showCamera = true }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                tile(ui("照片"), "photo.on.rectangle", id: "photos") { showFullPicker = true }
                tile(ui("文件"), "doc", id: "files") { showFiles = true }
            }
            grid
            if !selected.isEmpty {
                Button { Task { await addSelected() } } label: {
                    Text(adding ? ui("正在添加…") : ui("已选择 {0} · 添加", [String(selected.count)]))
                        .font(catTypography.Role.body.font.weight(.semibold)).foregroundStyle(catColors.onInk)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(catColors.ink, in: Capsule())
                }
                .buttonStyle(catPressButtonStyle()).disabled(adding)
                .accessibilityIdentifier("chat.attach.add")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(catColors.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: catColors.ink.opacity(0.18), radius: 24, y: 8)
        .animation(.snappy(duration: 0.25), value: selected.isEmpty)
        .task { await library.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.attach.popover")
        .fileImporter(isPresented: $showFiles, allowedContentTypes: ComposerAttachmentLimits.importTypes, allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task { finish(await ComposerAttachmentStager.stageOffMain(fileURLs: Array(urls.prefix(remaining)))) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            AttachPopoverCamera { data in
                showCamera = false
                if let data { Task { if let item = await ComposerAttachmentStager.stageOffMain(data: data, filename: "Photo.jpg", type: .jpeg) { finish([item]) } } }
            }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showFullPicker, selection: Binding(get: { [] }, set: { items in
            guard !items.isEmpty else { return }
            Task { finish(await Self.loadPicker(items)) }
        }), maxSelectionCount: max(1, remaining), matching: .images, preferredItemEncoding: .compatible)
    }

    private func tile(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(catTypography.Role.heading.font).foregroundStyle(catColors.ink)
                Text(title).font(catTypography.Role.secondary.font).foregroundStyle(catColors.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(catColors.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(catPressButtonStyle())
        .accessibilityIdentifier("chat.attach." + id)
    }

    @ViewBuilder private var grid: some View {
        switch library.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: cell)
        case .denied:
            HStack(spacing: 8) {
                Text(ui("允许访问照片后，这里会显示最近的照片。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                Spacer(minLength: 0)
                Button(ui("去设置")) { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                    .font(catTypography.Role.secondary.font.weight(.semibold)).foregroundStyle(catColors.ink)
            }.frame(minHeight: 44)
        case .ready:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(cell), spacing: 6), GridItem(.fixed(cell), spacing: 6)], spacing: 6) {
                    ForEach(library.assets, id: \.localIdentifier) { asset in thumb(asset) }
                }
            }
            .frame(height: cell * 2 + 6)
        }
    }

    private func thumb(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let order = selected.firstIndex(of: id)
        return Button { toggle(id) } label: {
            PhotoThumb(asset: asset, side: cell)
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(order == nil ? catColors.ink.opacity(0.25) : catBrand.paw)
                        Circle().stroke(catColors.onInk, lineWidth: 1.5)
                        if let order { Text(verbatim: "\(order + 1)").font(catTypography.Role.caption.font.weight(.bold)).foregroundStyle(catColors.ink) }
                    }
                    .frame(width: 24, height: 24).padding(5)
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(order == nil ? Color.clear : catBrand.paw, lineWidth: 2))
        }
        .buttonStyle(catPressButtonStyle())
        .sensoryFeedback(.selection, trigger: order != nil)
        .accessibilityLabel(ui("照片"))
        .accessibilityValue(order == nil ? "" : ui("已选择"))
        .accessibilityIdentifier("chat.attach.thumb")
    }

    private func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) }
        else if selected.count < remaining { selected.append(id) }
    }

    private func addSelected() async {
        adding = true; defer { adding = false }
        var out: [ComposerAttachment] = []
        for (i, id) in selected.enumerated() {
            guard let (data, type) = await library.data(for: id) else { continue }
            let name = "Image \(i + 1)." + (type.preferredFilenameExtension ?? "jpg")
            if let staged = await ComposerAttachmentStager.stageOffMain(data: data, filename: name, type: type) { out.append(staged) }
        }
        selected = []
        finish(out)
    }

    private func finish(_ items: [ComposerAttachment]) {
        guard !items.isEmpty else { return }
        onAdd(items); onDismiss()
    }

    private static func loadPicker(_ items: [PhotosPickerItem]) async -> [ComposerAttachment] {
        var out: [ComposerAttachment] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first ?? .jpeg
            if let staged = await ComposerAttachmentStager.stageOffMain(data: data, filename: "Image \(i + 1)." + (type.preferredFilenameExtension ?? "jpg"), type: type) { out.append(staged) }
        }
        return out
    }
}

/// Recent images via PHAsset (limited library access is fine).
@MainActor @Observable final class RecentPhotoLibrary {
    enum State { case loading, ready, denied }
    private(set) var state: State = .loading
    private(set) var assets: [PHAsset] = []
    var limit = 60

    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { state = .denied; return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [PHAsset] = []
        result.enumerateObjects { a, _, _ in list.append(a) }
        assets = list; state = .ready
    }

    func data(for id: String) async -> (Data, UTType)? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat; options.version = .current
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                if let data { cont.resume(returning: (data, uti.flatMap(UTType.init) ?? .jpeg)) } else { cont.resume(returning: nil) }
            }
        }
    }
}

private struct PhotoThumb: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        ZStack {
            catColors.panel
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: asset.localIdentifier) {
            let size = CGSize(width: side * scale, height: side * scale)
            let options = PHImageRequestOptions(); options.deliveryMode = .opportunistic; options.isNetworkAccessAllowed = true
            let asset = asset
            image = await withCheckedContinuation { cont in
                var resumed = false
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !resumed, !degraded || img == nil else { return }
                    resumed = true; cont.resume(returning: img)
                }
            }
        }
    }
}

private struct AttachPopoverCamera: UIViewControllerRepresentable {
    let done: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Data?) -> Void
        init(done: @escaping (Data?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

extension View {
    /// Floating "+" popover anchored above the composer, with a dimmed tap-to-dismiss backdrop.
    func composerAttachPopover(isPresented: Binding<Bool>, remaining: Int, onAdd: @escaping ([ComposerAttachment]) -> Void) -> some View {
        overlay(alignment: .bottom) {
            if isPresented.wrappedValue {
                ZStack(alignment: .bottom) {
                    catColors.ink.opacity(0.12).ignoresSafeArea().onTapGesture { isPresented.wrappedValue = false }
                        .accessibilityHidden(true)
                    ComposerAttachPopoverView(remaining: remaining, onAdd: onAdd, onDismiss: { isPresented.wrappedValue = false })
                        .padding(.horizontal, 12).padding(.bottom, 8)
                        .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: isPresented.wrappedValue)
    }
}
