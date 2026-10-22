import Foundation
#if !DEVICE_EFFECT_SERVICE_PORTABLE
import XCTest
@testable import cat
#endif

private enum DeviceEffectServiceMatrix {
    struct Case {let name:String;let run:() async throws -> Void}
    static func prepare(_ fixture:DeviceEffectDiskFixture,_ service:ConversationDeviceEffectService) async throws {_=try await service.refresh(fixture.source.action);_=try await service.admit(fixture.source.action,expectedActionDigest:fixture.source.reference.actionDigest,executionRevision:0)}
    static func fresh(_ fixture:DeviceEffectDiskFixture,_ service:ConversationDeviceEffectService) async throws -> String {let state=try await service.refresh(fixture.source.action);guard let hash=state.snapshotHash else {throw DeviceEffectTestFailure("Fresh expected snapshot missing")};return hash}
    static var cases:[Case] {[
        .init(name:"first POST sees a durable exact UUID and cold lost admission only GETs") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission"])
            do {
                let storage=FilePersistence(url:f.url),expected=(f.source.raw["admission"] as! [String:Any])["operation_id"] as! String
                await f.server.configure(lost:"admissions",observer:{body in
                    let s=try storage.load()
                    let saved=s.records.values.compactMap{r->String? in if case .preference(let p)=r.payload,p.key.hasPrefix("conversation_device_effects:"){return p.value};return nil}
                    try deviceCheck(saved.count==1 && saved[0].contains(expected),"Original admission UUID durable before URLSession POST")
                    try deviceCheck(try ConversationStrictJSON.object(body)["operation_id"] as? String==expected,"Native first POST uses stored original")
                })
                _=try await service.refresh(f.source.action)
                _=try await deviceReject{_=try await service.admit(f.source.action,expectedActionDigest:f.source.reference.actionDigest,executionRevision:0)}
                try deviceCheck(try await service.localState(f.source.action).hasUnresolvedOperation,"Transport failure stays unknown")
                let reopened=try f.reopened()
                try deviceCheck(try await reopened.localState(f.source.action).capabilitiesAvailable==false,"Fresh actor cannot restore capability")
                await reopened.setAdmissionAllowed(true);_=try await reopened.refresh(f.source.action)
                let result=try await reopened.localState(f.source.action),counts=await f.server.counters()
                try deviceCheck(!result.hasUnresolvedOperation && result.operations.count==1 && !result.latest!.execution_current && counts.1==1,"Original admission read resolves without another POST")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"lost dispatch and cold 404 retain original UUID never mint or consume") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
            do {
                try await prepare(f,service);let snapshot=try await fresh(f,service),consumed=DeviceEffectCounter()
                await f.server.configure(lost:"dispatches")
                _=try await deviceReject{_=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:snapshot){_ in consumed.increment()}}
                let unknown=try await service.localState(f.source.action);try deviceCheck(unknown.hasUnresolvedOperation && consumed.count()==0,"Lost POST cannot deliver a permit")
                await f.server.setCurrent(nil)
                let reopened=try f.reopened();await reopened.setAdmissionAllowed(true)
                _=try await reopened.refresh(f.source.action)
                let missing=try await reopened.localState(f.source.action)
                try deviceCheck(missing.hasUnresolvedOperation && missing.operations.contains{$0.issue == .originalNotFound},"GET404 remains unknown with original identity")
                await f.server.setCurrent("calendar_replay");_=try await reopened.refresh(f.source.action)
                let recovered=try await reopened.localState(f.source.action)
                try deviceCheck(!recovered.hasUnresolvedOperation && recovered.operations.last?.permitConsumed==false && consumed.count()==0,"Cold GET never remints live permit")
                _=try await deviceReject{_=try await reopened.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:recovered.snapshotHash!){_ in consumed.increment()}}
                try deviceCheck(await f.server.counters().1==2 && consumed.count()==0,"No third POST or blind native consumption")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"live permit consumed once and cached applied dispatch is not restored authority") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
            do {
                try await prepare(f,service);let snapshot=try await fresh(f,service),consumed=DeviceEffectCounter()
                let applied=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:snapshot){_ in consumed.increment()}
                try deviceCheck(consumed.count()==1 && applied.operations.contains{$0.permitConsumed},"One live consumption reservation")
                let journal=try await f.journal();if case .preference(let p)=journal.payload {try deviceCheck(!p.value.contains("dispatch_permit") && !p.value.contains("leaseExpiresAt"),"Journal never serializes permit")}
                let reopened=try f.reopened();let local=try await reopened.localState(f.source.action)
                try deviceCheck(!local.capabilitiesAvailable && !local.latest!.execution_current,"Cold disk is historical only")
                await reopened.setAdmissionAllowed(true);let hash=try await fresh(f,reopened)
                _=try await deviceReject{_=try await reopened.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash){_ in consumed.increment()}}
                let counts=await f.server.counters();try deviceCheck(consumed.count()==1 && counts.1==2,"No re-consume from stored/replayed response")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"POST success then disk failure preserves unknown and never consumes") {
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-device-disk-failure-"+UUID().uuidString),storage=DeviceEffectFailingPersistence(url:folder.appendingPathComponent("local.json"))
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"],persistence:storage)
            do {
                try await prepare(f,service);let hash=try await fresh(f,service),consumed=DeviceEffectCounter()
                await f.server.configure(afterPost:{storage.setFailure(true)})
                _=try await deviceReject{_=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash){_ in consumed.increment()}}
                try deviceCheck(consumed.count()==0,"No consumption before accepted response is durable")
                storage.setFailure(false);await f.server.configure()
                let reopened=try f.reopened();await reopened.setAdmissionAllowed(true);_=try await reopened.refresh(f.source.action)
                let counts=await f.server.counters();try deviceCheck(consumed.count()==0 && counts.1==2,"Fresh disk recovery only GET")
                await f.close()
            } catch {storage.setFailure(false);await f.close();throw error}
        },
        .init(name:"logout barrier fences a late accepted response without account revival") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission"]),gate=DeviceEffectTestGate()
            do {
                _=try await service.refresh(f.source.action);await f.server.configure(gateSuffix:"admissions",gate:gate)
                let task=Task {try await service.admit(f.source.action,expectedActionDigest:f.source.reference.actionDigest,executionRevision:0)}
                try await gate.waitForStart();let before=try Data(contentsOf:f.url)
                await service.invalidate();await gate.release();_=try await deviceReject{_=try await task.value}
                try deviceCheck(try Data(contentsOf:f.url)==before,"Late response does not write after invalidation")
                let reopened=try f.reopened();try deviceCheck(try await reopened.localState(f.source.action).hasUnresolvedOperation,"Fresh same-account journal keeps original intent only")
                let foreign=ConversationDeviceEffectService(repository:f.repository,subjectID:UUID(),backend:f.backend);await foreign.setAdmissionAllowed(true)
                _=try await deviceReject{_=try await foreign.refresh(f.source.action)}
                try deviceCheck(await f.server.counters().1==1,"Another account cannot submit/acknowledge old effect")
                await f.close()
            } catch {await gate.release();await f.close();throw error}
        },
        .init(name:"conversation deletion fences late callback and never recreates source") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission"]),gate=DeviceEffectTestGate()
            do {
                _=try await service.refresh(f.source.action);await f.server.configure(gateSuffix:"admissions",gate:gate)
                let task=Task {try await service.admit(f.source.action,expectedActionDigest:f.source.reference.actionDigest,executionRevision:0)}
                try await gate.waitForStart();let source=try await f.repository.record(f.source.reference.binding.conversation_id,scope:Profiles.user)
                try await f.repository.commit(scope:Profiles.user,mutations:[.remove(source.id,source.header.revision)])
                let deleted=try Data(contentsOf:f.url);await gate.release();_=try await deviceReject{_=try await task.value}
                try deviceCheck(try Data(contentsOf:f.url)==deleted,"Deleted source cannot be resurrected by receipt")
                _=try await deviceReject{_=try await f.repository.record(source.id,scope:Profiles.user)}
                await f.close()
            } catch {await gate.release();await f.close();throw error}
        },
        .init(name:"partial unknown independently keeps calendar receipt and stop keeps late fact") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch","calendarResult","notificationDispatch","notificationUnknown","stop"]),consumed=DeviceEffectCounter()
            do {
                try await prepare(f,service);var hash=try await fresh(f,service)
                _=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash){_ in consumed.increment()}
                hash=try await fresh(f,service)
                _=try await service.recordOriginalObservation(f.source.action,subeffect:.calendar,outcome:.succeeded,receipt:f.source.record("calendar_succeeded").subeffects.calendar.receipt,expectedSnapshotHash:hash)
                hash=try await fresh(f,service)
                _=try await service.dispatch(f.source.action,subeffect:.notification,expectedSnapshotHash:hash){_ in consumed.increment()}
                hash=try await fresh(f,service)
                let partial=try await service.recordOriginalObservation(f.source.action,subeffect:.notification,outcome:.unknown,receipt:nil,expectedSnapshotHash:hash)
                try deviceCheck(partial.latest?.state == .partialUnknown && partial.latest?.subeffects.calendar.receipt != nil && partial.latest?.subeffects.notification.receipt==nil && consumed.count()==2,"Two subeffects keep separate truthful outcomes")
                hash=try await fresh(f,service);_=try await service.stop(f.source.action,expectedSnapshotHash:hash)
                await f.server.setCurrent("stopped_late_fact");let stopped=try await service.refresh(f.source.action)
                try deviceCheck(stopped.latest?.state == .stopped && stopped.latest?.subeffects.notification.state == .succeeded && !stopped.latest!.execution_current && consumed.count()==2,"Late known fact cannot undo stop or rerun")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"corrupt saved journal and changed live snapshot are rejected before POST") {
            let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
            do {
                try await prepare(f,service);let hash=try await fresh(f,service);await f.server.setCurrent("calendar_replay")
                _=try await deviceReject{_=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash){_ in throw DeviceEffectTestFailure("Unexpected live consumption")}}
                try deviceCheck(await f.server.counters().1==1,"Changed snapshot rejected before dispatch")
                let journal=try await f.journal()
                guard case .preference(let p)=journal.payload else {throw DeviceEffectTestFailure("Preference journal")}
                var raw=try ConversationStrictJSON.object(Data(p.value.utf8)),ops=raw["operations"] as! [String:[String:Any]]
                let first=ops.keys.sorted()[0];ops[first]!["requestHash"]=String(repeating:"0",count:64);raw["operations"]=ops
                let payload=Payload.preference(.init(key:p.key,value:String(decoding:try DeviceEffectApplicationFixture.json(raw),as:UTF8.self)))
                try await f.repository.commit(scope:Profiles.user,mutations:[.update(journal.id,journal.header.revision,payload)])
                let reopened=try f.reopened();await reopened.setAdmissionAllowed(true)
                _=try await deviceReject{_=try await reopened.refresh(f.source.action)}
                try deviceCheck(await f.server.counters().1==1,"Corrupt journal cannot dispatch or reconcile")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"cold disk rejects restored authority contradictory issue and rolled-back history") {
            for fault in ["cached_authority","contradictory_issue","missing_latest","rolled_back_latest","admission_consumed"] {
                let (f,service)=try await DeviceEffectDiskFixture.make(["admission","calendarDispatch"])
                do {
                    try await prepare(f,service);let hash=try await fresh(f,service)
                    _=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:hash){_ in}
                    let journal=try await f.journal()
                    guard case .preference(let p)=journal.payload else {throw DeviceEffectTestFailure("Preference journal")}
                    var raw=try ConversationStrictJSON.object(Data(p.value.utf8)),ops=raw["operations"] as! [String:[String:Any]],latest=raw["latest"] as! [String:Any]
                    let admission=(f.source.raw["admission"] as! [String:Any])["operation_id"] as! String
                    switch fault {
                    case "cached_authority":latest["execution_current"]=true;raw["latest"]=latest
                    case "contradictory_issue":ops[admission]!["issue"]="unknown"
                    case "missing_latest":raw["latest"]=NSNull()
                    case "rolled_back_latest":raw["latest"]=ops[admission]!["response"]
                    case "admission_consumed":ops[admission]!["permitConsumed"]=true
                    default:throw DeviceEffectTestFailure("Unknown corruption")
                    }
                    raw["operations"]=ops
                    let payload=Payload.preference(.init(key:p.key,value:String(decoding:try DeviceEffectApplicationFixture.json(raw),as:UTF8.self)))
                    try await f.repository.commit(scope:Profiles.user,mutations:[.update(journal.id,journal.header.revision,payload)])
                    let before=await f.server.counters(),reopened=try f.reopened();await reopened.setAdmissionAllowed(true)
                    _=try await deviceReject{_=try await reopened.refresh(f.source.action)}
                    let after=await f.server.counters()
                    try deviceCheck(before.0==after.0 && before.1==after.1 && before.2==after.2,"Invalid "+fault+" is rejected before read or POST")
                    await f.close()
                } catch {await f.close();throw error}
            }
        },
        .init(name:"runtime default is unconfigured and never persists executable admission") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let service=ConversationDeviceEffectService(repository:f.repository,subjectID:UUID(uuidString:f.source.reference.subjectID))
                await service.setAdmissionAllowed(true)
                _=try await deviceReject{_=try await service.refresh(f.source.action)}
                _=try await deviceReject{_=try await service.admit(f.source.action,expectedActionDigest:f.source.reference.actionDigest,executionRevision:0)}
                let state=try await service.localState(f.source.action),counts=await f.server.counters()
                try deviceCheck(state.latest==nil && state.operations.isEmpty && !state.capabilitiesAvailable && counts.0==0 && counts.1==0 && counts.2==0,"No default producer or execution authority")
                await f.close()
            } catch {await f.close();throw error}
        }
    ]}
}
#if DEVICE_EFFECT_SERVICE_PORTABLE
@main struct DeviceEffectServicePortableRunner {
    static func main() async throws {for test in DeviceEffectServiceMatrix.cases {do{try await test.run();print("PASS: "+test.name)}catch{print("FAIL: "+test.name+" · "+String(describing:error));throw error}};print("EVIDENCE: actual native URLSession mocked; fresh FilePersistence/Repository recovery; OS/Auth/model/SQL/live network = NOT_RUN")}
}
#else
final class ConversationDeviceEffectServiceTests:XCTestCase {
    func testDurableDeviceEffectAndActualNativeWireMatrix() async throws {for test in DeviceEffectServiceMatrix.cases {do{try await test.run()}catch{XCTFail(test.name+": "+String(describing:error));throw error}}}
}
#endif
