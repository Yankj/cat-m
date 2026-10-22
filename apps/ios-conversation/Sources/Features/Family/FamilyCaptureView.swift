import SwiftUI
import PhotosUI
import UIKit

/// Capture by text or a notice photo. Output is always confirm cards; nothing is scheduled here.
struct FamilyCaptureView: View {
    @ObservedObject var store: FamilyStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var working = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("比如：下周三下午4点半小米游泳课，带泳镜").font(.footnote).foregroundStyle(catColors.secondary)
                TextEditor(text: $text).frame(minHeight: 120).padding(8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(catColors.input))
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("拍/选一张通知", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 44)
                }
                .foregroundStyle(catColors.ink).background(Capsule().stroke(catColors.controlEdge))
                FamilyPrimaryButton(title: working ? "整理中…" : "整理成待确认") {
                    Task { working = true; await store.capture(text: text); working = false; dismiss() }
                }
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(16).background(catColors.calmPage.ignoresSafeArea())
            .navigationTitle("记一件事").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    working = true; defer { working = false }
                    guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = Self.downscaledJPEG(data) else { store.notice = "这张图片没能读出来"; return }
                    await store.capture(photoJPEG: jpeg); dismiss()
                }
            }
        }
    }
    /// Server limit: JPEG/PNG ≤ 5 MiB and ≤ 2048 px per side.
    static func downscaledJPEG(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 2048, s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: floor(img.size.width * s), height: floor(img.size.height * s))
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        var q: CGFloat = 0.8
        while q > 0.3 { if let d = out.jpegData(compressionQuality: q), d.count <= 5 * 1024 * 1024 { return d }; q -= 0.15 }
        return nil
    }
}
