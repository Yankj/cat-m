#if os(iOS)
import SwiftUI
import PhotosUI
import UIKit

/// The only library entry is Apple's selected-item picker; selecting never uploads.
public struct ImageAttachmentPicker: View {
    @ObservedObject private var draft: ImageAttachmentDraft
    private let gate: ImageSendGate
    private let localize:(String)->String
    @State private var selectedItem: PhotosPickerItem?
    @State private var pendingItem: PhotosPickerItem?
    @State private var load: Task<Void, Never>?
    @State private var previewPresented=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(draft: ImageAttachmentDraft, gate: ImageSendGate = .unavailable,localize:@escaping (String)->String = {$0}) {
        self.draft = draft; self.gate = gate;self.localize=localize
    }
    public var body: some View {
        let pickerTitle = draft.attachment == nil ? localize("选择图片") : localize("更换图片")
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                PhotosPicker(selection: $selectedItem, matching: .images, preferredItemEncoding: .current) {
                    Label(pickerTitle, systemImage: "photo.badge.plus")
                        .font(.body).padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityHint(localize("只读取你选择的一张图片，选择后不会发送"))
                    .accessibilityIdentifier("attachment.pick")
                Spacer(minLength: 8)
                if draft.phase != .empty {
                    Button {
                        load?.cancel(); selectedItem = nil; pendingItem = nil; draft.clear()
                    } label: {
                        Image(systemName: "xmark").font(.body).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel(localize("移除图片")).accessibilityIdentifier("attachment.remove")
                }
            }
            if let attachment = draft.attachment, let image = UIImage(data: attachment.thumbnailData) {
                Image(uiImage: image).resizable().scaledToFill().frame(width:80,height:80).clipped().clipShape(RoundedRectangle(cornerRadius:10)).onTapGesture{previewPresented=true}
                    .accessibilityLabel(draft.isShowingRetainedAttachment ? localize("上次处理完成的图片，尚未替换") : localize("已选图片预览，尚未发送"))
                    .accessibilityIdentifier("attachment.preview")
            }
            if draft.isProcessing {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !reduceMotion { ProgressView().accessibilityHidden(true) }
                    Text(draft.phase == .loading ? localize("正在读取所选图片…") : localize("正在处理图片…")).font(.subheadline)
                    Button(localize("取消")) { load?.cancel(); draft.cancelProcessing() }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("attachment.cancel")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("attachment.processing")
            }
            if case .failed(let error) = draft.phase {
                Text(localize(error.message)).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("attachment.error")
                if draft.isShowingRetainedAttachment { Text(localize("上次处理完成的图片仍保留，当前附件不可发送。")).font(.subheadline) }
                if draft.canRetry {
                    Button(localize("重新处理图片")) { draft.retryEncoding() }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("attachment.retry")
                } else if let pendingItem {
                    Button(localize("重新读取所选图片")) { beginImport(pendingItem) }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("attachment.retryRead")
                }
            }
            if draft.phase != .empty {
                Text(gate.available && gate.liveTransmissionAvailable ? localize("所选图片仅在你发送并确认处理方式后外发。") : localize(ImageSendBlock.unavailable.message))
                    .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("attachment.localOnly")
            }
        }.buttonStyle(AttachmentPressStyle())
            .sheet(isPresented:$previewPresented) {
                NavigationStack {
                    if let data=draft.attachment?.encodedData,let image=UIImage(data:data) {Image(uiImage:image).resizable().scaledToFit().padding().accessibilityLabel(localize("所选图片完整预览"))}
                }.toolbar {ToolbarItem(placement:.confirmationAction){Button(localize("完成")){previewPresented=false}}}
            }
            .onChange(of: selectedItem) { _, item in
                if let item { beginImport(item) }
            }
            .onChange(of: draft.phase) { _, phase in
                if phase == .empty { load?.cancel(); pendingItem = nil; selectedItem = nil }
            }
            .onDisappear { load?.cancel(); draft.cancelProcessing() }
    }
    private func beginImport(_ item: PhotosPickerItem) {
        load?.cancel(); pendingItem = item
        let ticket = draft.beginSelection()
        load = Task {
            do {
                let data = try await item.loadTransferable(type: Data.self)
                guard !Task.isCancelled else { return }
                if let data {
                    draft.receiveSelectedData(data, ticket: ticket); pendingItem = nil
                } else { draft.selectionFailed(ticket: ticket) }
            } catch { if !Task.isCancelled { draft.selectionFailed(ticket: ticket) } }
            if !Task.isCancelled { selectedItem = nil }
        }
    }
}
private struct AttachmentPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
