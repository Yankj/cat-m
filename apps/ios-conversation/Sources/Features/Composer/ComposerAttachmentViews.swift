import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import UIKit

// MARK: Attachment strip (chips with thumbnail / progress / retry / remove, tap → Quick Look)

@MainActor struct ComposerAttachmentStrip: View {
    @Binding var attachments: [ComposerAttachment]
    var onRetry: (ComposerAttachment) -> Void
    var onRemove: (ComposerAttachment) -> Void
    @State private var previewURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { item in
                        ComposerAttachmentChip(item: item,
                                               open: { previewURL = item.localURL },
                                               retry: { onRetry(item) },
                                               remove: { onRemove(item) })
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 4).padding(.top, 4)
            }
            .animation(CatpawMotion.resolved(CatpawMotion.chip, reduceMotion), value: attachments.map(\.id))
            .quickLookPreview($previewURL, in: attachments.map(\.localURL))
            .accessibilityIdentifier("chat.composer.attachments")
        }
    }
}

@MainActor struct ComposerAttachmentChip: View {
    let item: ComposerAttachment
    let open: () -> Void
    let retry: () -> Void
    let remove: () -> Void
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private let side: CGFloat = 56

    var body: some View {
        Button(action: open) {
            ZStack {
                if let data = item.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: item.kind.symbol).font(.body)
                        Text((item.filename as NSString).pathExtension.uppercased()).font(CatpawTypography.Role.caption.font.weight(.semibold)).lineLimit(1)
                    }.foregroundStyle(CatpawColors.secondary)
                }
                overlay
            }
            .frame(width: side, height: side)
            .background(CatpawColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(borderColor, lineWidth: 1))
        }
        .buttonStyle(CatpawPressButtonStyle())
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark").font(CatpawTypography.Role.caption.font.weight(.bold)).foregroundStyle(CatpawColors.onInk)
                    .frame(width: 18, height: 18).background(CatpawColors.ink, in: Circle())
                    .frame(width: 32, height: 32) // hit area
            }
            .offset(x: 10, y: -10)
            .accessibilityLabel(ui("移除附件"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.filename)
        .accessibilityValue(statusText)
        .accessibilityAction(named: Text(ui("预览"))) { open() }
    }

    @ViewBuilder private var overlay: some View {
        switch item.status {
        case .staged, .uploaded: EmptyView()
        case let .uploading(fraction):
            ZStack {
                CatpawColors.ink.opacity(0.28)
                Circle().stroke(CatpawColors.onInk.opacity(0.35), lineWidth: 2.5).frame(width: 22, height: 22)
                Circle().trim(from: 0, to: max(0.04, fraction)).stroke(CatpawColors.onInk, style: .init(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 22, height: 22)
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        case .failed:
            ZStack {
                CatpawColors.ink.opacity(0.35)
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise").font(CatpawTypography.Role.caption.font.weight(.bold)).foregroundStyle(CatpawColors.onInk).touchTarget()
                }.accessibilityLabel(ui("重试上传"))
            }
        }
    }

    private var borderColor: Color { if case .failed = item.status { return CatpawColors.failure }; return CatpawColors.separator }
    private var statusText: String {
        switch item.status {
        case .staged: ui("待上传")
        case let .uploading(f): ui("上传中") + " \(Int(f * 100))%"
        case .uploaded: ui("已上传")
        case .failed: ui("上传失败")
        }
    }
}

// MARK: "+" menu: photos (multi), camera, files

@MainActor struct ComposerAddMenu: View {
    let remaining: Int
    let add: ([ComposerAttachment]) -> Void
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label(ui("照片"), systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label(ui("拍照"), systemImage: "camera") }
            }
            Button { showFiles = true } label: { Label(ui("文件"), systemImage: "folder") }
        } label: {
            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(CatpawColors.ink)
                .frame(width: 36, height: 36).touchTarget()
        }
        .disabled(remaining <= 0)
        .accessibilityLabel(ui("添加附件"))
        .accessibilityIdentifier("chat.composer.add")
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: max(1, remaining),
                      matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { add(await Self.load(items)) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: ComposerAttachmentLimits.importTypes, allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            add(urls.compactMap { try? ComposerAttachmentStager.stage(fileURL: $0) })
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { data in
                if let data, let item = try? ComposerAttachmentStager.stage(data: data, filename: "Photo.jpg", type: .jpeg) { add([item]) }
            }.ignoresSafeArea()
        }
    }

    private static func load(_ items: [PhotosPickerItem]) async -> [ComposerAttachment] {
        var out: [ComposerAttachment] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first ?? .jpeg
            let name = "Image \(i + 1)." + (type.preferredFilenameExtension ?? "jpg")
            if let staged = try? ComposerAttachmentStager.stage(data: data, filename: name, type: type) { out.append(staged) }
        }
        return out
    }
}

private struct CameraCapture: UIViewControllerRepresentable {
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
            done((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85)); picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil); picker.dismiss(animated: true) }
    }
}

// MARK: Drop + paste

extension View {
    /// Drop images/files onto the conversation or composer. Paste of images is handled in `ConversationTextView.paste(_:)`
    /// (UIKit owns the editor), see `ComposerPasteHandling` below.
    func composerDropTarget(isTargeted: Binding<Bool>, add: @escaping ([ComposerAttachment]) -> Void) -> some View {
        onDrop(of: [.fileURL, .image], isTargeted: isTargeted) { providers in
            Task { @MainActor in add(await ComposerItemProviderLoader.load(providers)) }
            return true
        }
    }
}

enum ComposerItemProviderLoader {
    @MainActor static func load(_ providers: [NSItemProvider]) async -> [ComposerAttachment] {
        var out: [ComposerAttachment] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                   _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) } }),
               let staged = try? ComposerAttachmentStager.stage(fileURL: url) { out.append(staged); continue }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await withCheckedContinuation({ (c: CheckedContinuation<Data?, Never>) in
                   _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in c.resume(returning: d) } }),
               let staged = try? ComposerAttachmentStager.stage(data: data, filename: provider.suggestedName.map { $0 + ".png" } ?? "Pasted.png", type: .png) {
                out.append(staged)
            }
        }
        return out
    }
}

/// Paste policy for the UIKit editor. Integration: in `ConversationTextView` override
/// `canPerformAction(_:withSender:)` / `paste(_:)` and call `ComposerPasteHandling.intercept(...)`; if it returns true,
/// skip `super.paste`. Long text (> 400 chars) becomes a .txt attachment so the draft stays editable.
enum ComposerPasteHandling {
    @MainActor static func intercept(_ pasteboard: UIPasteboard = .general, add: ([ComposerAttachment]) -> Void) -> Bool {
        if pasteboard.hasImages, let image = pasteboard.image, let data = image.pngData(),
           let staged = try? ComposerAttachmentStager.stage(data: data, filename: "Pasted.png", type: .png) {
            add([staged]); return true
        }
        if let text = pasteboard.string, text.count > ComposerAttachmentLimits.pasteTextThreshold,
           let staged = try? ComposerAttachmentStager.stage(data: Data(text.utf8), filename: "Pasted.txt", type: .plainText) {
            add([staged]); return true
        }
        return false
    }
}
