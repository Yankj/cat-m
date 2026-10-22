import Foundation

public struct BlobStore: Sendable {
    public let root: URL
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public func stage(_ data: Data) throws -> String {
        guard data.count <= ConversationAttachmentLimits.maxBytesPerFile else { throw catError.invalid("文件超过本地导入上限 20 MB。") }
        let hash = bytesHash(data)
        let url = root.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return hash
    }
    public func read(_ reference: String) throws -> Data {
        guard reference.count == 64, reference.allSatisfy({ $0.isHexDigit }) else { throw catError.invalid("文件引用无效。") }
        let data = try Data(contentsOf: root.appendingPathComponent(reference))
        guard bytesHash(data) == reference else { throw catError.corrupt("文件校验失败，停止读取。") }; return data
    }
    public func reconcile(referenced: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !referenced.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Private, account-partitioned local transport bytes. No cloud/Keychain/provider access.
public actor FileConversationImageByteStore:ConversationImageByteStore {
    private let root:URL
    public init(root:URL) throws {
        self.root=root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var excluded=root;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:root.path)
        #endif
    }
    private func url(_ c:UUID,_ o:UUID)->URL {root.appendingPathComponent(c.uuidString.lowercased()+"-"+o.uuidString.lowercased()+".image")}
    public func save(_ payload:ConversationVisionPayload,conversationID:UUID,operationID:UUID) throws {
        guard payload.reference.isValid,payload.bytes.count==payload.reference.receipt.size_bytes,bytesHash(payload.bytes)==payload.reference.receipt.sha256 else {throw ConversationSessionError.invalidEvent}
        let target=url(conversationID,operationID)
        if FileManager.default.fileExists(atPath:target.path) {guard try Data(contentsOf:target)==payload.bytes else {throw catError.conflict};return}
        #if os(iOS)
        try payload.bytes.write(to:target,options:[.atomic,.completeFileProtection])
        #else
        try payload.bytes.write(to:target,options:.atomic)
        #endif
    }
    public func read(reference:ConversationVisionReference,conversationID:UUID,operationID:UUID) throws -> Data {
        guard reference.isValid else {throw ConversationSessionError.invalidEvent}
        let target=url(conversationID,operationID)
        guard FileManager.default.fileExists(atPath:target.path) else {throw catError.missing}
        let handle=try FileHandle(forReadingFrom:target);defer {try? handle.close()}
        let data=try handle.read(upToCount:reference.receipt.size_bytes+1) ?? Data();guard data.count==reference.receipt.size_bytes,bytesHash(data)==reference.receipt.sha256 else {throw catError.corrupt("本机图片校验失败，停止发送。")};return data
    }
    public func remove(conversationID:UUID,operationID:UUID) throws {
        let target=url(conversationID,operationID);if FileManager.default.fileExists(atPath:target.path){try FileManager.default.removeItem(at:target)}
    }
}
