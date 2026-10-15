import Foundation
import SwiftUI

/// Local state for catpaw.ui.v1 blocks: latest block per id (after `ui.block.update`), server resolution
/// (`ui.block.resolve`) and the user's response. Persisted so cold start restores answered/expired cards.
/// Transport is injected: `responder` sends `ui.response` (tool result of `render_ui`), `errorReporter` sends `ui.error`.
@MainActor final class GenerativeBlockStore: ObservableObject {
    static let shared = GenerativeBlockStore()
    @Published private(set) var blocks: [String: GenerativeBlock] = [:]
    @Published private(set) var responses: [String: GenerativeBlockResponse] = [:]
    @Published private(set) var resolved: Set<String> = []
    var responder: (@MainActor (GenerativeBlockResponse) -> Void)?
    var errorReporter: (@MainActor (GenerativeBlockError) -> Void)?
    private let defaults: UserDefaults?
    private let key = "catpaw.generativeBlocks.v1"
    private var reported: Set<String> = []

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: key), let saved = try? GenerativeBlockCodec.decoder.decode(Snapshot.self, from: data) {
            blocks = saved.blocks; responses = saved.responses; resolved = Set(saved.resolved)
        }
    }

    /// Record a decoded block (called from onAppear, never during view evaluation). Reports `ui.error` once per block.
    func adopt(_ block: GenerativeBlock, error: GenerativeBlockError?) {
        if let error { if reported.insert(block.id).inserted { errorReporter?(error) }; return }
        if blocks[block.id] == nil { blocks[block.id] = block; save() }
    }
    func current(_ block: GenerativeBlock) -> GenerativeBlock { blocks[block.id] ?? block }
    func update(_ patch: GenerativeBlockPatch) { guard let b = blocks[patch.id] else { return }; blocks[patch.id] = b.applying(patch); save() }
    func resolve(_ id: String) { resolved.insert(id); save() }
    func respond(_ response: GenerativeBlockResponse) {
        responses[response.blockId] = response; save()
        responder?(response)
    }
    /// "可点按修改直到下一 turn": the conversation calls this when a new turn starts.
    func lock(_ ids: [String]) { for id in ids where responses[id] != nil { resolved.insert(id) }; save() }
    func reopen(_ id: String) { guard !resolved.contains(id) else { return }; responses[id] = nil; save() }

    private struct Snapshot: Codable { var blocks: [String: GenerativeBlock]; var responses: [String: GenerativeBlockResponse]; var resolved: [String] }
    private func save() {
        guard let defaults, let data = try? GenerativeBlockCodec.encoder.encode(Snapshot(blocks: blocks, responses: responses, resolved: Array(resolved))) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Plug-in adapter for the markdown renderer registry (feat/ios-markdown-render, `MarkdownCustomBlockRegistry`)
/// without a compile-time dependency on it. Once both branches are merged, call once at launch:
///
///     GenerativeBlockAdapter.register { kind, build in
///         MarkdownCustomBlockRegistry.shared.register(kind: kind) { payload, closed in build(payload, closed) }
///     }
///
/// Every catpaw.ui.v1 kind is registered, so a ```catpaw-card fence with `"kind": "choices"` (or `catpaw-card:choices`) renders natively.
@MainActor enum GenerativeBlockAdapter {
    typealias Builder = @MainActor (Data, Bool) -> AnyView
    static var kinds: [String] { GenerativeBlock.Kind.allCases.map(\.rawValue) }

    static func register(store: GenerativeBlockStore = .shared, into register: (_ kind: String, _ build: @escaping Builder) -> Void) {
        for kind in kinds { register(kind) { payload, closed in view(payload: payload, closed: closed, store: store) } }
    }
    /// While the fence is still streaming the JSON is incomplete: show a quiet placeholder, never raw JSON.
    static func view(payload: Data, closed: Bool, store: GenerativeBlockStore = .shared) -> AnyView {
        guard closed else { return AnyView(GenerativeBlockPlaceholder()) }
        switch GenerativeBlockCodec.decode(payload) {
        case .ready(let block): return AnyView(GenerativeBlockView(block: block, store: store))
        case .fallback(let card, let error): return AnyView(GenerativeBlockView(block: card, store: store, validationError: error))
        }
    }
}
