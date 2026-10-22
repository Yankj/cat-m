import Foundation

actor SequenceProvider: AgentProvider {
    private var scenarios: [FixtureScenario]
    private var requests: [ChatRequest] = []
    init(_ scenarios: [FixtureScenario]) { self.scenarios = scenarios }
    func received() -> [ChatRequest] { requests }
    func descriptor() async -> ProviderDescriptor { await FixtureProvider().descriptor() }
    func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { requests.append(request); let scenario = scenarios.isEmpty ? .success : scenarios.removeFirst(); return try await FixtureProvider(scenario: scenario, delayNanoseconds: 0).reply(to: request) }
    func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { try await FixtureProvider().start(request) }
    func observe(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { try await FixtureProvider().observe(operationID: operationID, context: context) }
    func cancel(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { try await FixtureProvider().cancel(operationID: operationID, context: context) }
}
actor CleanupGateProvider: AgentProvider {
    let old: AsyncGate, fresh: AsyncGate
    private var count = 0
    init(old: AsyncGate, fresh: AsyncGate) { self.old = old; self.fresh = fresh }
    func descriptor() async -> ProviderDescriptor { await FixtureProvider().descriptor() }
    func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        count += 1
        if count == 1 { await old.hold(); throw CancellationError() }
        await fresh.hold()
        return try await FixtureProvider(delayNanoseconds: 0).reply(to: request)
    }
    func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { try await FixtureProvider().start(request) }
    func observe(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { try await FixtureProvider().observe(operationID: operationID, context: context) }
    func cancel(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { try await FixtureProvider().cancel(operationID: operationID, context: context) }
}

@MainActor final class QueuedAudioNotificationSource: AudioNotificationSource {
    private var callbacks: [UUID: @MainActor (AudioNotificationEvent) -> Void] = [:]
    private(set) var active: Set<UUID> = []
    private(set) var latest: UUID?
    func observe(_ receive: @escaping @MainActor (AudioNotificationEvent) -> Void) -> UUID { let id = UUID(); callbacks[id] = receive; active.insert(id); latest = id; return id }
    func remove(_ observation: UUID) { active.remove(observation) }
    // Deliberately retain delivery already queued before remove; this models the race, not the OS.
    func deliverQueued(_ observation: UUID, _ event: AudioNotificationEvent) { callbacks[observation]?(event) }
}

enum ProductRegression {
    @MainActor static func runAudioNotifications() throws -> Int {
        var passed = 0
        func check(_ value: Bool, _ label: String) throws { guard value else { throw catError.invalid("FAIL: \(label)") }; passed += 1; print("PASS \(label)") }
        let source = QueuedAudioNotificationSource()
        var voice = VoiceGuard(), interruptions = 0
        let notifications = AudioSessionNotifications(source: source) { interruptions += 1; voice.abort(); voice.stopPlayback() }
        notifications.begin(); let oldID = source.latest!, oldGeneration = notifications.generation
        try check(source.active == [oldID], "R9 registration belongs to one active audio session")
        notifications.end()
        try check(source.active.isEmpty, "R9 stopping session removes native-source observation token")
        let newCapture = voice.startCapture(); _ = voice.receive("new session transcript", epoch: newCapture, revision: 1)
        notifications.begin(); let newID = source.latest!
        try check(newID != oldID && notifications.generation != oldGeneration && source.active == [newID], "R9 restarted session captures a new registration generation")
        source.deliverQueued(oldID, .interruption(began: true)); source.deliverQueued(oldID, .routeChanged(reason: 2)); source.deliverQueued(oldID, .routeChanged(reason: 7))
        try check(interruptions == 0 && voice.capturing && voice.text == "new session transcript", "R9 queued old interruption and unplug cannot stop new session")
        source.deliverQueued(newID, .routeChanged(reason: 3)); source.deliverQueued(newID, .interruption(began: false))
        try check(interruptions == 0 && source.active == [newID] && voice.capturing, "R9 current category change and ended notification preserve capture")
        source.deliverQueued(newID, .routeChanged(reason: 7))
        try check(interruptions == 1 && !voice.capturing && source.active.isEmpty, "R9 current no-route stops and revokes registration")
        let stoppedGeneration = notifications.generation
        source.deliverQueued(newID, .interruption(began: false)); source.deliverQueued(newID, .interruption(began: true))
        try check(interruptions == 1 && notifications.generation == stoppedGeneration && source.active.isEmpty, "R9 late callbacks after stop never restart or interrupt again")
        notifications.begin(); let thirdID = source.latest!
        source.deliverQueued(thirdID, .interruption(began: true))
        try check(interruptions == 2 && source.active.isEmpty, "R9 new current interruption began still stops")
        notifications.begin(); let fourthID = source.latest!
        source.deliverQueued(fourthID, .routeChanged(reason: 2))
        try check(interruptions == 3 && source.active.isEmpty, "R9 new current unplug still stops")
        return passed
    }
    static func runLocalization() throws -> Int {
        var passed = 0
        func check(_ value: Bool, _ label: String) throws { guard value else { throw catError.invalid("FAIL: \(label)") }; passed += 1; print("PASS \(label)") }
        let url = URL(fileURLWithPath: "Resources/UIStrings.json")
        let catalog = try UICatalog(data: Data(contentsOf: url))
        try check(catalog.entries.count >= 401 && catalog.entries.values.allSatisfy { Set($0.keys) == ["zh-Hans", "en"] && !$0.values.contains(where: { $0.isEmpty }) }, "L10 UI resources retain baseline and have nonempty Chinese and English values")
        let han = try NSRegularExpression(pattern: "[\u{3400}-\u{9fff}]")
        try check(catalog.entries.values.allSatisfy { han.firstMatch(in: $0["en"]!, range: NSRange($0["en"]!.startIndex..., in: $0["en"]!)) == nil }, "L10 English interface resources contain no untranslated Chinese")
        let placeholders = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func tokens(_ text: String) -> [String] { placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted() }
        try check(catalog.entries.values.allSatisfy { tokens($0["en"]!) == tokens($0["zh-Hans"]!) }, "L10 all bilingual interpolation placeholders agree")
        try check(catalog.text("进度 {0}/{1}", language: .english, arguments: ["2", "5"]) == "Progress 2/5" && catalog.text("进度 {0}/{1}", language: .chinese, arguments: ["2", "5"]) == "进度 2/5", "L10 dynamic labels select requested language and preserve numbers")
        try check(catalog.text("目的地：{0}", language: .english, arguments: ["private-{1}-中文"]) == "Destination: private-{1}-中文", "L10 interpolation does not translate or reinterpret inserted content")
        let original = "用户文档正文，保持原样"
        try check(catalog.text(original, language: .english) == original, "L10 unregistered user or source content stays unchanged")
        try check(AppLanguage(locale: Locale(identifier: "en_US")) == .english && AppLanguage(locale: Locale(identifier: "zh_Hans_CN")) == .chinese, "L10 locale routes English and Chinese interface selection")
        try check(UIStrings.catalog.entries.count >= 401 && AppLanguage.english.ui("设置") == "Settings", "L10 staged executable bundle loads actual UI resource")
        return passed
    }
    static func run(root: URL) async throws -> Int {
        var passed = 0
        func check(_ value: Bool, _ label: String) throws { guard value else { throw catError.invalid("FAIL: \(label)") }; passed += 1; print("PASS \(label)") }
        func rejects(_ label: String, _ body: () async throws -> Void) async throws { do { try await body() } catch { try check(true, label); return }; throw catError.invalid("FAIL: \(label) expected rejection") }
        let driver = FailingPersistence(root.appendingPathComponent("product-regression.json"))
        let repo = try Repository(persistence: driver)
        let blobs = try BlobStore(root: root.appendingPathComponent("product-blobs"))
        let service = WorkspaceService(repository: repo, blobs: blobs)
        let local = Profiles.user, cloud = Profiles.inEnvironment(.cloud, profile: local), computer = Profiles.inEnvironment(.computer, profile: local)
        for scope in [local, cloud, computer, Profiles.demo] { try await service.bootstrap(scope: scope) }
        let env = service.environmentID(.local, local), project = stableID("\(local.profileID)-local-default-project")
        let conversation = try await service.createConversation(scope: local, environment: env, project: project, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false))
        try await service.preference(scope: cloud, key: "theme", value: "light")
        try await service.preference(scope: computer, key: "language", value: "en")
        try await service.preference(scope: local, key: "subagents", value: "true")
        for scope in [local, cloud, computer] {
            let prefs = await repo.profilePreferences(profileID: scope.profileID)
            try check(prefs["theme"] == "light" && prefs["language"] == "en" && prefs["subagents"] == "true", "A1 profile preferences shared in \(scope.workspaceID)")
        }
        let demoPrefs = await repo.profilePreferences(profileID: Profiles.demo.profileID)
        try check(demoPrefs.isEmpty, "A1 preferences isolated across profiles")
        let configRecord = try await repo.record(stableID("config-\(conversation)"), scope: local)
        guard case .preference(let configText) = configRecord.payload else { throw catError.missing }
        let oldConfig = try JSONDecoder().decode(ConversationConfiguration.self, from: Data(configText.value.utf8))
        try check(!oldConfig.subagents, "A1 existing conversation ignores new Subagents default")
        let canonical = await repo.read(scope: ProfilePreferences.scope(local.profileID))
        let cloudSnapshot = await repo.read(scope: cloud)
        try check(canonical.list("preference", scope: ProfilePreferences.scope(local.profileID)).count == 3 && !cloudSnapshot.list("preference", scope: cloud).contains(where: { if case .preference(let p) = $0.payload { return p.key == "theme" }; return false }), "A1 writes use explicit profile scope")
        let observer = await repo.changes(scope: cloud, after: canonical.sequence, includeProfilePreferences: true)
        var events = observer.makeAsyncIterator()
        driver.failNext()
        try await rejects("A1 failed profile preference save") { try await service.preference(scope: computer, key: "theme", value: "dark") }
        let failedPrefs = await repo.profilePreferences(profileID: local.profileID)
        let afterFail = await repo.read(scope: local)
        try check(failedPrefs["theme"] == "light" && afterFail.sequence == canonical.sequence, "A1 failure rolls back value and sequence")
        try await service.preference(scope: cloud, key: "theme", value: "system")
        let notice = await events.next()
        try check(notice?.scope == ProfilePreferences.scope(local.profileID) && notice?.sequence == canonical.sequence + 1, "A1 workspace observer only gets durable profile event")
        let reopen = try Repository(persistence: driver)
        let persistedPrefs = await reopen.profilePreferences(profileID: local.profileID)
        try check(persistedPrefs["theme"] == "system" && persistedPrefs["language"] == "en", "A1 profile preferences survive disk restart")
        try await repo.commit(scope: local, mutations: [.create(UUID(), .preference(Preference(key: "voice_locale", value: "zh-CN")))])
        let legacyPrefs = await repo.profilePreferences(profileID: local.profileID)
        try check(legacyPrefs["voice_locale"] == "zh-CN", "A1 legacy workspace defaults read consistently without rewriting bytes")
        let unknown = DataScope(profileID: UUID(), workspaceID: UUID())
        try check(Profiles.inEnvironment(.cloud, profile: unknown).profileID == unknown.profileID, "A1 arbitrary profile never collapses into user profile")
        try await rejects("A1 unsupported language rejected") { try await service.preference(scope: local, key: "language", value: "unsupported") }

        let delegation = try await service.createDelegation(scope: local, goal: "原始目标", stop: "本周停止", requirements: "短稿保留来源")
        let artifactID = try await service.runDelegation(scope: local, id: delegation)
        let artifactRecord = try await repo.record(artifactID, scope: local)
        guard case .artifact(let artifact) = artifactRecord.payload else { throw catError.missing }
        let v1 = artifact.documentReference
        let actionID = try await service.prepareAction(scope: local, document: v1, destination: "review@example.invalid")
        let actionBefore = try await repo.record(actionID, scope: local)
        let delegationBefore = try await repo.record(delegation, scope: local)
        _ = try await service.readDocument(scope: local, id: v1.documentID, version: 1)
        let unopened = await repo.read(scope: local)
        try check(!unopened.isViewed(scope: local, reference: v1), "A2 data fetch and preparation do not mark viewed")
        let openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await service.markDocumentOpened(scope: local, reference: v1, now: openedAt)
        let viewed = await repo.read(scope: local)
        try check(viewed.isViewed(scope: local, reference: v1), "A2 explicit reader open persists version receipt")
        try check(viewed.records[artifactID]?.header.revision == artifactRecord.header.revision && viewed.records[delegation]?.header.revision == delegationBefore.header.revision && viewed.records[actionID]?.header.revision == actionBefore.header.revision, "A2 viewed does not change ready delegation or approval")
        try await service.markDocumentOpened(scope: local, reference: v1, now: openedAt.addingTimeInterval(100))
        let repeated = await repo.read(scope: local)
        guard case .viewReceipt(let receipt) = repeated.records[ViewReceipt.id(scope: local, reference: v1)]?.payload else { throw catError.missing }
        try check(receipt.openedAt == openedAt && repeated.sequence == viewed.sequence, "A2 repeated open keeps original durable receipt")
        let receiptRestart = try Repository(persistence: driver)
        let reloadedReceipt = await receiptRestart.read(scope: local)
        try check(reloadedReceipt.isViewed(scope: local, reference: v1), "A2 view receipt survives disk restart")
        let v2 = try await service.editDocument(scope: local, id: v1.documentID, expectedVersion: 1, text: "第二版独立正文")
        let unviewedV2 = await repo.read(scope: local)
        try check(unviewedV2.isViewed(scope: local, reference: v1) && !unviewedV2.isViewed(scope: local, reference: v2), "A2 v2 never inherits v1 viewed state")
        driver.failNext()
        try await rejects("A2 receipt save failure") { try await service.markDocumentOpened(scope: local, reference: v2) }
        let failedReceipt = await repo.read(scope: local)
        try check(!failedReceipt.isViewed(scope: local, reference: v2), "A2 failed save never reports viewed")
        try await rejects("A2 another profile cannot mark private version viewed") { try await service.markDocumentOpened(scope: Profiles.demo, reference: v1) }
        async let openOne: Void = service.markDocumentOpened(scope: local, reference: v2, now: openedAt)
        async let openTwo: Void = service.markDocumentOpened(scope: local, reference: v2, now: openedAt.addingTimeInterval(1))
        _ = try await (openOne, openTwo)
        let concurrentOpen = await repo.read(scope: local)
        try check(concurrentOpen.list("viewReceipt", scope: local).filter { if case .viewReceipt(let value) = $0.payload { return value.document == v2 }; return false }.count == 1, "A2 simultaneous reader opens create one receipt without error")

        let originalBody = try await service.readDocument(scope: local, id: v1.documentID, version: 1)
        let gate = AsyncGate(), gatedService = WorkspaceService(repository: repo, blobs: blobs, beforeRunPublication: { await gate.hold() })
        let inFlight = Task { try await gatedService.runDelegation(scope: local, id: delegation) }
        await gate.waitUntilEntered()
        try await service.editDelegation(scope: local, id: delegation, expectedRevision: delegationBefore.header.revision, goal: "新目标", requirements: "换成详细说明", stop: "明天停止")
        await gate.release()
        try await rejects("A3 old run cannot publish after requirements edit") { _ = try await inFlight.value }
        let changed = try await repo.record(delegation, scope: local)
        try check(changed.header.revision == delegationBefore.header.revision + 1 && changed.delegation?.goal == "新目标" && changed.delegation?.stopConditions == ["明天停止"], "A3 goal stop and requirement revision persist")
        try check(DelegationRequirements.decode(changed.delegation!.scopeJSON).requirements == "换成详细说明", "A3 requirements saved in delegation scope")
        let unchangedBody = try await service.readDocument(scope: local, id: v1.documentID, version: 1)
        try check(unchangedBody.1 == originalBody.1 && String(data: unchangedBody.1, encoding: .utf8)!.contains("短稿保留来源"), "A3 old artifact retains frozen requirement body")
        try await rejects("A3 stale editor revision rejected") { try await service.editDelegation(scope: local, id: delegation, expectedRevision: delegationBefore.header.revision, goal: "旧编辑", requirements: "", stop: "停止") }
        driver.failNext()
        try await rejects("A3 edit save failure") { try await service.editDelegation(scope: local, id: delegation, expectedRevision: changed.header.revision, goal: "失败目标", requirements: "", stop: "停止") }
        let afterEditFailure = try await repo.record(delegation, scope: local)
        try check(afterEditFailure.header.revision == changed.header.revision && afterEditFailure.delegation?.goal == "新目标", "A3 failure rolls back agreement without touching artifacts")
        var withUnknownScope = afterEditFailure.delegation!
        withUnknownScope.scopeJSON = Data("{\"delivery\":\"in_app\",\"cross_task_memory\":false,\"source_policy\":{\"allow_new_sources\":false},\"requirements\":\"旧要求\"}".utf8)
        try await repo.commit(scope: local, mutations: [.update(delegation, afterEditFailure.header.revision, .delegation(withUnknownScope))])
        let withUnknownRecord = try await repo.record(delegation, scope: local)
        try await service.editDelegation(scope: local, id: delegation, expectedRevision: withUnknownRecord.header.revision, goal: "新目标", requirements: "仅改要求", stop: "明天停止")
        let preservedScope = try await repo.record(delegation, scope: local)
        let scopeObject = try JSONSerialization.jsonObject(with: preservedScope.delegation!.scopeJSON) as! [String: Any]
        try check((scopeObject["source_policy"] as? [String: Bool])?["allow_new_sources"] == false && scopeObject["cross_task_memory"] as? Bool == false, "A3 editing requirements preserves unknown scope and authorization fields")

        let dataExpertID = UUID(), designSkillID = UUID()
        try await repo.commit(scope: local, mutations: [
            .create(dataExpertID, .core(.expert(Expert(name: "Data expert", summary: "automation analysis", configurationJSON: Data("{\"categoryID\":\"data\"}".utf8), preset: true, configurationRevision: 1)))),
            .create(designSkillID, .core(.skill(Skill(name: "Design skill", summary: "automation drawing", definitionJSON: Data("{\"categoryID\":\"design\"}".utf8), version: "1", enabledScopeIDs: []))))
        ])
        let dataExpert = try await repo.record(dataExpertID, scope: local), designSkill = try await repo.record(designSkillID, scope: local)
        try check(CatalogFilter.matches(dataExpert, category: .data, query: "AUTO") && !CatalogFilter.matches(dataExpert, category: .office, query: "AUTO"), "A4 actual expert metadata combines category and case insensitive query")
        try check(CatalogFilter.matches(designSkill, category: .design, query: " drawing ") && !CatalogFilter.matches(designSkill, category: .data, query: ""), "A4 skill category never inferred from item type")
        try check(!CatalogFilter.matches(designSkill, category: .design, query: "missing"), "A4 combined filters require both matches")
        try check(CatalogCategory.data.title(.english) == "Data analysis" && CatalogCategory.data.title(.chinese) == "数据分析", "A4 catalog labels route through persisted language enum")

        try check(try ScheduleInput.intervalCadence(" 170 ") == "interval_170h", "A5 positive interval is typed input with no arbitrary 168 hour ceiling")
        for invalid in ["0", "-1", "1.5", "letters", String(Int.max)] { try await rejects("A5 invalid interval \(invalid)") { _ = try ScheduleInput.intervalCadence(invalid) } }
        let formatter = ISO8601DateFormatter(), sunday = formatter.date(from: "2026-10-11T09:00:00Z")!
        let monday = ScheduleSpec(timezoneID: "UTC", cadence: "weekly", localHour: 8, localMinute: 0, weekdays: [1], missedRunPolicy: "skip")
        let nextMonday = try ScheduleCalculator.next(monday, after: sunday)
        try check(formatter.string(from: nextMonday) == "2026-10-12T08:00:00Z", "A5 ISO weekday 1 is Monday")
        let isoSunday = ScheduleSpec(timezoneID: "UTC", cadence: "weekly", localHour: 8, localMinute: 0, weekdays: [7], missedRunPolicy: "skip")
        let nextSunday = try ScheduleCalculator.next(isoSunday, after: sunday)
        try check(formatter.string(from: nextSunday) == "2026-10-18T08:00:00Z", "A5 ISO weekday 7 is Sunday")
        let legacy = try JSONDecoder().decode(ScheduleSpec.self, from: Data("{\"timezoneID\":\"UTC\",\"cadence\":\"weekly\",\"localHour\":8,\"localMinute\":0,\"weekdays\":[1],\"missedRunPolicy\":\"skip\"}".utf8))
        try check(try ScheduleCalculator.next(legacy, after: sunday) == nextSunday && ScheduleInput.isoWeekdays(legacy) == [7], "A5 old Calendar weekday snapshot preserves Sunday semantics")
        var malformedLegacy = legacy; malformedLegacy.weekdays = [0]
        let invalidLegacy = malformedLegacy
        try await rejects("A5 legacy invalid weekday is rejected rather than normalized") { _ = try ScheduleCalculator.next(invalidLegacy, after: sunday) }
        try await service.saveSchedule(scope: local, id: nil, revision: nil, title: "ISO Monday", spec: monday, template: ScheduleTemplate(prompt: "检查", projectID: project, environmentID: env, configuration: oldConfig))
        let scheduleRestart = try Repository(persistence: driver)
        let scheduleSnapshot = await scheduleRestart.read(scope: local)
        guard case .core(.schedule(let saved)) = scheduleSnapshot.list("schedule", scope: local).first?.payload else { throw catError.missing }
        try check(saved.schedule.weekdayConvention == "iso8601" && saved.schedule.weekdays == [1], "A5 explicit ISO convention survives persistence")
        let cancelledProvider = SequenceProvider([.cancelled, .success])
        let cancelledRuntime = ChatRuntime(repository: repo, service: service, provider: cancelledProvider)
        let cancelledClient = UUID()
        let cancelledOperation = try await cancelledRuntime.send(scope: local, conversationID: conversation, text: "provider cancels", clientMessageID: cancelledClient, scenario: .cancelled)
        await cancelledRuntime.awaitCompletion(operationID: cancelledOperation)
        let cancelledTaskID = stableID("task-\(cancelledClient)")
        let cancelledTask = try await repo.record(cancelledTaskID, scope: local)
        try check(cancelledTask.task?.state == .cancelled, "R6 provider cancelled terminal persists")
        try await cancelledRuntime.retry(scope: local, taskID: cancelledTaskID, scenario: .success)
        await cancelledRuntime.awaitCompletion(operationID: cancelledOperation)
        let retriedTask = try await repo.record(cancelledTaskID, scope: local)
        let cancelRequests = await cancelledProvider.received()
        try check(retriedTask.task?.state == .succeeded && cancelRequests.count == 2, "R6 provider cancelled worker cleans live so same task retries")
        try check(cancelRequests[0].context.runtimeEpoch != cancelRequests[1].context.runtimeEpoch, "R6 cancelled retry has distinct attempt identity")

        let failedClient = UUID(), firstProvider = SequenceProvider([.failure])
        let initialRuntime = ChatRuntime(repository: repo, service: service, provider: firstProvider)
        let failedOperation = try await initialRuntime.send(scope: local, conversationID: conversation, text: "A fails", clientMessageID: failedClient, scenario: .failure)
        await initialRuntime.awaitCompletion(operationID: failedOperation)
        let otherConversation = try await service.createConversation(scope: local, environment: env, project: project, configuration: oldConfig)
        let admissionGate = AsyncGate(), admissionSpy = SequenceProvider([.success, .success])
        let interleaved = ChatRuntime(repository: repo, service: service, provider: admissionSpy, beforeAdmissionCommit: { await admissionGate.hold() })
        let bClient = UUID()
        let bSend = Task { try await interleaved.send(scope: local, conversationID: otherConversation, text: "B remains admitted", clientMessageID: bClient, scenario: .success) }
        await admissionGate.waitUntilEntered()
        try await interleaved.retry(scope: local, taskID: stableID("task-\(failedClient)"), scenario: .success)
        await interleaved.awaitCompletion(operationID: failedOperation)
        await admissionGate.release()
        let bOperation = try await bSend.value
        await interleaved.awaitCompletion(operationID: bOperation)
        let bTask = try await repo.record(stableID("task-\(bClient)"), scope: local)
        try check(bTask.task?.state == .succeeded, "R6 retry A never invalidates gated B send admission")
        let admittedRequests = await admissionSpy.received()
        try check(admittedRequests.count == 2 && Set(admittedRequests.map(\.conversationID)) == [conversation, otherConversation], "R6 both retry A and unrelated B reach actual provider")

        let oldGate = AsyncGate(), freshGate = AsyncGate()
        let cleanupProvider = CleanupGateProvider(old: oldGate, fresh: freshGate)
        let cleanupRuntime = ChatRuntime(repository: repo, service: service, provider: cleanupProvider)
        let cleanupClient = UUID()
        let cleanupOperation = try await cleanupRuntime.send(scope: local, conversationID: otherConversation, text: "old worker exits late", clientMessageID: cleanupClient, scenario: .success)
        await oldGate.waitUntilEntered()
        let oldCompletion = await cleanupRuntime.completionForCurrentAttempt(operationID: cleanupOperation)!
        try await cleanupRuntime.cancel(operationID: cleanupOperation)
        try await cleanupRuntime.retry(scope: local, taskID: stableID("task-\(cleanupClient)"), scenario: .success)
        await freshGate.waitUntilEntered()
        await oldGate.release()
        await oldCompletion.value
        await freshGate.release()
        await cleanupRuntime.awaitCompletion(operationID: cleanupOperation)
        let freshTask = try await repo.record(stableID("task-\(cleanupClient)"), scope: local)
        try check(freshTask.task?.state == .succeeded, "R6 old worker cleanup cannot remove new retry attempt")
        let activeRequestRecord = try await repo.record(stableID("reply-request-\(cleanupOperation)"), scope: local)
        guard case .preference(let activeJSON) = activeRequestRecord.payload else { throw catError.missing }
        let activeRequest = try JSONDecoder().decode(ChatRequest.self, from: Data(activeJSON.value.utf8))
        var staleReducer = OperationReducer(operationID: cleanupOperation, epoch: activeRequest.context.runtimeEpoch - 1); staleReducer.fail("stale")
        let replySnapshot = await repo.read(scope: local)
        let assistantMessageID = replySnapshot.list("message", scope: local).first { $0.message?.replyToID == stableID("user-message-\(cleanupClient)") }!.id
        try await rejects("R6 repository rejects stale attempt publication") { try await repo.persistOperation(scope: local, messageID: assistantMessageID, taskID: freshTask.id, outcome: staleReducer) }

        var foreground = ForegroundVoiceSession()
        let voiceRuntime = ChatRuntime(repository: repo, service: service, provider: SequenceProvider([.success, .success]))
        let firstEpoch = foreground.begin(scope: local, target: .conversation(otherConversation))
        _ = foreground.receive("第一轮口述", epoch: firstEpoch, revision: 1); foreground.finish()
        let firstTurn = try foreground.submit()
        let firstOperation = try await voiceRuntime.send(scope: local, conversationID: otherConversation, text: firstTurn.transcript.submittedText, clientMessageID: firstTurn.transcript.clientMessageID, scenario: .success)
        await voiceRuntime.awaitCompletion(operationID: firstOperation)
        let secondEpoch = foreground.begin(scope: local, target: .conversation(otherConversation))
        try check(!foreground.receive("迟到的第一轮", epoch: firstEpoch, revision: 2), "A6 next voice turn rejects late previous transcript")
        _ = foreground.receive("第二轮口述", epoch: secondEpoch, revision: 1); foreground.finish()
        let secondTurn = try foreground.submit()
        try check(firstTurn.transcript.sessionID == secondTurn.transcript.sessionID && firstTurn.transcript.clientMessageID != secondTurn.transcript.clientMessageID, "A6 two foreground turns share session and have independent submissions")
        let secondOperation = try await voiceRuntime.send(scope: local, conversationID: otherConversation, text: secondTurn.transcript.submittedText, clientMessageID: secondTurn.transcript.clientMessageID, scenario: .success)
        await voiceRuntime.awaitCompletion(operationID: secondOperation)
        let voiceMessages = await repo.read(scope: local).list("message", scope: local)
        try check(voiceMessages.filter { [firstTurn.transcript.clientMessageID, secondTurn.transcript.clientMessageID].contains($0.message?.clientMessageID ?? UUID()) }.count == 2, "A6 two turns persist in same conversation through actual runtime")
        try await rejects("A6 frozen transcript cannot submit twice") { _ = try foreground.submit() }
        foreground.stopPlayback()
        try check(foreground.submittedTurns.count == 2, "A6 stop playback preserves business submissions")

        let privateDocument = try await service.createDocument(scope: local, title: "voice-private.md", mime: "text/markdown", data: Data("# 私稿\n\n原始正文".utf8), owners: [project], source: "user_import")
        let pendingAction = try await service.prepareAction(scope: local, document: privateDocument, destination: "review@example.invalid")
        let editEpoch = foreground.begin(scope: local, target: .document(privateDocument))
        _ = foreground.receive("第二段短一些", epoch: editEpoch, revision: 1); foreground.finish()
        let editTurn = try foreground.submit()
        let original = try await service.readDocument(scope: local, id: privateDocument.documentID, version: 1)
        let draft = try await FixtureVoiceRevisionAdapter().draft(turn: editTurn, original: String(data: original.1, encoding: .utf8)!)
        try check(draft.reality == .simulated && draft.text.contains("未执行真实模型改写"), "A6 voice rewrite adapter identifies deterministic fixture")
        let revised = try await service.editDocument(scope: local, id: privateDocument.documentID, expectedVersion: 1, text: draft.text, voiceTurn: editTurn, adapterID: draft.adapterID)
        let postVoice = await repo.read(scope: local)
        guard case .action(let invalidated) = postVoice.records[pendingAction]?.payload else { throw catError.missing }
        try check(revised.documentID == privateDocument.documentID && revised.version == 2 && invalidated.status == .invalidated, "A6 voice edit binds same document version and invalidates old approval")
        let duplicateRevision = try await service.editDocument(scope: local, id: privateDocument.documentID, expectedVersion: 1, text: draft.text, voiceTurn: editTurn, adapterID: draft.adapterID)
        let afterDuplicate = await repo.read(scope: local)
        try check(duplicateRevision == revised && afterDuplicate.sequence == postVoice.sequence, "A6 duplicate voice submission creates no extra version")
        try await rejects("A6 voice target cannot be redirected to other document") { _ = try await service.editDocument(scope: local, id: v1.documentID, expectedVersion: 1, text: draft.text, voiceTurn: editTurn) }
        let staleEditEpoch = foreground.begin(scope: local, target: .document(privateDocument))
        _ = foreground.receive("旧版本再改", epoch: staleEditEpoch, revision: 1); foreground.finish()
        let staleEditTurn = try foreground.submit()
        try await rejects("A6 stale same document version rejected before publication") { _ = try await service.editDocument(scope: local, id: privateDocument.documentID, expectedVersion: 1, text: draft.text, voiceTurn: staleEditTurn) }
        let editRestart = try Repository(persistence: driver)
        let editRestartSnapshot = await editRestart.read(scope: local)
        try check(editRestartSnapshot.list("voiceEdit", scope: local).count == 1 && editRestartSnapshot.records[revised.documentID]?.document?.currentVersion == 2, "A6 bound voice receipt and revision survive restart")
        let nextEditEpoch = foreground.begin(scope: local, target: .document(revised))
        _ = foreground.receive("再补一个例子", epoch: nextEditEpoch, revision: 1); foreground.finish()
        let nextEditTurn = try foreground.submit()
        let currentBody = try await service.readDocument(scope: local, id: revised.documentID, version: revised.version)
        let nextDraft = try await FixtureVoiceRevisionAdapter().draft(turn: nextEditTurn, original: String(data: currentBody.1, encoding: .utf8)!)
        let beforeVoiceFailure = await repo.read(scope: local)
        driver.failNext()
        try await rejects("A6 voice revision save failure") { _ = try await service.editDocument(scope: local, id: revised.documentID, expectedVersion: 2, text: nextDraft.text, voiceTurn: nextEditTurn, adapterID: nextDraft.adapterID) }
        let afterVoiceFailure = await repo.read(scope: local)
        try check(afterVoiceFailure.sequence == beforeVoiceFailure.sequence && afterVoiceFailure.list("voiceEdit", scope: local).count == 1 && afterVoiceFailure.records[revised.documentID]?.document?.currentVersion == 2, "A6 failed voice save publishes neither receipt nor version")
        let preferencesAfterVoice = await repo.profilePreferences(profileID: local.profileID)
        try check(preferencesAfterVoice["subagents"] == "true" && preferencesAfterVoice.keys.sorted() == legacyPrefs.keys.sorted(), "A6 temporary oral requirements never become profile preferences")

        let routeText = "完整开头\n\n中间段落\n\n完整结尾", routeReference = DocumentReference(documentID: UUID(), version: 4, contentHash: textHash(routeText))
        let full = try ReadoutRouter.make(reference: routeReference, text: routeText, sourceKind: "user_import", mode: .full)
        let summary = try ReadoutRouter.make(reference: routeReference, text: routeText, sourceKind: "user_import", mode: .summary)
        let selection = try ReadoutRouter.make(reference: routeReference, text: routeText, sourceKind: "user_import", mode: .selection, selectionIndex: 1)
        try check(full.speechText == routeText && summary.speechText == "完整开头" && selection.speechText == "中间段落", "A6 full summary and selected paragraph route exact fixed text")
        let faster = try ReadoutRouter.retime(full, rateMultiplier: 1.5, paragraph: 1)
        try check(faster.document == full.document && faster.startParagraph == 1 && faster.speechText == "中间段落\n\n完整结尾", "A6 speed change preserves fixed version and paragraph cursor")
        let tts = RecordingReadoutAdapter()
        for privatePlan in [full, summary, selection] { try await rejects("A6 private \(privatePlan.mode.rawValue) route never reaches TTS adapter") { try await tts.play(privatePlan) } }
        let privateCalls = await tts.received()
        try check(privateCalls.isEmpty, "A6 private TTS gate remains closed for every readout mode")
        let publicRef = DocumentReference(documentID: UUID(), version: 1, contentHash: textHash(PublicReadoutSample.text))
        for mode in ReadoutMode.allCases { let plan = try ReadoutRouter.make(reference: publicRef, text: PublicReadoutSample.text, sourceKind: PublicReadoutSample.sourceKind, mode: mode, rateMultiplier: 1.25); try await tts.play(plan) }
        let publicCalls = await tts.received()
        try check(publicCalls.map(\.mode) == ReadoutMode.allCases && publicCalls.allSatisfy { $0.rateMultiplier == 1.25 }, "A6 public fake TTS records explicit mode and rate")
        try await rejects("A6 stale content hash rejects readout plan") { _ = try ReadoutRouter.make(reference: routeReference, text: "换稿", sourceKind: "user_import", mode: .full) }
        try await rejects("A6 out of range paragraph rejected") { _ = try ReadoutRouter.make(reference: routeReference, text: routeText, sourceKind: "user_import", mode: .selection, selectionIndex: 10) }
        try await rejects("A6 unsupported speed rejected") { _ = try ReadoutRouter.retime(full, rateMultiplier: 2, paragraph: 0) }
        let oldSession = foreground.guardState.sessionID; foreground.end()
        try check(foreground.guardState.sessionID != oldSession && foreground.target == nil, "A6 leaving foreground invalidates session and bound target")
        passed += try await runAudioNotifications()
        passed += try runLocalization()
        return passed
    }
}
