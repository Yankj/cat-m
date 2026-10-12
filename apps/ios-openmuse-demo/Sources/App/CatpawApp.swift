import SwiftUI

@MainActor final class Bootstrap: ObservableObject {
    let model: AppModel?
    let error: String?
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CatpawM-OpenMuseDemo", isDirectory: true)
        do {
            #if os(iOS)
            let storage: any SnapshotPersistence = try SwiftDataPersistence(url: root.appendingPathComponent("local.store"))
            #else
            let storage: any SnapshotPersistence = FilePersistence(url: root.appendingPathComponent("portable-preview.json"))
            #endif
            let repo = try Repository(persistence: storage)
            let blobs = try BlobStore(root: root.appendingPathComponent("blobs"))
            let service = WorkspaceService(repository: repo, blobs: blobs)
            let fixture = try OpenMuseFixtureTransport(stateURL: root.appendingPathComponent("openmuse-named-fixture.json"))
            model = AppModel(repository: repo, service: service, openMuseFixtureService: OpenMuseTaskService(repository: repo, transport: fixture)); error = nil
        } catch { self.model = nil; self.error = error.localizedDescription }
    }
}
@MainActor @main struct CatpawMApp: App {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @StateObject private var bootstrap = Bootstrap()
    var body: some Scene {
        WindowGroup {
            if let model = bootstrap.model { RootView(model: model) }
            else { EmptyState(title: ui("本地存储无法打开"), detail: (bootstrap.error ?? ui("未知错误")) + ui("\n原文件已保留，未重置存储。请在完整 Xcode 下排查迁移或恢复。")) }
        }
    }
}
