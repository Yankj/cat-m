import Foundation
import XCTest
@testable import cat

private actor DeviceExecutorOS:ConversationDeviceEffectOSPort {
    var allowed:ConversationDeviceOSPermission = .authorized
    private var permissionRequests=0,queries=0,writes=0
    private var visible=false,lost=false
    private var beforeSubmissionGate:DeviceEffectTestGate?
    private var performGate:DeviceEffectTestGate?
    private var permissionGate:DeviceEffectTestGate?
    private var afterSubmission:(@Sendable(ConversationDeviceSubeffectKind)->Void)?
    let source:DeviceEffectApplicationFixture
    let storage:FilePersistence
    init(_ fixture:DeviceEffectDiskFixture){source=fixture.source;storage=FilePersistence(url:fixture.url)}
    func configure(permission:ConversationDeviceOSPermission = .authorized,lost:Bool=false,visible:Bool=false,performGate:DeviceEffectTestGate?=nil,permissionGate:DeviceEffectTestGate?=nil,beforeSubmissionGate:DeviceEffectTestGate?=nil,afterSubmission:(@Sendable(ConversationDeviceSubeffectKind)->Void)?=nil) {
        allowed=permission;self.lost=lost;self.visible=visible;self.performGate=performGate;self.permissionGate=permissionGate;self.beforeSubmissionGate=beforeSubmissionGate;self.afterSubmission=afterSubmission
    }
    func counts()->(requests:Int,queries:Int,writes:Int){(permissionRequests,queries,writes)}
    func permission(_ kind:ConversationDeviceSubeffectKind) async -> ConversationDeviceOSPermission {if let permissionGate {await permissionGate.pause()};return allowed}
    func requestPermissionFromUserAction(_ kind:ConversationDeviceSubeffectKind) async throws -> ConversationDeviceOSPermission {permissionRequests += 1;return allowed}
    func query(_ intent:ConversationDeviceOSIntent,knownReference:ConversationTaskActionJSON?) async throws -> ConversationDeviceOSObservation {
        queries += 1
        guard visible else {return .absent}
        return .found(try source.record(intent.kind == .calendar ? "calendar_succeeded":"succeeded").subeffects[intent.kind].receipt!.external_reference)
    }
    func perform(_ intent:ConversationDeviceOSIntent,authorization:ConversationDeviceOSWriteAuthorization) async throws -> ConversationDeviceOSObservation {
        let permit=authorization.permit
        // Named mock proves persistence ordering using the real disk snapshot.
        let snapshot=try storage.load()
        let values=snapshot.records.values.compactMap{record->String? in if case .preference(let p)=record.payload,p.key.hasPrefix("conversation_device_os:"){return p.value};return nil}
        try deviceCheck(values.contains{$0.contains(permit.dispatch.operation_id) && $0.contains("time_zone") && $0.contains(intent.effect.frozen.target.calendar_id)},"Exact OS intent must be durable before the first platform call")
        try deviceCheck(try intent.dispatch==permit.dispatch,"Only the original fresh typed permit reaches the OS port")
        if let beforeSubmissionGate {await beforeSubmissionGate.pause()}
        try authorization.withAuthorization {writes += 1}
        afterSubmission?(intent.kind)
        if let performGate {await performGate.pause()}
        if lost {throw URLError(.networkConnectionLost)}
        visible=true
        return .found(try source.record(intent.kind == .calendar ? "calendar_succeeded":"succeeded").subeffects[intent.kind].receipt!.external_reference)
    }
}

final class ConversationDeviceEffectExecutorTests:XCTestCase {
    private func executor(_ f:DeviceEffectDiskFixture,_ service:ConversationDeviceEffectService,_ os:DeviceExecutorOS,repository:Repository?=nil,clock:(@Sendable()->Date)?=nil)->ConversationDeviceEffectExecutor {
        let target=f.source.action.frozen.target,date=f.source.createdAt
        return .init(repository:repository ?? f.repository,service:service,subjectID:UUID(uuidString:f.source.reference.subjectID)!,deviceID:UUID(uuidString:target.device_id)!,environmentID:UUID(uuidString:target.environment_id)!,os:os,clock:clock ?? {date})
    }
    private func prepare(_ f:DeviceEffectDiskFixture,_ service:ConversationDeviceEffectService) async throws -> String {
        _=try await service.refresh(f.source.action)
        _=try await service.admit(f.source.action,expectedActionDigest:f.source.reference.actionDigest,executionRevision:0)
        return try await service.refresh(f.source.action).snapshotHash!
    }
    func testDefaultClosedAndPermissionDenialNeverDispatchOrRequestPermission() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os)
            _=try await deviceReject{_=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:"unused")}
            let closed=await os.counts(),before=await f.server.counters()
            XCTAssertEqual(closed.requests,0);XCTAssertEqual(closed.queries,0);XCTAssertEqual(closed.writes,0);XCTAssertEqual(before.1,0)
            let hash=try await prepare(f,service);await run.setAdmissionAllowed(true);await os.configure(permission:.denied)
            _=try await deviceReject{_=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)}
            let denied=await os.counts(),after=await f.server.counters()
            XCTAssertEqual(denied.requests,0);XCTAssertEqual(denied.writes,0);XCTAssertEqual(after.1,1,"Only the earlier explicit admission exists")
            await f.close()
        } catch {await f.close();throw error}
    }
    func testOneFreshPermitPersistsIntentBeforeOSAndRepeatedExecutionOnlyReads() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch","calendarResult"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service)
            await run.setAdmissionAllowed(true)
            let outcome=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)
            guard case .succeeded(let receipt)=outcome else {throw DeviceEffectTestFailure("Expected verified calendar observation")}
            XCTAssertEqual(receipt,try f.source.record("calendar_succeeded").subeffects.calendar.receipt)
            let again=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)
            XCTAssertEqual(again,outcome)
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,1);XCTAssertEqual(counts.requests,0);XCTAssertEqual(server.1,3)
            await f.close()
        } catch {await f.close();throw error}
    }
    func testColdUnknownAbsenceNeverRepeatsCalendarCreateThenOriginalMarkerCanResolve() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service)
            await os.configure(lost:true);await run.setAdmissionAllowed(true)
            let first=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)
            XCTAssertEqual(first,.unknown);await run.invalidate();await service.invalidate()
            let repository=try Repository(persistence:FilePersistence(url:f.url)),ids=try f.source.operationIDs(["calendarResult"]),date=f.source.createdAt
            let coldService=ConversationDeviceEffectService(repository:repository,subjectID:UUID(uuidString:f.source.reference.subjectID)!,backend:f.backend,clock:{date},operationID:{ids.next()})
            await coldService.setAdmissionAllowed(true)
            let cold=executor(f,coldService,os,repository:repository);await cold.setAdmissionAllowed(true)
            let missing=try await cold.recover(f.source.action,subeffect:.calendar)
            XCTAssertEqual(missing,.unknown)
            let absentCounts=await os.counts(),absentServer=await f.server.counters()
            XCTAssertEqual(absentCounts.writes,1);XCTAssertEqual(absentServer.1,2,"Unknown absence sends no second dispatch or result")
            await os.configure(visible:true)
            let found=try await cold.recover(f.source.action,subeffect:.calendar)
            guard case .succeeded=found else {throw DeviceEffectTestFailure("Original marker must reconcile")}
            let finalCounts=await os.counts(),finalServer=await f.server.counters()
            XCTAssertEqual(finalCounts.writes,1);XCTAssertEqual(finalServer.1,3,"Only the original observation result is delivered")
            await f.close()
        } catch {await f.close();throw error}
    }
    func testLostDispatchReplyRecoveryCanQueryButCannotManufactureOSWritePermit() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service)
            await run.setAdmissionAllowed(true);await f.server.configure(lost:"dispatches")
            _=try await deviceReject{_=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)}
            await f.server.configure();await f.server.setCurrent("calendar_replay")
            let outcome=try await run.recover(f.source.action,subeffect:.calendar)
            XCTAssertEqual(outcome,.unknown)
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,0);XCTAssertEqual(counts.queries,1);XCTAssertEqual(server.1,2)
            await f.close()
        } catch {await f.close();throw error}
    }
    func testNotificationCannotDispatchUntilOriginalCalendarSucceeded() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service)
            await run.setAdmissionAllowed(true)
            _=try await deviceReject{_=try await run.execute(f.source.action,subeffect:.notification,expectedSnapshotHash:hash)}
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,0);XCTAssertEqual(counts.queries,0);XCTAssertEqual(server.1,1)
            await f.close()
        } catch {await f.close();throw error}
    }
    func testLatePermissionReadAfterLogoutCannotDispatch() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service),gate=DeviceEffectTestGate()
            await os.configure(permissionGate:gate);await run.setAdmissionAllowed(true)
            let task=Task{try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)}
            try await gate.waitForStart();await run.invalidate();await gate.release()
            _=try await deviceReject{_=try await task.value}
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,0);XCTAssertEqual(server.1,1)
            await f.close()
        } catch {await f.close();throw error}
    }
    func testFinalOSSubmissionFenceRejectsAsyncCallbackAfterBackground() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service),gate=DeviceEffectTestGate()
            await os.configure(beforeSubmissionGate:gate);await run.setAdmissionAllowed(true)
            let task=Task{try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)}
            try await gate.waitForStart();await run.setAdmissionAllowed(false);await gate.release()
            _=try await deviceReject{_=try await task.value}
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,0,"A callback that passed earlier actor checks still cannot submit to the OS")
            XCTAssertEqual(server.1,2)
            await f.close()
        } catch {await f.close();throw error}
    }
    func testCalendarReceiptMustCommitBeforeKnownTimeNotificationCanExecute() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch","calendarResult","notificationDispatch","notificationResult"])
        do {
            let elapsed=DeviceEffectMonotonic(),origin=f.source.createdAt
            let os=DeviceExecutorOS(f),run=executor(f,service,os,clock:{origin.addingTimeInterval(elapsed.read())}),hash=try await prepare(f,service)
            await run.setAdmissionAllowed(true)
            let calendar=try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)
            guard case .succeeded=calendar else {throw DeviceEffectTestFailure("Calendar must finish first")}
            let next=try await service.refresh(f.source.action).snapshotHash!
            // Retained wire: both submissions t=0, lease t=15, notification
            // observation t=20. Advance only AFTER the one-use OS submission
            // fence, never before dispatch; late observation grants no new write.
            let recorded=try f.source.record("succeeded")
            let expected=try XCTUnwrap(recorded.subeffects.notification.receipt)
            let dispatched=try XCTUnwrap(ConversationTaskActionValidation.utc(try XCTUnwrap(recorded.subeffects.notification.dispatch).dispatched_at))
            let expires=try XCTUnwrap(ConversationTaskActionValidation.utc(recorded.frozen.lease_expires_at))
            let observed=try XCTUnwrap(ConversationTaskActionValidation.utc(expected.observed_at))
            XCTAssertEqual(origin,dispatched);XCTAssertLessThan(dispatched,expires)
            XCTAssertGreaterThan(observed,expires);XCTAssertEqual(elapsed.read(),0)
            let observedElapsed=observed.timeIntervalSince(origin)
            await os.configure(visible:false,afterSubmission:{kind in
                if kind == .notification {elapsed.set(observedElapsed)}
            })
            let notification=try await run.execute(f.source.action,subeffect:.notification,expectedSnapshotHash:next)
            guard case .succeeded(let receipt)=notification else {throw DeviceEffectTestFailure("Expected known-time notification observation")}
            XCTAssertEqual(receipt,expected);XCTAssertEqual(elapsed.read(),observedElapsed)
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,2);XCTAssertEqual(counts.requests,0);XCTAssertEqual(server.1,5)
            await f.close()
        } catch {await f.close();throw error}
    }
    func testLateOSCompletionAfterLogoutLeavesOriginalUnknownWithoutReceiptCommit() async throws {
        let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
        do {
            let os=DeviceExecutorOS(f),run=executor(f,service,os),hash=try await prepare(f,service),gate=DeviceEffectTestGate()
            await os.configure(performGate:gate);await run.setAdmissionAllowed(true)
            let task=Task{try await run.execute(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash)}
            try await gate.waitForStart();await run.invalidate();await service.setAdmissionAllowed(false);await gate.release()
            _=try await deviceReject{_=try await task.value}
            let snapshot=await f.repository.read(scope:Profiles.user)
            let journals=snapshot.records.values.compactMap{record->String? in if case .preference(let p)=record.payload,p.key.hasPrefix("conversation_device_os:"){return p.value};return nil}
            XCTAssertEqual(journals.count,1)
            let journal=try ConversationStrictJSON.object(Data(journals[0].utf8))
            XCTAssertNil(journal["receipt"],"Late old-account OS completion cannot publish or persist success")
            let counts=await os.counts(),server=await f.server.counters()
            XCTAssertEqual(counts.writes,1);XCTAssertEqual(server.1,2)
            await f.close()
        } catch {await f.close();throw error}
    }
}
