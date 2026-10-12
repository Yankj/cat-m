import Foundation

final class FailingPersistence: SnapshotPersistence, @unchecked Sendable {
    let base: FilePersistence
    private let lock = NSLock()
    private var failure = false
    private var failFixture = false
    init(_ url: URL) { base = FilePersistence(url: url) }
    func failNext() { lock.lock(); failure = true; lock.unlock() }
    func failNextFixtureResult() { lock.lock(); failFixture = true; lock.unlock() }
    func load() throws -> StoreSnapshot { try base.load() }
    func save(_ s: StoreSnapshot) throws {
        lock.lock(); let fail = failure; failure = false; lock.unlock()
        if fail { throw CatpawError.unavailable("injected_disk_failure") }
        let old = try base.load()
        let introducesFixture = s.records.values.contains { old.records[$0.id] == nil && $0.document?.sourceKind == "fixture" }
        lock.lock(); let failResult = failFixture && introducesFixture; if failResult { failFixture = false }; lock.unlock()
        if failResult { throw CatpawError.unavailable("injected_fixture_result_failure") }
        try base.save(s)
    }
}
actor AsyncGate {
    private var entered = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async { await withCheckedContinuation { continuation in entered = true; blocked = continuation; observers.forEach { $0.resume() }; observers = [] } }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { blocked?.resume(); blocked = nil }
}
actor SpyProvider: AgentProvider {
    private var requests: [ChatRequest] = []
    let firstFails: Bool
    init(firstFails: Bool = false) { self.firstFails = firstFails }
    func received() -> [ChatRequest] { requests }
    func descriptor() async -> ProviderDescriptor { await FixtureProvider().descriptor() }
    func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { requests.append(request); return try await FixtureProvider(scenario: firstFails && requests.count == 1 ? .failure : .success, delayNanoseconds: 0).reply(to: request) }
    func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { try await FixtureProvider().start(request) }
    func observe(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { try await FixtureProvider().observe(operationID: operationID, context: context) }
    func cancel(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { try await FixtureProvider().cancel(operationID: operationID, context: context) }
}
@main struct DomainRunner {
    static var passed = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw CatpawError.invalid("FAIL: \(name)") }
        passed += 1; print("PASS \(name)")
    }
    static func mustThrow(_ name: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { try check(true, name); return }
        throw CatpawError.invalid("FAIL: \(name) expected rejection")
    }
    static func main() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-tests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let driver = FailingPersistence(root.appendingPathComponent("store.json"))
            let repo = try Repository(persistence: driver)
            let blobs = try BlobStore(root: root.appendingPathComponent("blobs"))
            let service = WorkspaceService(repository: repo, blobs: blobs)
            try await service.bootstrap(scope: Profiles.user); try await service.bootstrap(scope: Profiles.demo)
            let env = service.environmentID(.local, Profiles.user)
            let project = stableID("\(Profiles.user.profileID)-local-default-project")
            let c = try await service.createConversation(scope: Profiles.user, environment: env, project: project, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false))
            try await service.saveDraft(scope: Profiles.user, conversationID: c, text: "未发送草稿")
            let reopened = try Repository(persistence: driver)
            let restored = try await reopened.record(c, scope: Profiles.user)
            try check(restored.conversation?.draftText == "未发送草稿", "IOS04 disk reopen restores draft and ID")
            try await mustThrow("IOS06 cross-profile read rejected") { _ = try await repo.record(c, scope: Profiles.demo) }
            let before = await repo.read(scope: Profiles.user)
            let notices = await repo.changes(scope: Profiles.user, after: before.sequence)
            var iterator = notices.makeAsyncIterator()
            let failedID = UUID(); driver.failNext()
            try await mustThrow("IOS03 injected save failure") { try await repo.commit(scope: Profiles.user, mutations: [.create(failedID, .preference(Preference(key: "failed", value: "no")))]) }
            let afterFailure = await repo.read(scope: Profiles.user)
            try check(afterFailure.records[failedID] == nil && afterFailure.sequence == before.sequence, "IOS03 failure emits no success and rolls back candidate")
            let successID = UUID(), operationID = UUID()
            let mutations: [Mutation] = [.create(successID, .preference(Preference(key: "success", value: "yes")))]
            let committed = try await repo.commit(operationID: operationID, scope: Profiles.user, mutations: mutations)
            let notice = await iterator.next()
            try check(notice?.recordIDs == [successID] && notice?.sequence == before.sequence + 1, "IOS03 subscription only sees committed record")
            let duplicate = try await repo.commit(operationID: operationID, scope: Profiles.user, mutations: mutations)
            try check(duplicate.sequence == committed.sequence, "IOS03 operation idempotency")
            let disk = try driver.load()
            try check(disk.records[failedID] == nil && disk.records[successID] != nil, "IOS03 failed insert never leaks into next save")
            try await mustThrow("IOS03 optimistic revision conflict") { try await service.rename(scope: Profiles.user, id: c, name: "冲突", expectedRevision: 1) }
            let context = ProviderContext(scope: Profiles.user, operationID: UUID(), environmentID: env, providerID: "catpaw.fixture.v1", runtimeEpoch: 1, authorizationReferences: [])
            let requestUser = UUID()
            let request = ChatRequest(context: context, conversationID: c, userMessageID: requestUser, frozenText: "测试", frozenTextHash: textHash("测试"), conversationRevision: 2, frozenConfiguration: FrozenRequestConfiguration(conversationID: c, userMessageID: requestUser, environmentID: env, projectID: project, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false), expertRevisions: [:], skillRevisions: [:]))
            for scenario in FixtureScenario.allCases {
                var reducer = OperationReducer(operationID: context.operationID, epoch: 1)
                for try await event in try await FixtureProvider(scenario: scenario, delayNanoseconds: 0).reply(to: request) { _ = reducer.accept(event) }
                reducer.endOfStream()
                let expected: WorkState = scenario == .success ? .succeeded : scenario == .cancelled ? .cancelled : scenario == .unknown ? .outcomeUnknown : .failed
                try check(reducer.taskState == expected && !reducer.text.isEmpty, "IOS08 fixture \(scenario.rawValue) explicit terminal")
            }
            var late = OperationReducer(operationID: context.operationID, epoch: 1); late.cancel()
            let accepted = late.accept(ProviderEvent(operationID: context.operationID, sequence: 999, runtimeEpoch: 1, reality: .simulated, payload: .textDelta("late")))
            try check(!accepted && late.text.isEmpty, "IOS08 cancelled epoch rejects late output")
            var forged = OperationReducer(operationID: context.operationID, epoch: 1)
            try check(!forged.accept(ProviderEvent(operationID: context.operationID, sequence: 1, runtimeEpoch: 1, reality: .remoteVerified, payload: .textDelta("forged"))), "IOS19 fixture cannot become remote verified")
            var badHash = OperationReducer(operationID: context.operationID, epoch: 1)
            _ = badHash.accept(ProviderEvent(operationID: context.operationID, sequence: 1, runtimeEpoch: 1, reality: .simulated, payload: .textDelta("partial")))
            _ = badHash.accept(ProviderEvent(operationID: context.operationID, sequence: 2, runtimeEpoch: 1, reality: .simulated, payload: .messageCompleted(finalTextHash: "invalid", finishReason: .stop)))
            badHash.endOfStream(); try check(badHash.messageState == .failed && badHash.taskState == .failed, "IOS08 wrong final hash rejected")
            let runtime = ChatRuntime(repository: repo, service: service)
            let clientID = UUID(); let start = await repo.read(scope: Profiles.user)
            let stream = await repo.changes(scope: Profiles.user, after: start.sequence)
            let op = try await runtime.send(scope: Profiles.user, conversationID: c, text: "原生首链", clientMessageID: clientID, scenario: .success)
            let op2 = try await runtime.send(scope: Profiles.user, conversationID: c, text: "原生首链", clientMessageID: clientID, scenario: .success)
            for await _ in stream {
                let s = await repo.read(scope: Profiles.user)
                if let task = s.records[stableID("task-\(clientID)")]?.task, !task.results.isEmpty { break }
            }
            let final = await repo.read(scope: Profiles.user)
            try check(op == op2 && final.list("message", scope: Profiles.user).count == 2, "M1 double submit stores one user and one assistant message")
            try check(final.records[stableID("task-\(clientID)")]?.task?.state == .succeeded, "M1 runtime commits explicit success")
            let docRef = final.records[stableID("task-\(clientID)")]!.task!.results[0]
            let (_, bytes) = try await service.readDocument(scope: Profiles.user, id: docRef.documentID, version: docRef.version)
            try check(bytesHash(bytes) == docRef.contentHash, "M1 task result reads same immutable document hash")
            let restart = try Repository(persistence: driver)
            let restartState = await restart.read(scope: Profiles.user)
            try check(restartState.list("message", scope: Profiles.user).count == 2 && restartState.records[c]?.conversation?.draftText == "", "M1 disk reopen restores ordered messages and cleared submitted draft")
            let userCount = restartState.records.count
            let cloudScope = Profiles.inEnvironment(.cloud, profile: Profiles.user)
            try await service.bootstrap(scope: cloudScope)
            let cloudEnvironment = service.environmentID(.cloud, cloudScope)
            let cloudProject = stableID("\(cloudScope.profileID)-cloud-default-project")
            let cloudConversation = try await service.createConversation(scope: cloudScope, environment: cloudEnvironment, project: cloudProject, configuration: ConversationConfiguration(model: "Pro", safety: false, subagents: true))
            try await service.saveDraft(scope: cloudScope, conversationID: cloudConversation, text: "云端视图草稿")
            let localOnly = await repo.read(scope: Profiles.user)
            try check(localOnly.records[cloudConversation] == nil && localOnly.records[c] != nil, "F02 workspace environment isolation")
            try await mustThrow("F07 foreign environment project rejected") { _ = try await service.createConversation(scope: cloudScope, environment: cloudEnvironment, project: project, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false)) }
            if case .requestConfiguration(let frozen) = localOnly.records[stableID("request-config-\(clientID)")]?.payload { try check(frozen.configuration.subagents == false && frozen.configuration.model == "Auto" && frozen.environmentID == env, "F04 F15 submitted configuration snapshot frozen") } else { throw CatpawError.invalid("missing snapshot") }
            try await service.preference(scope: Profiles.user, key: "subagents", value: "true")
            let configAfter = await repo.read(scope: Profiles.user)
            if case .requestConfiguration(let frozen) = configAfter.records[stableID("request-config-\(clientID)")]?.payload { try check(!frozen.configuration.subagents, "F15 settings changes do not rewrite old requests") }
            let csv = try CSVParser.parse("Name,Value\r\n\"A, B\",\"line1\nline2\"\r\n\"a\"\"b\",2")
            try check(csv.count == 3 && csv[1] == ["A, B", "line1\nline2"] && csv[2][0] == "a\"b", "F09 CSV quoted comma newline escaped quote")
            try await mustThrow("F09 malformed CSV rejected") { _ = try CSVParser.parse("\"unclosed") }
            let sample = try CSVParser.parse("Product,Planned,Actual,Difference\nA,3,4,1\nB,2,2,0\nC,5,6,1\nTotal,10,12,2")
            try check(sample[4] == ["Total", "10", "12", "2"], "F09 fictional screenshot values preserved")
            let iso = ISO8601DateFormatter(); let dstStart = iso.date(from: "2026-03-08T06:00:00Z")!
            let dst = ScheduleSpec(timezoneID: "America/New_York", cadence: "daily", localHour: 2, localMinute: 30, weekdays: [], missedRunPolicy: "skip")
            let next = try ScheduleCalculator.next(dst, after: dstStart)
            var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
            try check(ny.component(.hour, from: next) == 3 && ny.component(.day, from: next) == 8, "IOS09 DST nonexistent time advances to next valid time")
            let invalidWeekly = ScheduleSpec(timezoneID: "UTC", cadence: "weekly", localHour: 8, localMinute: 0, weekdays: [], missedRunPolicy: "skip")
            try await mustThrow("F12 missing weekly days rejected") { _ = try ScheduleCalculator.next(invalidWeekly, after: Date()) }
            let hourly = ScheduleSpec(timezoneID: "UTC", cadence: "interval_2h", localHour: 999, localMinute: 999, weekdays: [], missedRunPolicy: "skip")
            try check(try ScheduleCalculator.next(hourly, after: dstStart).timeIntervalSince(dstStart) == 7200, "F12 interval ignores unused calendar fields")
            let invalidInterval = ScheduleSpec(timezoneID: "UTC", cadence: "interval_0h", localHour: 0, localMinute: 0, weekdays: [], missedRunPolicy: "skip")
            try await mustThrow("F12 nonpositive interval rejected") { _ = try ScheduleCalculator.next(invalidInterval, after: Date()) }
            let daily = ScheduleSpec(timezoneID: "UTC", cadence: "daily", localHour: 8, localMinute: 0, weekdays: [], missedRunPolicy: "skip")
            let template = ScheduleTemplate(prompt: "整理日志", projectID: project, environmentID: env, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false))
            try await mustThrow("F12 empty prompt rejected") { try await service.saveSchedule(scope: Profiles.user, title: "test", spec: daily, template: ScheduleTemplate(prompt: "", projectID: project, environmentID: env, configuration: template.configuration)) }
            try await service.saveSchedule(scope: Profiles.user, title: "本地规则", spec: daily, template: template)
            var schedules = await repo.read(scope: Profiles.user).list("schedule", scope: Profiles.user)
            var schedule = schedules[0]
            if case .core(.schedule(var p)) = schedule.payload { p.nextDueAt = Date().addingTimeInterval(-60); try await repo.commit(scope: Profiles.user, mutations: [.update(schedule.id, schedule.header.revision, .core(.schedule(p)))]) }
            let skipped = try await service.claimDueSchedules(scope: Profiles.user, now: Date(), resumed: true)
            schedules = await repo.read(scope: Profiles.user).list("schedule", scope: Profiles.user); schedule = schedules[0]
            if case .core(.schedule(let p)) = schedule.payload { try check(skipped.isEmpty && p.lastLocalAttemptAt == nil, "IOS09 resume skips missed run without fake history") }
            if case .core(.schedule(var p)) = schedule.payload { p.nextDueAt = Date().addingTimeInterval(-1); try await repo.commit(scope: Profiles.user, mutations: [.update(schedule.id, schedule.header.revision, .core(.schedule(p)))]) }
            let due = try await service.claimDueSchedules(scope: Profiles.user, now: Date(), resumed: false)
            let again = try await service.claimDueSchedules(scope: Profiles.user, now: Date(), resumed: false)
            try check(due.count == 1 && again.isEmpty, "IOS09 foreground due rule claimed once")
            try await service.toggleSchedule(scope: Profiles.user, id: schedule.id)
            if case .core(.schedule(let p)) = try await repo.record(schedule.id, scope: Profiles.user).payload { try check(!p.enabled && p.nextDueAt == nil, "F11 pause persists schedule state") }
            let delegation = try await service.createDelegation(scope: Profiles.user, goal: "本周研究持续助理", stop: "主动结束")
            try await service.addSource(scope: Profiles.user, delegationID: delegation, url: "https://example.invalid/source")
            let source = await repo.read(scope: Profiles.user).list("source", scope: Profiles.user)[0]
            try await service.sourcePermission(scope: Profiles.user, id: source.id, allowed: false)
            var dr = try await repo.record(delegation, scope: Profiles.user)
            try await service.changeDelegation(scope: Profiles.user, id: delegation, state: .paused, expectedRevision: dr.header.revision)
            dr = try await repo.record(delegation, scope: Profiles.user)
            try await service.changeDelegation(scope: Profiles.user, id: delegation, state: .active, expectedRevision: dr.header.revision)
            try await service.replaceSource(scope: Profiles.user, id: source.id, url: "https://example.invalid/replacement")
            if case .source(let s) = try await repo.record(source.id, scope: Profiles.user).payload { try check(!s.allowed && s.revision == 3, "IOS12 resume and source replacement never regrant") }
            let memoryID = try await service.addMemory(scope: Profiles.user, content: "优先一手资料", scopeID: delegation, sourceMessageID: stableID("user-message-\(clientID)"))
            let artifactID = try await service.runDelegation(scope: Profiles.user, id: delegation)
            let artifactRecord = try await repo.record(artifactID, scope: Profiles.user)
            guard case .artifact(let artifact) = artifactRecord.payload else { throw CatpawError.missing }
            dr = try await repo.record(delegation, scope: Profiles.user)
            try check(dr.delegation?.state == .active, "IOS11 finished run does not end delegation")
            let oldDocument = try await service.readDocument(scope: Profiles.user, id: artifact.documentReference.documentID, version: 1)
            let memoryRecord = try await repo.record(memoryID, scope: Profiles.user)
            try await service.editMemory(scope: Profiles.user, id: memoryID, text: "先关注开发者", expectedRevision: memoryRecord.header.revision)
            let oldAgain = try await service.readDocument(scope: Profiles.user, id: artifact.documentReference.documentID, version: 1)
            try check(oldAgain.1 == oldDocument.1 && String(data: oldAgain.1, encoding: .utf8)!.contains("优先一手资料"), "IOS10 old artifact preserves preparation snapshot")
            let pending = try await service.prepareAction(scope: Profiles.user, document: artifact.documentReference, destination: "me@example.invalid")
            let newReference = try await service.editDocument(scope: Profiles.user, id: artifact.documentReference.documentID, expectedVersion: 1, text: "# 实际改稿\n新开头")
            let pendingRecord = try await repo.record(pending, scope: Profiles.user)
            if case .action(let a) = pendingRecord.payload { try check(a.status == .invalidated, "IOS12 editing invalidates old approval") }
            try await mustThrow("IOS12 old approval cannot dispatch") { try await service.approveAction(scope: Profiles.user, id: pending, expectedRevision: pendingRecord.header.revision) }
            let updatedArtifact = try await repo.record(artifactID, scope: Profiles.user)
            if case .artifact(let a) = updatedArtifact.payload { try check(a.documentReference.version == 2 && a.documentReference.contentHash == newReference.contentHash, "IOS10 modified preview and artifact version agree") }
            let sendID = try await service.prepareAction(scope: Profiles.user, document: newReference, destination: "me@example.invalid")
            let parallelPreview = try await service.prepareAction(scope: Profiles.user, document: newReference, destination: "second@example.invalid")
            let sendRecord = try await repo.record(sendID, scope: Profiles.user)
            try await service.approveAction(scope: Profiles.user, id: sendID, expectedRevision: sendRecord.header.revision)
            let competing = try await repo.record(parallelPreview, scope: Profiles.user)
            try await mustThrow("IOS12 two previews cannot both be accepted") { try await service.approveAction(scope: Profiles.user, id: parallelPreview, expectedRevision: competing.header.revision) }
            try await mustThrow("IOS12 accepted record blocks fresh send") { _ = try await service.prepareAction(scope: Profiles.user, document: newReference, destination: "new@example.invalid") }
            try await service.queryAction(scope: Profiles.user, id: sendID, unknown: true)
            let v3 = try await service.editDocument(scope: Profiles.user, id: newReference.documentID, expectedVersion: 2, text: "版本三")
            try await mustThrow("IOS12 unknown record survives edit and blocks resend") { _ = try await service.prepareAction(scope: Profiles.user, document: v3, destination: "new@example.invalid") }
            try await service.queryAction(scope: Profiles.user, id: sendID)
            if case .action(let a) = try await repo.record(sendID, scope: Profiles.user).payload { try check(a.queryCount == 2 && a.history == [.notStarted, .accepted, .unknown, .verified] && a.document.version == 2 && a.reality == .simulated, "IOS12 query preserves original operation/version/history and simulation") }
            try await service.forgetMemory(scope: Profiles.user, id: memoryID)
            if case .memory(let m) = try await repo.record(memoryID, scope: Profiles.user).payload { try check(m.status == .deleted && m.content.isEmpty && m.deletionEpoch == 1, "IOS13 forgotten memory is redacted tombstone") }
            try await mustThrow("IOS13 suppression prevents source re-extraction") { _ = try await service.addMemory(scope: Profiles.user, content: "再抽取旧来源", scopeID: delegation, sourceMessageID: stableID("user-message-\(clientID)")) }
            var voice = VoiceGuard(); let capture = voice.startCapture()
            _ = voice.receive("原识别", epoch: capture, revision: 1); voice.edit("用户改字")
            try check(!voice.receive("迟到覆盖", epoch: capture, revision: 2) && voice.text == "用户改字", "IOS16 edited transcript rejects late recognition")
            voice.finish(); let frozenTranscript = try voice.freeze(); voice.stopPlayback()
            try check(frozenTranscript.submittedText == "用户改字" && voice.text == "用户改字", "IOS17 stopping playback preserves submitted text")
            try await mustThrow("IOS16 transcript submission once") { _ = try voice.freeze() }
            let newCapture = voice.startCapture(); voice.abort()
            try check(!voice.receive("后台final", epoch: newCapture, revision: 1), "IOS17 aborted capture rejects background final")
            var independentVoice = VoiceGuard(); let independentCapture = independentVoice.startCapture(); independentVoice.stopPlayback()
            try check(independentVoice.receive("当前合法转写", epoch: independentCapture, revision: 1), "IOS17 stopping playback does not invalidate live capture")
            let cancelClient = UUID()
            let cancelOperation = try await runtime.send(scope: Profiles.user, conversationID: c, text: "取消后重试原输入", clientMessageID: cancelClient, scenario: .success)
            try await runtime.cancel(operationID: cancelOperation)
            let cancelTaskID = stableID("task-\(cancelClient)")
            try check(try await repo.record(cancelTaskID, scope: Profiles.user).task?.state == .cancelled, "F06 actual runtime cancellation commits cancelled state")
            let beforeRetry = await repo.read(scope: Profiles.user)
            let retryStream = await repo.changes(scope: Profiles.user, after: beforeRetry.sequence)
            try await runtime.retry(scope: Profiles.user, taskID: cancelTaskID, scenario: .success)
            for await _ in retryStream { if try await repo.record(cancelTaskID, scope: Profiles.user).task?.results.isEmpty == false { break } }
            let retried = await repo.read(scope: Profiles.user)
            try check(retried.records[cancelTaskID]?.task?.operationID == cancelOperation && retried.list("message", scope: Profiles.user).count == 4, "F06 retry reuses operation and user message IDs")
            try check(retried.list("preference", scope: Profiles.user).contains { if case .preference(let p) = $0.payload { return p.key == "attempt_archive:\(cancelOperation)" && p.value.contains("cancelled") }; return false }, "F06 old cancelled attempt remains in archive")
            // Independent review regressions R1-R9. Gates force interleavings; no timing-based sleeps.
            let projectB = try await service.createProject(scope: Profiles.user, name: "项目 B", environment: env)
            let beforeProjectSwitch = await repo.read(scope: Profiles.user)
            driver.failNext()
            try await mustThrow("R4 project save failure rejects context change") { _ = try await service.selectProjectConversation(scope: Profiles.user, sourceID: c, project: projectB, draft: "A 尚未发出的草稿") }
            let failedProjectSwitch = await repo.read(scope: Profiles.user)
            try check(failedProjectSwitch.sequence == beforeProjectSwitch.sequence && failedProjectSwitch.list("conversation", scope: Profiles.user).count == beforeProjectSwitch.list("conversation", scope: Profiles.user).count && failedProjectSwitch.records[c]?.conversation?.projectID == project, "R4 failure preserves A context and creates no B key")
            let b = try await service.selectProjectConversation(scope: Profiles.user, sourceID: c, project: projectB, draft: "A 尚未发出的草稿")
            let aAgain = try await service.selectProjectConversation(scope: Profiles.user, sourceID: b, project: project, draft: "B 未发草稿")
            let projectState = await repo.read(scope: Profiles.user)
            try check(b != c && aAgain == c && projectState.records[c]?.conversation?.draftText == "A 尚未发出的草稿" && projectState.records[b]?.conversation?.draftText == "B 未发草稿", "R4 A B A retains separate conversation IDs and drafts")
            try check(projectState.list("message", scope: Profiles.user).filter { $0.message?.conversationID == c }.count == 4 && projectState.list("task", scope: Profiles.user).filter { $0.task?.conversationID == c }.count == 2 && projectState.records[c]?.conversation?.projectID == project, "R4 historical messages and tasks stay in A")
            let cRecord = try await repo.record(c, scope: Profiles.user)
            try await mustThrow("R4 direct project mutation denied") { try await service.configureConversation(scope: Profiles.user, id: c, project: projectB, expert: nil, skills: [], expectedRevision: cRecord.header.revision) }
            let draftInputs = [c: "A 内存草稿", b: "B 内存草稿"]
            driver.failNext()
            try await mustThrow("R1 environment draft batch save failure") { try await repo.saveDraftsAtomically(scope: Profiles.user, drafts: draftInputs) }
            let draftFailed = await repo.read(scope: Profiles.user)
            try check(draftFailed.records[c]?.conversation?.draftText == "A 尚未发出的草稿" && draftFailed.records[b]?.conversation?.draftText == "B 未发草稿" && draftInputs[c] == "A 内存草稿", "R1 failed batch rolls back every draft and retains input snapshot")
            try await repo.saveDraftsAtomically(scope: Profiles.user, drafts: draftInputs)
            let draftReopen = try Repository(persistence: driver)
            try check(try await draftReopen.record(b, scope: Profiles.user).conversation?.draftText == "B 内存草稿", "R1 successful batch is durable before context handoff")
            let expertID = stableID("\(Profiles.user.workspaceID)-expert-document"), skillID = stableID("\(Profiles.user.workspaceID)-skill-excel")
            let spyC = try await service.createConversation(scope: Profiles.user, environment: env, project: project, expert: expertID, skills: [skillID], configuration: ConversationConfiguration(model: "Pro", safety: false, subagents: true))
            let spy = SpyProvider(firstFails: true), spyClient = UUID()
            let spyRuntime = ChatRuntime(repository: repo, service: service, provider: spy)
            let spyOperation = try await spyRuntime.send(scope: Profiles.user, conversationID: spyC, text: "冻结正文", clientMessageID: spyClient, scenario: .success)
            await spyRuntime.awaitCompletion(operationID: spyOperation)
            try await service.preference(scope: Profiles.user, key: "model", value: "Auto")
            let e = try await repo.record(expertID, scope: Profiles.user)
            try await repo.commit(scope: Profiles.user, mutations: [.update(e.id, e.header.revision, e.payload)])
            try await service.installSkill(scope: Profiles.user, id: skillID, environment: env, enabled: true)
            try await spyRuntime.retry(scope: Profiles.user, taskID: stableID("task-\(spyClient)"), scenario: .success)
            await spyRuntime.awaitCompletion(operationID: spyOperation)
            let providerRequests = await spy.received()
            try check(providerRequests.count == 2 && providerRequests.allSatisfy { $0.frozenConfiguration.projectID == project && $0.frozenConfiguration.environmentID == env && $0.frozenConfiguration.configuration.model == "Pro" && !$0.frozenConfiguration.configuration.safety && $0.frozenConfiguration.configuration.subagents && $0.frozenConfiguration.expertRevisions[expertID] == 1 && $0.frozenConfiguration.skillRevisions[skillID] == 1 }, "R2 actual provider receives frozen project model safety experts skills on retry")
            try check(providerRequests.allSatisfy { $0.frozenText == "冻结正文" && $0.frozenTextHash == textHash("冻结正文") && $0.context.operationID == spyOperation }, "R2 provider retry receives original body hash and operation ID")
            try check(providerRequests[0].context.runtimeEpoch != providerRequests[1].context.runtimeEpoch, "R6 retry gets fresh epoch so old worker cannot write into retry")
            for postCommit in [false, true] {
                let gate = AsyncGate(), stoppedSpy = SpyProvider(), stoppedClient = UUID()
                let hook: @Sendable () async -> Void = { await gate.hold() }
                let beforeHook: (@Sendable () async -> Void)? = postCommit ? nil : hook
                let afterHook: (@Sendable () async -> Void)? = postCommit ? hook : nil
                let stoppedRuntime = ChatRuntime(repository: repo, service: service, provider: stoppedSpy, beforeAdmissionCommit: beforeHook, afterAdmissionCommit: afterHook)
                let send = Task { try await stoppedRuntime.send(scope: Profiles.user, conversationID: b, text: "挂起交错", clientMessageID: stoppedClient, scenario: .success) }
                await gate.waitUntilEntered(); await stoppedRuntime.suspend(); await gate.release()
                try await mustThrow("R6 suspended \(postCommit ? "post" : "pre") commit admission rejected") { _ = try await send.value }
                let received = await stoppedSpy.received(); let stoppedState = await repo.read(scope: Profiles.user)
                try check(received.isEmpty && (postCommit ? stoppedState.records[stableID("task-\(stoppedClient)")]?.task?.state == .cancelled : stoppedState.records[stableID("task-\(stoppedClient)")] == nil), "R6 old admission never starts provider after suspend \(postCommit)")
            }
            let publicationClient = UUID(), publicationSpy = SpyProvider()
            let publicationRuntime = ChatRuntime(repository: repo, service: service, provider: publicationSpy)
            driver.failNextFixtureResult()
            let publicationOp = try await publicationRuntime.send(scope: Profiles.user, conversationID: b, text: "注入成果失败", clientMessageID: publicationClient, scenario: .success)
            await publicationRuntime.awaitCompletion(operationID: publicationOp)
            let failedPublication = try await repo.record(stableID("task-\(publicationClient)"), scope: Profiles.user)
            try check(failedPublication.task?.state == .failed && failedPublication.task?.results.isEmpty == true, "R7 result save failure leaves failed task never success without result")
            try await publicationRuntime.retry(scope: Profiles.user, taskID: failedPublication.id, scenario: .success)
            await publicationRuntime.awaitCompletion(operationID: publicationOp)
            let repairedPublication = try await repo.record(failedPublication.id, scope: Profiles.user)
            try check(repairedPublication.task?.state == .succeeded && repairedPublication.task?.results.count == 1, "R7 retry atomically publishes success and immutable result")
            for invalidation in ["forget", "pause", "source"] {
                let guardedDelegation = try await service.createDelegation(scope: Profiles.user, goal: "交错回归", stop: "停止")
                let guardedMemory = try await service.addMemory(scope: Profiles.user, content: "不得迟到发布的私有记忆", scopeID: guardedDelegation)
                try await service.addSource(scope: Profiles.user, delegationID: guardedDelegation, url: "https://example.invalid/public")
                let gate = AsyncGate()
                let guardedService = WorkspaceService(repository: repo, blobs: blobs, beforeRunPublication: { await gate.hold() })
                let run = Task { try await guardedService.runDelegation(scope: Profiles.user, id: guardedDelegation) }
                await gate.waitUntilEntered()
                if invalidation == "forget" { try await service.forgetMemory(scope: Profiles.user, id: guardedMemory) }
                else if invalidation == "pause" { let r = try await repo.record(guardedDelegation, scope: Profiles.user); try await service.changeDelegation(scope: Profiles.user, id: guardedDelegation, state: .paused, expectedRevision: r.header.revision) }
                else { let state = await repo.read(scope: Profiles.user); let source = state.list("source", scope: Profiles.user).first { if case .source(let s) = $0.payload { return s.delegationID == guardedDelegation }; return false }!; try await service.sourcePermission(scope: Profiles.user, id: source.id, allowed: false) }
                await gate.release()
                try await mustThrow("R8 \(invalidation) invalidates in-flight publication") { _ = try await run.value }
                let guardedState = await repo.read(scope: Profiles.user)
                try check(!guardedState.list("run", scope: Profiles.user).contains { if case .run(let r) = $0.payload { return r.delegationID == guardedDelegation }; return false }, "R8 no stale run or artifact after \(invalidation)")
            }
            let publicReference = DocumentReference(documentID: UUID(), version: 1, contentHash: textHash(PublicReadoutSample.text))
            try check(PublicReadoutSample.allows(reference: publicReference, sourceKind: PublicReadoutSample.sourceKind, text: PublicReadoutSample.text), "R3 exact bundled public sample may reach TTS")
            try check(!PublicReadoutSample.allows(reference: publicReference, sourceKind: "user_import", text: PublicReadoutSample.text) && !PublicReadoutSample.allows(reference: publicReference, sourceKind: "fixture", text: PublicReadoutSample.text), "R3 imported and private fixture sources denied")
            try check(!PublicReadoutSample.allows(reference: publicReference, sourceKind: PublicReadoutSample.sourceKind, text: "私有正文") && !PublicReadoutSample.allows(reference: DocumentReference(documentID: publicReference.documentID, version: 2, contentHash: publicReference.contentHash), sourceKind: PublicReadoutSample.sourceKind, text: PublicReadoutSample.text), "R3 changed body and edited version denied")
            try check(!AudioEventPolicy.shouldInterruptRoute(reason: 3, notificationEpoch: 1, currentEpoch: 1) && !AudioEventPolicy.shouldInterrupt(began: false, notificationEpoch: 1, currentEpoch: 1), "R9 own category change and interruption ended do not clear transcript")
            try check(AudioEventPolicy.shouldInterruptRoute(reason: 2, notificationEpoch: 2, currentEpoch: 2) && AudioEventPolicy.shouldInterrupt(began: true, notificationEpoch: 2, currentEpoch: 2) && !AudioEventPolicy.shouldInterruptRoute(reason: 2, notificationEpoch: 1, currentEpoch: 2), "R9 unplug and interruption began stop current epoch only")
            let orphan = try blobs.stage(Data("unreferenced stage".utf8))
            try await service.reconcileBlobsAtLaunch()
            try check(!FileManager.default.fileExists(atPath: blobs.root.appendingPathComponent(orphan).path), "IOS10 startup removes unreferenced staged blobs")
            let (_, stillReadable) = try await service.readDocument(scope: Profiles.user, id: v3.documentID, version: 1)
            try check(bytesHash(stillReadable) == artifact.documentReference.contentHash, "IOS10 reconciliation preserves all immutable versions")
            let futureURL = root.appendingPathComponent("future.json")
            var future = StoreSnapshot(); future.schemaVersion = 99
            let futureData = try JSONEncoder().encode(future); try futureData.write(to: futureURL)
            try await mustThrow("IOS05 unknown schema rejected without reset") { _ = try Repository(persistence: FilePersistence(url: futureURL)) }
            try check(try Data(contentsOf: futureURL) == futureData, "IOS05 unsupported migration preserves original bytes")
            let currentUserCount = await repo.read(scope: Profiles.user).records.count
            let linkSnapshot = await repo.read(scope: Profiles.user)
            try check(try DeepLinkResolver.resolve(URL(string: "catpawm://document/\(v3.documentID)?version=1")!, snapshot: linkSnapshot, scope: Profiles.user) == .document(v3.documentID, version: 1), "IOS07 deep link resolves exact local version")
            try await mustThrow("IOS06 deep link rejects cross workspace") { _ = try DeepLinkResolver.resolve(URL(string: "catpawm://conversation/\(cloudConversation)")!, snapshot: linkSnapshot, scope: Profiles.user) }
            try await mustThrow("IOS07 deep link rejects private content parameters") { _ = try DeepLinkResolver.resolve(URL(string: "catpawm://conversation/\(c)?token=forbidden")!, snapshot: linkSnapshot, scope: Profiles.user) }
            try await repo.resetDemo()
            let userAfterReset = await repo.read(scope: Profiles.user); let demoAfterReset = await repo.read(scope: Profiles.demo)
            try check(userAfterReset.records.count == currentUserCount && demoAfterReset.records.isEmpty && userCount > 0, "IOS06 demo reset preserves user partition")
            passed += try await ProductRegression.run(root: root)
            print("RESULT \(passed) passed, 0 failed. Portable Foundation/disk driver only; iOS/SwiftData runtime unverified.")
        } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
    }
}
