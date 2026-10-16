// Test-only shims so the PR90 proactive runner builds without the app target (and on Linux, without CryptoKit).
import Foundation
struct MemoryLibraryItem: Sendable, Equatable { var content: String }
struct MemoryLibrarySnapshot: Sendable, Equatable { var useMemory: Bool; var items: [MemoryLibraryItem] }
#if !canImport(CryptoKit)
enum SHA256 { // FNV-1a stand-in: stable, not cryptographic (tests only).
    static func hash(data: Data) -> [UInt8] {
        var h: UInt64 = 0xcbf29ce484222325; for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return (0..<32).map { UInt8(truncatingIfNeeded: h >> (UInt64($0 % 8) * 8)) }
    }
}
#endif
