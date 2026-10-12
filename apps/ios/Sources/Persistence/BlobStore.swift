import Foundation

public struct BlobStore: Sendable {
    public let root: URL
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public func stage(_ data: Data) throws -> String {
        guard data.count <= 20 * 1024 * 1024 else { throw CatpawError.invalid("文件超过本地导入上限 20 MB。") }
        let hash = bytesHash(data)
        let url = root.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return hash
    }
    public func read(_ reference: String) throws -> Data {
        guard reference.count == 64, reference.allSatisfy({ $0.isHexDigit }) else { throw CatpawError.invalid("文件引用无效。") }
        let data = try Data(contentsOf: root.appendingPathComponent(reference))
        guard bytesHash(data) == reference else { throw CatpawError.corrupt("文件校验失败，停止读取。") }; return data
    }
    public func reconcile(referenced: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !referenced.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
