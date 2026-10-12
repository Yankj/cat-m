import XCTest
@testable import CatpawM

final class NativeTests: XCTestCase {
    @MainActor func testEnvironmentSaveFailureKeepsVisibleScopeAndDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawScopeTest-\(UUID())")
        // Retain this test-owned SQLite directory until the host exits; SwiftData retains handles.
        let driver = try SwiftDataPersistence(url: directory.appendingPathComponent("local.store"))
        let repo = try Repository(persistence: driver)
        let blobs = try BlobStore(root: directory.appendingPathComponent("blobs"))
        let service = WorkspaceService(repository: repo, blobs: blobs)
        let model = AppModel(repository: repo, service: service)
        model.scope = Profiles.user; model.environmentKind = .local
        await model.start()
        let c = try await service.createConversation(scope: model.scope, environment: model.environmentID, project: model.projects.first?.id, configuration: model.configuration)
        await model.refresh(); model.drafts[c] = "未发送内存草稿"; model.path = [.conversation(c)]
        driver.failNextSaveForTesting()
        do { try await model.changeEnvironment(to: .cloud); XCTFail("Scope switch must fail") } catch { }
        XCTAssertEqual(model.scope, Profiles.user); XCTAssertEqual(model.environmentKind, .local)
        XCTAssertEqual(model.drafts[c], "未发送内存草稿"); XCTAssertEqual(model.path, [.conversation(c)])
        try await model.changeEnvironment(to: .cloud)
        let original = try await repo.record(c, scope: Profiles.user)
        XCTAssertEqual(original.conversation?.draftText, "未发送内存草稿")
        XCTAssertEqual(model.scope, Profiles.inEnvironment(.cloud, profile: Profiles.user))
    }
    @MainActor func testProjectSaveFailureKeepsVisibleConversationAndDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawProjectTest-\(UUID())")
        // Retain this test-owned SQLite directory until the host exits; SwiftData retains handles.
        let driver = try SwiftDataPersistence(url: directory.appendingPathComponent("local.store"))
        let repo = try Repository(persistence: driver)
        let blobs = try BlobStore(root: directory.appendingPathComponent("blobs"))
        let service = WorkspaceService(repository: repo, blobs: blobs)
        let model = AppModel(repository: repo, service: service)
        model.scope = Profiles.user; model.environmentKind = .local; await model.start()
        let a = try await service.createConversation(scope: model.scope, environment: model.environmentID, project: model.projects.first?.id, configuration: model.configuration)
        let bProject = try await service.createProject(scope: model.scope, name: "B", environment: model.environmentID)
        await model.refresh(); model.path = [.conversation(a)]; model.drafts[a] = "A 原稿"
        driver.failNextSaveForTesting()
        do { try await model.changeProject(from: a, to: bProject); XCTFail("Project switch must fail") } catch { }
        XCTAssertEqual(model.path, [.conversation(a)]); XCTAssertEqual(model.drafts[a], "A 原稿")
        try await model.changeProject(from: a, to: bProject)
        XCTAssertNotEqual(model.path, [.conversation(a)])
        let original = try await repo.record(a, scope: model.scope)
        XCTAssertEqual(original.conversation?.draftText, "A 原稿"); XCTAssertNotEqual(original.conversation?.projectID, bProject)
    }
    func testSwiftDataFailureRollsBackAndReopens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawNativeTest-\(UUID())")
        // Retain this test-owned SQLite directory until the host exits; SwiftData retains handles.
        let url = directory.appendingPathComponent("local.store")
        let driver = try SwiftDataPersistence(url: url)
        let repo = try Repository(persistence: driver)
        let failedID = UUID(), successID = UUID()
        driver.failNextSaveForTesting()
        do { try await repo.commit(scope: Profiles.user, mutations: [.create(failedID, .preference(Preference(key: "failed", value: "no")))]); XCTFail("Save should fail") } catch { }
        try await repo.commit(scope: Profiles.user, mutations: [.create(successID, .preference(Preference(key: "saved", value: "yes")))])
        let reopened = try Repository(persistence: SwiftDataPersistence(url: url))
        let state = await reopened.read(scope: Profiles.user)
        XCTAssertNil(state.records[failedID]); XCTAssertNotNil(state.records[successID]); XCTAssertEqual(state.sequence, 1)
    }
    func testExplicitTerminalsAndEpochs() throws {
        let id = UUID(); var state = OperationReducer(operationID: id, epoch: 1)
        XCTAssertTrue(state.accept(ProviderEvent(operationID: id, sequence: 1, runtimeEpoch: 1, reality: .simulated, payload: .textDelta("partial"))))
        state.endOfStream(); XCTAssertEqual(state.messageState, .failed); XCTAssertEqual(state.taskState, .failed); XCTAssertEqual(state.text, "partial")
        state.cancel()
        XCTAssertFalse(state.accept(ProviderEvent(operationID: id, sequence: 9, runtimeEpoch: 1, reality: .simulated, payload: .messageCompleted(finalTextHash: textHash("partial"), finishReason: .stop))))
    }
    func testCSVQuotedFields() throws {
        XCTAssertEqual(try CSVParser.parse("A,B\r\n\"x,y\",\"z\"\"q\""), [["A", "B"], ["x,y", "z\"q"]])
    }
    @MainActor func testProfileSwitchDoesNotRestoreOldSettingsRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawProfileTest-\(UUID())")
        let driver = try SwiftDataPersistence(url: directory.appendingPathComponent("local.store"))
        let repo = try Repository(persistence: driver)
        let service = WorkspaceService(repository: repo, blobs: try BlobStore(root: directory.appendingPathComponent("blobs")))
        let model = AppModel(repository: repo, service: service)
        let key = "CatpawM.route.\(Profiles.user.workspaceID)"
        let originalRoute = UserDefaults.standard.data(forKey: key)
        let oldEnvironment = UserDefaults.standard.string(forKey: "CatpawM.lastEnvironment")
        defer { UserDefaults.standard.set(originalRoute, forKey: key); UserDefaults.standard.set(oldEnvironment, forKey: "CatpawM.lastEnvironment") }
        model.scope = Profiles.user; model.environmentKind = .local; await model.start()
        model.path = [.settings]; model.saveNavigation()
        try await model.changeProfile(to: true)
        XCTAssertEqual(model.scope, Profiles.demo); XCTAssertTrue(model.path.isEmpty)
        model.path = [.settings]
        try await model.changeProfile(to: false)
        XCTAssertEqual(model.scope, Profiles.user); XCTAssertTrue(model.loaded); XCTAssertTrue(model.path.isEmpty)
        XCTAssertFalse(model.switchingContext)
    }
    @MainActor func testReplyStaysInFrozenProjectDuringSwitchAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawFrozenProject-\(UUID())")
        let url = directory.appendingPathComponent("local.store")
        let repo = try Repository(persistence: SwiftDataPersistence(url: url))
        let service = WorkspaceService(repository: repo, blobs: try BlobStore(root: directory.appendingPathComponent("blobs")))
        let scope = Profiles.inEnvironment(.local, profile: DataScope(profileID: UUID(), workspaceID: UUID()))
        let model = AppModel(repository: repo, service: service); model.scope = scope; model.environmentKind = .local; await model.start()
        let environment = service.environmentID(.local, scope)
        let a = try await service.createProject(scope: scope, name: "Frozen A", environment: environment)
        let b = try await service.createProject(scope: scope, name: "Frozen B", environment: environment)
        let c = try await service.createConversation(scope: scope, environment: environment, project: a, configuration: model.configuration)
        await model.refresh(); model.path = [.conversation(c)]
        let runtime = ChatRuntime(repository: repo, service: service, provider: FixtureProvider(delayNanoseconds: 20_000_000))
        let operation = try await runtime.send(scope: scope, conversationID: c, text: "Frozen A result", clientMessageID: UUID(), scenario: .success)
        try await model.changeProject(from: c, to: b)
        XCTAssertNotEqual(model.path.last, .conversation(c))
        await runtime.awaitCompletion(operationID: operation)
        let reopened = try Repository(persistence: SwiftDataPersistence(url: url))
        let snapshot = await reopened.read(scope: scope)
        let task = try XCTUnwrap(snapshot.list("task", scope: scope).first { $0.task?.operationID == operation }?.task)
        XCTAssertEqual(task.state, .succeeded)
        let reference = try XCTUnwrap(task.results.first)
        let document = try XCTUnwrap(snapshot.records[reference.documentID]?.document)
        XCTAssertTrue(document.ownerIDs.contains(c)); XCTAssertTrue(document.ownerIDs.contains(a)); XCTAssertFalse(document.ownerIDs.contains(b))
        guard case .core(.project(let projectA)) = snapshot.records[a]?.payload, case .core(.project(let projectB)) = snapshot.records[b]?.payload else { return XCTFail("Missing projects") }
        XCTAssertTrue(projectA.documentIDs.contains(reference.documentID)); XCTAssertFalse(projectB.documentIDs.contains(reference.documentID))
        let read = try await WorkspaceService(repository: reopened, blobs: service.blobs).readDocument(scope: scope, id: reference.documentID, version: 1)
        XCTAssertEqual(bytesHash(read.1), reference.contentHash)
    }
    func testDocumentReplacementExactBytesHashAndNativeReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawReplacementTest-\(UUID())")
        let url = directory.appendingPathComponent("local.store")
        let repo = try Repository(persistence: SwiftDataPersistence(url: url))
        let blobs = try BlobStore(root: directory.appendingPathComponent("blobs"))
        let service = WorkspaceService(repository: repo, blobs: blobs)
        let scope = Profiles.inEnvironment(.local, profile: DataScope(profileID: UUID(), workspaceID: UUID()))
        try await service.bootstrap(scope: scope)
        let project = try await service.createProject(scope: scope, name: "Replacement", environment: service.environmentID(.local, scope))
        let original = "# Original fixture body\nThis text must be entirely replaced."
        let reference = try await service.createDocument(scope: scope, title: "replacement.md", mime: "text/markdown", data: Data(original.utf8), owners: [project], source: "local")
        let replacement = "# 全文替换 🐾\nOnly this revision remains.\n第二行中文。"
        let revised = try await service.editDocument(scope: scope, id: reference.documentID, expectedVersion: 1, text: replacement)
        XCTAssertEqual(revised.version, 2); XCTAssertEqual(revised.contentHash, textHash(replacement))
        let reopened = try Repository(persistence: SwiftDataPersistence(url: url))
        let reopenedService = WorkspaceService(repository: reopened, blobs: blobs)
        let read = try await reopenedService.readDocument(scope: scope, id: reference.documentID, version: 2)
        XCTAssertEqual(read.0, revised); XCTAssertEqual(read.1, Data(replacement.utf8))
        let old = try await reopenedService.readDocument(scope: scope, id: reference.documentID, version: 1)
        XCTAssertEqual(old.1, Data(original.utf8))
    }
}

// Integrate into CatpawMTests (iOS, Debug). Six cases passed on iOS Simulator 27.0.
// Uses native SwiftData and UUID-owned temporary files; never opens the app's store.
#if os(iOS)
import XCTest
@testable import CatpawM

final class NativeAcceptanceTests: XCTestCase {
    override func setUpWithError() throws {
        executionTimeAllowance = 30
        continueAfterFailure = false
    }
    private struct Harness {
        let directory: URL
        let storeURL: URL
        let scope: DataScope
        let repository: Repository
        let blobs: BlobStore
        let service: WorkspaceService
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawIndependentAcceptance-\(UUID())", isDirectory: true)
            storeURL = directory.appendingPathComponent("acceptance.store")
            scope = Profiles.inEnvironment(.local, profile: DataScope(profileID: UUID(), workspaceID: UUID()))
            repository = try Repository(persistence: SwiftDataPersistence(url: storeURL))
            blobs = try BlobStore(root: directory.appendingPathComponent("blobs"))
            service = WorkspaceService(repository: repository, blobs: blobs)
        }
        func reopened() throws -> Repository {
            try Repository(persistence: SwiftDataPersistence(url: storeURL))
        }
        // Retain the UUID-owned store until the test host exits. SwiftData can retain open FDs
        // after a local reference goes out of scope; unlinking here corrupts test-only handles.
    }

    // N01: persisted UI-model lifecycle, distinct project drafts, then environment round trip.
    @MainActor func testProjectAndEnvironmentDraftRoundTripReopensNativeStore() async throws {
        let h = try Harness()
        let previousEnvironment = UserDefaults.standard.object(forKey: "CatpawM.lastEnvironment")
        defer {
            if let previousEnvironment { UserDefaults.standard.set(previousEnvironment, forKey: "CatpawM.lastEnvironment") }
            else { UserDefaults.standard.removeObject(forKey: "CatpawM.lastEnvironment") }
        }
        let model = AppModel(repository: h.repository, service: h.service)
        model.scope = h.scope; model.environmentKind = .local
        await model.start(); XCTAssertTrue(model.loaded)
        let projectA = try XCTUnwrap(model.projects.first?.id)
        let projectB = try await h.service.createProject(scope: h.scope, name: "验收项目乙", environment: model.environmentID)
        let a = try await h.service.createConversation(scope: h.scope, environment: model.environmentID, project: projectA, configuration: model.configuration)
        await model.refresh(); model.path = [.conversation(a)]
        let textA = "甲项目：尚未发送\n中文长句与 emoji 🐈，引号\"甲\"。"
        let textB = "乙项目：另一份草稿\n第二行保持。"
        model.editDraft(a, text: textA)
        try await model.changeProject(from: a, to: projectB)
        guard case .some(.conversation(let b)) = model.path.last else { return XCTFail("Project change must open a conversation") }
        XCTAssertNotEqual(a, b); XCTAssertEqual(model.drafts[b], "")
        model.editDraft(b, text: textB)
        try await model.changeProject(from: b, to: projectA)
        XCTAssertEqual(model.path.last, .conversation(a)); XCTAssertEqual(model.drafts[a], textA)
        try await model.changeEnvironment(to: .cloud)
        let cloudScope = model.scope
        XCTAssertNil(model.record(a)); XCTAssertFalse(model.drafts.keys.contains(a))
        let cloudID = try await h.service.createConversation(scope: cloudScope, environment: model.environmentID, project: model.projects.first?.id, configuration: model.configuration)
        await model.refresh(); model.editDraft(cloudID, text: "云端本地分区草稿")
        try await model.changeEnvironment(to: .local)
        XCTAssertEqual(model.scope, h.scope)
        XCTAssertEqual(model.drafts[a], textA); XCTAssertEqual(model.drafts[b], textB)
        XCTAssertNil(model.record(cloudID))
        await model.suspend()
        let reopened = try h.reopened()
        let storedA = try await reopened.record(a, scope: h.scope)
        let storedB = try await reopened.record(b, scope: h.scope)
        let storedCloud = try await reopened.record(cloudID, scope: cloudScope)
        XCTAssertEqual(storedA.conversation?.draftText, textA)
        XCTAssertEqual(storedB.conversation?.draftText, textB)
        XCTAssertEqual(storedCloud.conversation?.draftText, "云端本地分区草稿")
        XCTAssertEqual(storedA.conversation?.projectID, projectA)
        XCTAssertEqual(storedB.conversation?.projectID, projectB)
    }

    // N02: two button commands in the same MainActor turn; later typing must survive admission.
    @MainActor func testRapidSendKeepsOneUserMessageAndLaterComposerText() async throws {
        let h = try Harness()
        let model = AppModel(repository: h.repository, service: h.service)
        model.scope = h.scope; model.environmentKind = .local; await model.start()
        let c = try await h.service.createConversation(scope: h.scope, environment: model.environmentID, project: model.projects.first?.id, configuration: model.configuration)
        await model.refresh(); model.editDraft(c, text: "第一条提交")
        model.send(c, scenario: .success); model.send(c, scenario: .success)
        model.editDraft(c, text: "发送中继续写的新草稿，不应被清空")
        for _ in 0..<250 {
            if !model.sending.contains(c) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.sending.contains(c), "Admission did not finish within the bounded wait")
        let admitted = await h.repository.read(scope: h.scope)
        let task = try XCTUnwrap(admitted.list("task", scope: h.scope).first { $0.task?.conversationID == c }?.task)
        await model.runtime.awaitCompletion(operationID: task.operationID)
        await model.suspend()
        let reopened = try h.reopened()
        let snapshot = await reopened.read(scope: h.scope)
        let messages = snapshot.list("message", scope: h.scope).compactMap(\.message).filter { $0.conversationID == c }
        XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(snapshot.list("task", scope: h.scope).filter { $0.task?.conversationID == c }.count, 1)
        XCTAssertEqual(messages.first { $0.role == .user }?.blocks.textValue, "第一条提交")
        let saved = try await reopened.record(c, scope: h.scope)
        XCTAssertEqual(saved.conversation?.draftText, "发送中继续写的新草稿，不应被清空")
    }

    // N03: real cancel command, drained original worker, retry same operation and persisted IDs.
    func testCancelThenRetryKeepsOperationAndNativeMessageIDs() async throws {
        let h = try Harness()
        try await h.service.bootstrap(scope: h.scope)
        let env = h.service.environmentID(.local, h.scope)
        let c = try await h.service.createConversation(scope: h.scope, environment: env, project: nil, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false))
        let runtime = ChatRuntime(repository: h.repository, service: h.service)
        let client = UUID()
        let operation = try await runtime.send(scope: h.scope, conversationID: c, text: "取消后按原输入重试", clientMessageID: client, scenario: .success)
        let originalWorker = await runtime.completionForCurrentAttempt(operationID: operation)
        try await runtime.cancel(operationID: operation)
        await originalWorker?.value
        let cancelled = await h.repository.read(scope: h.scope)
        let taskRecord = try XCTUnwrap(cancelled.list("task", scope: h.scope).first { $0.task?.operationID == operation })
        XCTAssertEqual(taskRecord.task?.state, .cancelled)
        let messageIDs = Set(cancelled.list("message", scope: h.scope).filter { $0.message?.conversationID == c }.map(\.id))
        try await runtime.retry(scope: h.scope, taskID: taskRecord.id, scenario: .success)
        await runtime.awaitCompletion(operationID: operation)
        let reopened = try h.reopened(); let snapshot = await reopened.read(scope: h.scope)
        let finalTask = try await reopened.record(taskRecord.id, scope: h.scope)
        XCTAssertEqual(finalTask.task?.operationID, operation); XCTAssertEqual(finalTask.task?.state, .succeeded)
        XCTAssertEqual(finalTask.task?.results.count, 1)
        XCTAssertEqual(Set(snapshot.list("message", scope: h.scope).filter { $0.message?.conversationID == c }.map(\.id)), messageIDs)
        let ref = try XCTUnwrap(finalTask.task?.results.first)
        let data = try await h.service.readDocument(scope: h.scope, id: ref.documentID, version: ref.version).1
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("取消后按原输入重试"))
        XCTAssertEqual(bytesHash(data), ref.contentHash)
    }

    // N04: native persisted terminal records, not a repeated pure reducer test.
    func testFailureEOFAndUnknownPersistWithoutSuccessfulResults() async throws {
        let h = try Harness()
        try await h.service.bootstrap(scope: h.scope)
        let cases: [(FixtureScenario, WorkState)] = [(.failure, .failed), (.unexpectedEOF, .failed), (.unknown, .outcomeUnknown)]
        for (scenario, expected) in cases {
            let runtime = ChatRuntime(repository: h.repository, service: h.service, provider: FixtureProvider(scenario: scenario, delayNanoseconds: 0))
            let c = try await h.service.createConversation(scope: h.scope, environment: h.service.environmentID(.local, h.scope), project: nil, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false))
            let op = try await runtime.send(scope: h.scope, conversationID: c, text: "原生异常验收 \(scenario.rawValue)", clientMessageID: UUID(), scenario: scenario)
            await runtime.awaitCompletion(operationID: op)
            let reopened = try h.reopened(); let snapshot = await reopened.read(scope: h.scope)
            let task = try XCTUnwrap(snapshot.list("task", scope: h.scope).first { $0.task?.operationID == op })
            XCTAssertEqual(task.task?.state, expected); XCTAssertEqual(task.task?.results.count, 0)
            let assistant = try XCTUnwrap(snapshot.list("message", scope: h.scope).first { $0.message?.conversationID == c && $0.message?.role == .assistant }?.message)
            XCTAssertEqual(assistant.state, .failed); XCTAssertEqual(assistant.reality, .simulated)
            XCTAssertFalse(assistant.blocks.textValue.isEmpty)
            if scenario == .unknown {
                do { try await runtime.retry(scope: h.scope, taskID: task.id, scenario: .success); XCTFail("Unknown may not be retried blindly") }
                catch { XCTAssertTrue(error is CatpawError) }
            }
        }
    }

    // N05: reader lifecycle semantics with native receipts and an intentionally corrupt owned blob.
    func testVersionReadsAndCorruptFileNeverProduceFalseReadReceipt() async throws {
        let h = try Harness()
        let v1 = try await h.service.createDocument(scope: h.scope, title: "验收中文.md", mime: "text/markdown", data: Data("# 原版\n第一版正文".utf8), owners: [], source: "acceptance_local")
        try await h.service.markDocumentOpened(scope: h.scope, reference: v1)
        try await h.service.markDocumentOpened(scope: h.scope, reference: v1)
        let v2 = try await h.service.editDocument(scope: h.scope, id: v1.documentID, expectedVersion: 1, text: "# 修改版\n第二版正文")
        let reopened = try h.reopened(); let snapshot = await reopened.read(scope: h.scope)
        XCTAssertTrue(snapshot.isViewed(scope: h.scope, reference: v1)); XCTAssertFalse(snapshot.isViewed(scope: h.scope, reference: v2))
        XCTAssertEqual(snapshot.list("viewReceipt", scope: h.scope).count, 1)
        let original = try await h.service.readDocument(scope: h.scope, id: v1.documentID, version: 1)
        XCTAssertEqual(String(decoding: original.1, as: UTF8.self), "# 原版\n第一版正文")
        try Data("corrupt acceptance-only blob".utf8).write(to: h.blobs.root.appendingPathComponent(v2.contentHash), options: .atomic)
        do { _ = try await h.service.readDocument(scope: h.scope, id: v2.documentID, version: 2); XCTFail("Corrupt file must fail") }
        catch { XCTAssertTrue(error is CatpawError) }
        do { try await h.service.markDocumentOpened(scope: h.scope, reference: v2); XCTFail("Corrupt file cannot be marked viewed") }
        catch { XCTAssertTrue(error is CatpawError) }
        let after = await h.repository.read(scope: h.scope)
        XCTAssertFalse(after.isViewed(scope: h.scope, reference: v2))
        XCTAssertEqual(after.list("viewReceipt", scope: h.scope).count, 1)
    }

    // N06: native restart after pause; source revocation stays revoked through resume and replacement.
    func testPauseAndSourceRevocationSurviveNativeReopen() async throws {
        let h = try Harness()
        print("N06: bootstrap temporary native scope")
        try await h.service.bootstrap(scope: h.scope)
        let d = try await h.service.createDelegation(scope: h.scope, goal: "独立验收公开资料短稿", stop: "验收后停止")
        print("N06: delegation created")
        let sourceURL = "https://example.invalid/acceptance-source"
        try await h.service.addSource(scope: h.scope, delegationID: d, url: sourceURL)
        let sources = await h.repository.read(scope: h.scope).list("source", scope: h.scope)
        let source = try XCTUnwrap(sources.first?.id)
        try await h.service.sourcePermission(scope: h.scope, id: source, allowed: false)
        let active = try await h.repository.record(d, scope: h.scope)
        try await h.service.changeDelegation(scope: h.scope, id: d, state: .paused, expectedRevision: active.header.revision)
        print("N06: paused; reopening native store")
        let reopened = try h.reopened()
        let service = WorkspaceService(repository: reopened, blobs: h.blobs)
        let paused = try await reopened.record(d, scope: h.scope)
        XCTAssertEqual(paused.delegation?.state, .paused)
        print("N06: reopened; checking paused run rejection")
        do { _ = try await service.runDelegation(scope: h.scope, id: d); XCTFail("Paused delegation may not run") }
        catch { XCTAssertTrue(error is CatpawError) }
        try await service.changeDelegation(scope: h.scope, id: d, state: .active, expectedRevision: paused.header.revision)
        print("N06: resumed; replacing revoked source")
        try await service.replaceSource(scope: h.scope, id: source, url: "https://example.invalid/replaced")
        let revoked = try await reopened.record(source, scope: h.scope)
        guard case .source(let savedSource) = revoked.payload else { return XCTFail("Missing source") }
        XCTAssertFalse(savedSource.allowed)
        let artifactID = try await service.runDelegation(scope: h.scope, id: d)
        print("N06: new artifact produced without revoked source")
        let artifactRecord = try await reopened.record(artifactID, scope: h.scope)
        guard case .artifact(let artifact) = artifactRecord.payload else { return XCTFail("Missing artifact") }
        XCTAssertFalse(artifact.evidenceIDs.contains(source))
        let result = try await service.readDocument(scope: h.scope, id: artifact.documentReference.documentID, version: artifact.documentReference.version)
        let text = String(decoding: result.1, as: UTF8.self)
        XCTAssertFalse(text.contains(sourceURL)); XCTAssertFalse(text.contains("https://example.invalid/replaced"))
        XCTAssertTrue(text.contains("未接通")); XCTAssertEqual(artifact.documentReference.contentHash, bytesHash(result.1))
    }
}
#endif
