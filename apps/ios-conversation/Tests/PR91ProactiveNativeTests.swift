import Foundation
import XCTest
@testable import CatpawM

/// Codex PR91 (p91c-1, p91c-5): proactive account barriers that need the iOS SDK (EventKit / ProactiveEngine).
/// L2 runs on a temporary root with ephemeral keys; no Keychain, EventKit write or network.
final class PR91ProactiveNativeTests: XCTestCase {
    /// Temporary L2 root + ephemeral keys for one test; restores the globals afterwards.
    @MainActor private func withTemporaryL2(_ body: () async throws -> Void) async rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr91-proactive-" + UUID().uuidString, isDirectory: true)
        let savedRoot = L2SecureStore.rootDirectory, savedKeys = L2SecureStore.keys
        L2SecureStore.rootDirectory = root; L2SecureStore.keys = EphemeralL2KeyProvider()
        defer {
            L2SecureStore.activate(userID: nil); AccountEpoch.shared.signOut()
            L2SecureStore.rootDirectory = savedRoot; L2SecureStore.keys = savedKeys
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    /// p91c-1: an undo whose token went stale (account switched) never deletes a system reminder.
    @MainActor func testPR91RemoveReminderWithStaleTokenRefusesToWrite() async {
        await withTemporaryL2 {
        AccountEpoch.shared.activate(account: UUID().uuidString)
        let stale = AccountEpoch.shared.capture()
        XCTAssertNotNil(stale)
        AccountEpoch.shared.activate(account: UUID().uuidString)   // B signed in: A's token is stale
        XCTAssertFalse(AccountEpoch.shared.isValid(stale))
        let before = ProactiveEngine.shared.reminderDeletes
        let outcome = await ProactiveEngine.shared.removeReminder("pr91-stale-\(UUID().uuidString)", token: stale)
        XCTAssertNil(outcome, "stale token ⇒ unknown, not undone/alreadyGone")
        XCTAssertEqual(ProactiveEngine.shared.reminderDeletes, before, "no EventKit delete attempted with a stale token")
        let signedOut = await ProactiveEngine.shared.removeReminder("pr91-none", token: nil)
        XCTAssertNil(signedOut)
        XCTAssertEqual(ProactiveEngine.shared.reminderDeletes, before)
        }
    }

    /// p91c-5: legacy ownerless proactive data (global UserDefaults) is sealed into the device vault, not adopted by
    /// the signed-in account, and the plaintext is removed only after the sealed copy reads back.
    @MainActor func testPR91LegacyProactiveDataIsQuarantinedNotAssignedToCurrentAccount() async throws {
        try await withTemporaryL2 {
        let legacyKey = "catpaw.proactive.attendees.v1"
        let raw = try JSONSerialization.data(withJSONObject: ["s-legacy": ["names": ["张三"], "recipients": ["13800000000"]]])
        UserDefaults.standard.set(raw, forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }
        let user = UUID()
        AccountEpoch.shared.activate(account: user.uuidString)
        L2SecureStore.activate(userID: user)
        let current = try XCTUnwrap(L2SecureStore.current)

        let seen = ProactiveEngine.shared.attendees(for: "s-legacy")
        XCTAssertTrue(seen.names.isEmpty && seen.recipients.isEmpty, "legacy attendees must not surface for the current account")
        XCTAssertNil(UserDefaults.standard.data(forKey: legacyKey), "plaintext removed once the sealed copy verified")
        XCTAssertNil(current.data(forKey: ProactiveEngine.sealedAttendeesKey), "nothing written into the account's own store")
        let vault = try L2SecureStore(userID: LegacyMemoryQuarantine.vaultID, root: L2SecureStore.rootDirectory, keys: L2SecureStore.keys)
        let kept = vault.get([Data].self, forKey: "proactive.legacy-quarantine.v1." + legacyKey) ?? []
        XCTAssertEqual(kept, [raw], "the legacy bytes are kept sealed in the device vault")
        XCTAssertTrue(ProactiveEngine.quarantineLegacy(raw, name: legacyKey), "re-quarantining the same bytes is idempotent")
        XCTAssertEqual(vault.get([Data].self, forKey: "proactive.legacy-quarantine.v1." + legacyKey), [raw])
        }
    }
}
