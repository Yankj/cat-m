import Foundation
import Combine

@MainActor
final class ParentingWorkspaceModel: ObservableObject {
    @Published private(set) var workspace: ParentingWorkspace = .empty
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error: String?
    /// Nil when this model has no reminder authority (fixtures, tests, signed-out shells).
    @Published private(set) var reminderStatus: ParentingReminderStatus?
    @Published private(set) var reminderSettings: ParentingReminderSettings = .default

    private let store: ParentingWorkspaceStore
    private let reminders: ParentingReminderScheduler?
    private let reminderSettingsStore: ParentingReminderSettingsStore?
    private let clock: @Sendable () -> Date

    var remindersAvailable: Bool { reminders != nil }

    init(repository: Repository, scope: DataScope, subjectID: UUID?, cipher: any ParentingWorkspaceCipher = ParentingPersistentCipher(),
         reminders: ParentingReminderScheduler? = nil, reminderSettingsStore: ParentingReminderSettingsStore? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        store = ParentingWorkspaceStore(repository: repository, scope: scope, subjectID: subjectID, cipher: cipher)
        self.reminders = reminders; self.reminderSettingsStore = reminderSettingsStore; self.clock = clock
        reminderSettings = reminderSettingsStore?.load() ?? .default
    }
    init(store: ParentingWorkspaceStore, reminders: ParentingReminderScheduler? = nil,
         reminderSettingsStore: ParentingReminderSettingsStore? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.reminders = reminders; self.reminderSettingsStore = reminderSettingsStore; self.clock = clock
        reminderSettings = reminderSettingsStore?.load() ?? .default
    }

    func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let saved = try await store.load()
            guard store.isCurrentAccount() else { throw catError.unavailable("账号已变更，请重新打开育儿账本。") }
            workspace = saved; loaded = true
        } catch {
            self.error = error.localizedDescription
            return
        }
        await syncReminders()
    }

    @discardableResult
    func apply(_ command: ParentingCommand, operationID: UUID = UUID(), expectedRevision: Int? = nil) async -> Bool {
        guard !busy else { return false }
        guard loaded else { error = "请先载入育儿账本，再保存修改。"; return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            let saved = try await store.apply(command, expectedRevision: expectedRevision ?? workspace.revision, operationID: operationID)
            guard store.isCurrentAccount() else { throw catError.unavailable("账号已变更，请重新打开育儿账本。") }
            workspace = saved
        } catch {
            self.error = error.localizedDescription
            return false
        }
        // The ledger is already saved. A reminder problem never turns a saved change into a failure.
        await syncReminders()
        return true
    }

    /// Re-reads the system's permission and re-plans from the saved ledger (foreground, settings return).
    func refreshReminders() async {
        guard loaded else { return }
        await syncReminders()
    }

    /// Parent toggled reminders. Turning them on asks the system for permission, once, from this action.
    func setReminders(enabled: Bool) async {
        guard let reminders, store.isCurrentAccount() else { return }
        var next = reminderSettings
        next.enabled = enabled
        if enabled, await reminders.authorization() == .notDetermined { _ = await reminders.requestAuthorization() }
        saveReminderSettings(next)
        await syncReminders()
    }

    func setReminderLead(_ lead: ParentingReminderLead) async {
        guard reminders != nil, store.isCurrentAccount() else { return }
        var next = reminderSettings
        next.lead = lead
        saveReminderSettings(next)
        await syncReminders()
    }

    func setReminderContentHidden(_ hidden: Bool) async {
        guard reminders != nil, store.isCurrentAccount() else { return }
        var next = reminderSettings
        next.hideContent = hidden
        saveReminderSettings(next)
        await syncReminders()
    }

    private func saveReminderSettings(_ settings: ParentingReminderSettings) {
        reminderSettings = settings
        reminderSettingsStore?.save(settings)
    }

    private func syncReminders() async {
        guard let reminders, loaded, store.isCurrentAccount() else { return }
        let status = await reminders.reconcile(workspace: workspace, settings: reminderSettings, now: clock())
        guard store.isCurrentAccount() else { return }
        reminderStatus = status
    }
}
