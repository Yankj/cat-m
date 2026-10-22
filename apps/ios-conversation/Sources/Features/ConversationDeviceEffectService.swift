import Foundation

public enum ConversationDeviceEffectJournalRequest:Codable,Sendable,Equatable {
    case admission(ConversationDeviceEffectAdmissionRequest),dispatch(ConversationDeviceEffectDispatchRequest),result(ConversationDeviceEffectResultRequest),stop(ConversationDeviceEffectStopRequest)
    public var operationID:String {switch self {case .admission(let r):return r.operation_id;case .dispatch(let r):return r.operation_id;case .result(let r):return r.operation_id;case .stop(let r):return r.operation_id}}
    public func body() throws -> Data {switch self {case .admission(let r):return try ConversationTaskActionJSON.encoded(r);case .dispatch(let r):return try ConversationTaskActionJSON.encoded(r);case .result(let r):return try ConversationTaskActionJSON.encoded(r);case .stop(let r):return try ConversationTaskActionJSON.encoded(r)}}
}
public struct ConversationDeviceEffectJournalOperation:Codable,Sendable,Equatable {
    public enum State:String,Codable,Sendable {case unknown,applied,notSent,rejected}
    public enum Issue:String,Codable,Sendable {case unknown,originalNotFound,notSent,rejected}
    public let request:ConversationDeviceEffectJournalRequest
    public let requestHash:String
    /// Historical exact input snapshot; it cannot restore live execution authority.
    public let base:ConversationDeviceEffectRecord?
    public let expectedSnapshotHash:String?
    public var state:State
    public var issue:Issue?
    public var response:ConversationDeviceEffectRecord?
    /// Means that the live permit was removed from circulation, not that the OS executed.
    public var permitConsumed=false
}
public struct ConversationDeviceEffectLocalState:Sendable,Equatable {
    public let latest:ConversationDeviceEffectRecord?
    public let operations:[ConversationDeviceEffectJournalOperation]
    public let capabilitiesAvailable:Bool
    public let snapshotHash:String?
    public var hasUnresolvedOperation:Bool {operations.contains{$0.state == .unknown}}
}
private struct DeviceEffectJournal:Codable {
    var schemaVersion=1
    let identity:String
    let frozen:ConversationExecutableTaskActionFrozenV2
    let decision:ConversationExecutableActionDecisionV2
    var latest:ConversationDeviceEffectRecord?
    var operations:[String:ConversationDeviceEffectJournalOperation]=[:]
}
/// Account-scoped durable intent/delivery. It never requests OS permissions or executes a system API.
/// The default backend is unavailable; cached records and fresh GET never mint a dispatch permit.
public actor ConversationDeviceEffectService {
    public nonisolated let scope:DataScope
    private let subjectID:UUID?
    private let repository:Repository
    private let backend:any ConversationDeviceEffectBackend
    private let clock:@Sendable()->Date
    private let operationID:@Sendable()->UUID
    private let monotonic:@Sendable()->TimeInterval
    private var admitted=false,invalidated=false,locked=false
    private var generation=0
    private var active:Set<String>=[]
    private struct Fresh {let available:Bool;let record:ConversationDeviceEffectRecord?}
    private var fresh:[String:Fresh]=[:]
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    public init(repository:Repository,scope:DataScope = Profiles.user,subjectID:UUID?=nil,backend:any ConversationDeviceEffectBackend = UnconfiguredConversationDeviceEffectBackend(),clock:@escaping @Sendable()->Date={Date()},operationID:@escaping @Sendable()->UUID={UUID()},monotonic:@escaping @Sendable()->TimeInterval={ProcessInfo.processInfo.systemUptime}) {
        self.repository=repository;self.scope=scope;self.subjectID=subjectID;self.backend=backend;self.clock=clock;self.operationID=operationID;self.monotonic=monotonic
    }
    public func setAdmissionAllowed(_ allowed:Bool) {if !allowed {generation += 1;fresh.removeAll()};admitted=allowed && !invalidated}
    public func invalidate() async {generation += 1;admitted=false;invalidated=true;fresh.removeAll();await lock();unlock()}
    public func localState(_ action:ConversationApprovedDeviceAction) async throws -> ConversationDeviceEffectLocalState {let (j,_)=try await load(action);return try state(j,available:false)}
    public func refresh(_ action:ConversationApprovedDeviceAction) async throws -> ConversationDeviceEffectLocalState {
        let key=try key(action.reference);try begin(key);defer{active.remove(key)}
        let epoch=generation;let (initial,_)=try await load(action);try ensure(epoch);fresh[key]=nil
        let available=try await backend.deviceEffectAvailability(action.reference);try ensure(epoch)
        var original:ConversationDeviceEffectRecord?
        do {let value=try await backend.readOriginalDeviceEffect(action.reference,action:action);try ensure(epoch);guard value.dispatchPermit==nil else {throw ConversationDeviceEffectError.invalidResponse};original=value.effect}
        catch ConversationDeviceEffectServiceError.originalNotFound {try ensure(epoch)}
        await lock();defer{unlock()};try ensure(epoch)
        var (journal,record)=try await load(action);try ensure(epoch)
        guard journal.operations==initial.operations else {throw ConversationDeviceEffectServiceError.busy}
        if let original {
            try merge(original,into:&journal)
            for (id,old) in journal.operations where old.state == .unknown {
                if matches(old.request,record:original) {journal.operations[id]?.state = .applied;journal.operations[id]?.issue=nil;journal.operations[id]?.response=historical(original)}
                // A missing original result operation is not silently inferred rejected.
            }
        } else {
            for (id,old) in journal.operations where old.state == .unknown {journal.operations[id]?.issue = .originalNotFound}
        }
        try await save(journal,record:record,action:action,epoch:epoch);try ensure(epoch)
        fresh[key]=Fresh(available:available,record:original)
        return try state(journal,available:available)
    }
    public func admit(_ action:ConversationApprovedDeviceAction,expectedActionDigest:String,executionRevision:Int) async throws -> ConversationDeviceEffectLocalState {
        let key=try key(action.reference);try begin(key);defer{active.remove(key)};let epoch=generation
        let (initial,_)=try await load(action);try ensure(epoch)
        guard fresh[key]?.available==true,expectedActionDigest==action.reference.actionDigest,initial.latest==nil,!initial.operations.values.contains(where:{$0.state != .notSent && $0.state != .rejected}),let expires=ConversationTaskActionValidation.utc(action.frozen.expires_at),expires>clock() else {throw ConversationDeviceEffectServiceError.stale}
        let request=try ConversationDeviceEffectAdmissionRequest(operationID:operationID(),reference:action.reference,action:action,executionRevision:executionRevision)
        return try await submit(action,request:.admission(request),base:nil,epoch:epoch,consume:nil)
    }
    public func dispatch(_ action:ConversationApprovedDeviceAction,subeffect:ConversationDeviceSubeffectKind,expectedSnapshotHash:String,consume:@escaping @Sendable(ConversationDeviceDispatchPermit) async throws -> Void) async throws -> ConversationDeviceEffectLocalState {
        let key=try key(action.reference);try begin(key);defer{active.remove(key)};let epoch=generation
        let base=try await current(action,expectedSnapshotHash:expectedSnapshotHash,requiresExecution:true,epoch:epoch)
        let (journal,_)=try await load(action);try ensure(epoch)
        guard !journal.operations.values.contains(where:{$0.state == .unknown}),
              !journal.operations.values.contains(where:{if case .dispatch(let r)=$0.request {return r.subeffect==subeffect && $0.state != .notSent && $0.state != .rejected};return false}),
              base.stop==nil,base.subeffects[subeffect].state == .notDispatched,
              subeffect == .calendar || (base.subeffects.calendar.state == .succeeded && base.frozen.parameters.reminder_offset_seconds != nil) else {throw ConversationDeviceEffectServiceError.busy}
        let request=try ConversationDeviceEffectDispatchRequest(operationID:operationID(),subeffect:subeffect,expectedRevision:base.revision,bindingHash:base.binding_hash,leaseID:base.frozen.lease_id)
        return try await submit(action,request:.dispatch(request),base:base,epoch:epoch,consume:consume)
    }
    public func recordOriginalObservation(_ action:ConversationApprovedDeviceAction,subeffect:ConversationDeviceSubeffectKind,outcome:ConversationDeviceSubeffectState,receipt:ConversationDeviceEffectReceipt?,expectedSnapshotHash:String) async throws -> ConversationDeviceEffectLocalState {
        let key=try key(action.reference);try begin(key);defer{active.remove(key)};let epoch=generation
        let base=try await current(action,expectedSnapshotHash:expectedSnapshotHash,requiresExecution:false,epoch:epoch)
        let (journal,_)=try await load(action);try ensure(epoch);guard !journal.operations.values.contains(where:{$0.state == .unknown}) else {throw ConversationDeviceEffectServiceError.busy}
        let request=try ConversationDeviceEffectResultRequest(operationID:operationID(),subeffect:subeffect,base:base,outcome:outcome,receipt:receipt)
        return try await submit(action,request:.result(request),base:base,epoch:epoch,consume:nil)
    }
    public func stop(_ action:ConversationApprovedDeviceAction,expectedSnapshotHash:String) async throws -> ConversationDeviceEffectLocalState {
        let key=try key(action.reference);try begin(key);defer{active.remove(key)};let epoch=generation
        let base=try await current(action,expectedSnapshotHash:expectedSnapshotHash,requiresExecution:false,epoch:epoch)
        let (journal,_)=try await load(action);try ensure(epoch);guard !journal.operations.values.contains(where:{$0.state == .unknown}) else {throw ConversationDeviceEffectServiceError.busy}
        return try await submit(action,request:.stop(try .init(operationID:operationID(),base:base)),base:base,epoch:epoch,consume:nil)
    }
    private func current(_ action:ConversationApprovedDeviceAction,expectedSnapshotHash:String,requiresExecution:Bool,epoch:Int) async throws -> ConversationDeviceEffectRecord {
        let key=try key(action.reference), (journal,_)=try await load(action);try ensure(epoch)
        guard fresh[key]?.available==true,let shown=journal.latest,try hash(shown)==expectedSnapshotHash,let live=fresh[key]?.record else {throw ConversationDeviceEffectServiceError.stale}
        let value=try await backend.readOriginalDeviceEffect(action.reference,action:action);try ensure(epoch)
        guard value.dispatchPermit==nil,value.effect==live,historical(value.effect)==shown else {fresh[key]=nil;throw ConversationDeviceEffectServiceError.stale}
        if requiresExecution {guard value.effect.execution_current,let expires=ConversationTaskActionValidation.utc(value.effect.frozen.lease_expires_at),expires>clock() else {fresh[key]=nil;throw ConversationDeviceEffectServiceError.stale}}
        return value.effect
    }
    private func submit(_ action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectJournalRequest,base:ConversationDeviceEffectRecord?,epoch:Int,consume:(@Sendable(ConversationDeviceDispatchPermit) async throws -> Void)?) async throws -> ConversationDeviceEffectLocalState {
        let key=try key(action.reference),id=request.operationID
        let op=ConversationDeviceEffectJournalOperation(request:request,requestHash:try ConversationDeviceEffectsCodec.canonicalHashJSON(request.body()),base:base.map(historical),expectedSnapshotHash:try base.map{try hash(historical($0))},state:.unknown,issue:.unknown,response:nil)
        await lock()
        do {
            try ensure(epoch);var (journal,record)=try await load(action);try ensure(epoch)
            guard journal.operations.count<64,journal.operations[id]==nil else {throw ConversationDeviceEffectServiceError.journalFull}
            journal.operations[id]=op
            // Exact original UUID/body/base is durable before any POST, including crash here.
            try await save(journal,record:record,action:action,epoch:epoch);try ensure(epoch);fresh[key]=nil;unlock()
        } catch {unlock();throw error}
        var provenNotSent=false,rejected=false
        do {
            try ensure(epoch)
            let started=monotonic()
            let response:ConversationDeviceEffectEnvelope
            do {
                switch request {
                case .admission(let r):response=try await backend.admitDeviceEffect(action.reference,action:action,request:r)
                case .dispatch(let r):response=try await backend.dispatchDeviceEffect(action.reference,action:action,request:r)
                case .result(let r):response=try await backend.recordDeviceEffectResult(action.reference,action:action,request:r)
                case .stop(let r):response=try await backend.stopDeviceEffect(action.reference,action:action,request:r)
                }
            } catch {provenNotSent=error is ConversationDeviceEffectDispatchFailure;if case catError.conflict=error {rejected=true};throw error}
            try ensure(epoch);guard matches(request,record:response.effect) else {throw ConversationDeviceEffectError.invalidResponse}
            if case .dispatch=request {} else {guard response.dispatchPermit==nil else {throw ConversationDeviceEffectError.invalidResponse}}
            await lock()
            do {
                try ensure(epoch);var (journal,record)=try await load(action);try ensure(epoch)
                guard journal.operations[id]==op else {throw ConversationDeviceEffectServiceError.invalidJournal}
                try merge(response.effect,into:&journal);journal.operations[id]?.state = .applied;journal.operations[id]?.issue=nil;journal.operations[id]?.response=historical(response.effect)
                // A restored response contains no permit. Consumption reservation does not prove an OS call.
                journal.operations[id]?.permitConsumed=response.dispatchPermit != nil
                try await save(journal,record:record,action:action,epoch:epoch);try ensure(epoch);unlock()
            } catch {unlock();throw error}
            if let permit=response.dispatchPermit {
                guard let consume,case .dispatch(let r)=request,permit.dispatch.operation_id==id,permit.dispatch.kind==r.subeffect else {throw ConversationDeviceEffectError.invalidResponse}
                let original=try await backend.readOriginalDeviceEffect(action.reference,action:action);try ensure(epoch)
                guard original.dispatchPermit==nil,original.effect.record_hash==response.effect.record_hash,original.effect.execution_current,original.effect.stop==nil,
                      let expires=ConversationTaskActionValidation.utc(permit.leaseExpiresAt),let dispatchedAt=ConversationTaskActionValidation.utc(permit.dispatch.dispatched_at),expires>clock(),
                      monotonic()>=started,monotonic()-started<expires.timeIntervalSince(dispatchedAt) else {throw ConversationDeviceEffectServiceError.stale}
                // The sole live value is consumed in this invocation; neither disk nor refresh has a path here.
                try ensure(epoch);try await consume(permit);try ensure(epoch)
            }
            return try state(try await load(action).0,available:false)
        } catch {
            guard generation==epoch,!invalidated,!Task.isCancelled else {throw error}
            await lock();defer{unlock()};try ensure(epoch)
            var (journal,record)=try await load(action);try ensure(epoch)
            if journal.operations[id]?.state == .unknown {
                if provenNotSent {journal.operations[id]?.state = .notSent;journal.operations[id]?.issue = .notSent}
                else if rejected {journal.operations[id]?.state = .rejected;journal.operations[id]?.issue = .rejected}
                try await save(journal,record:record,action:action,epoch:epoch)
            }
            // A consumed permit or durable server response is never reverted to a new dispatchable operation.
            throw error
        }
    }
    private func matches(_ request:ConversationDeviceEffectJournalRequest,record:ConversationDeviceEffectRecord)->Bool {
        switch request {
        case .admission(let r):return record.frozen.admission_operation_id==r.operation_id && record.frozen.admission_request_hash==(try? ConversationDeviceEffectsCodec.canonicalHash(r))
        case .dispatch(let r):return record.subeffects[r.subeffect].dispatch?.operation_id==r.operation_id && record.subeffects[r.subeffect].dispatch?.request_hash==(try? ConversationDeviceEffectsCodec.canonicalHash(r))
        case .result(let r):let child=record.subeffects[r.subeffect];return child.result_operation_id==r.operation_id && child.state==r.outcome && child.receipt==r.receipt
        case .stop(let r):return record.stop?.operation_id==r.operation_id
        }
    }
    private func merge(_ value:ConversationDeviceEffectRecord,into journal:inout DeviceEffectJournal) throws {
        if let old=journal.latest {try validateProgress(value,after:old)}
        journal.latest=historical(value)
    }
    private func validateProgress(_ value:ConversationDeviceEffectRecord,after old:ConversationDeviceEffectRecord) throws {
            guard value.binding_hash==old.binding_hash,value.revision>=old.revision else {throw ConversationDeviceEffectServiceError.invalidJournal}
            if value.revision==old.revision {guard value.record_hash==old.record_hash else {throw ConversationDeviceEffectServiceError.invalidJournal}}
            if old.stop != nil {guard value.stop==old.stop else {throw ConversationDeviceEffectServiceError.invalidJournal}}
            for kind in [ConversationDeviceSubeffectKind.calendar,.notification] {
                let before=old.subeffects[kind],after=value.subeffects[kind]
                if let dispatch=before.dispatch {guard after.dispatch==dispatch else {throw ConversationDeviceEffectServiceError.invalidJournal}}
                if [.succeeded,.notExecuted].contains(before.state) {guard after.state==before.state,after.receipt_hash==before.receipt_hash,after.receipt==before.receipt,after.result_operation_id==before.result_operation_id else {throw ConversationDeviceEffectServiceError.invalidJournal}}
            }
    }
    private func historical(_ r:ConversationDeviceEffectRecord)->ConversationDeviceEffectRecord {.init(id:r.id,contract:r.contract,frozen:r.frozen,binding_hash:r.binding_hash,revision:r.revision,stop:r.stop,subeffects:r.subeffects,record_hash:r.record_hash,state:r.state,execution_current:false,unresolved_subeffects:r.unresolved_subeffects,can_redispatch:false)}
    private func hash(_ r:ConversationDeviceEffectRecord) throws -> String {try ConversationDeviceEffectsCodec.canonicalHash(r)}
    private func state(_ j:DeviceEffectJournal,available:Bool) throws -> ConversationDeviceEffectLocalState {.init(latest:j.latest.map(historical),operations:j.operations.values.sorted{$0.request.operationID<$1.request.operationID},capabilitiesAvailable:available,snapshotHash:try j.latest.map(hash))}
    private func load(_ action:ConversationApprovedDeviceAction) async throws -> (DeviceEffectJournal,StoredRecord?) {
        let reference=action.reference
        guard !invalidated,reference.scope==scope else {throw catError.scopeMismatch}
        guard subjectID?.uuidString.lowercased()==reference.subjectID else {throw ConversationDeviceEffectServiceError.notConfigured}
        let conversation=try await repository.record(reference.binding.conversation_id,scope:scope);guard conversation.conversation != nil else {throw ConversationDeviceEffectServiceError.invalidJournal}
        let key=try key(reference),record:StoredRecord
        do {record=try await repository.record(stableID(key),scope:scope)} catch catError.missing {return (.init(identity:key,frozen:action.frozen,decision:action.decision),nil)}
        guard case .preference(let p)=record.payload,p.key==key,p.value.utf8.count<=512_000 else {throw ConversationDeviceEffectServiceError.invalidJournal}
        let data=Data(p.value.utf8);_=try ConversationStrictJSON.object(data,maxBytes:512_000)
        let journal=try JSONDecoder().decode(DeviceEffectJournal.self,from:data)
        guard journal.schemaVersion==1,journal.identity==key,journal.operations.count<=64,
              journal.operations.values.filter({$0.state == .unknown}).count<=1,
              try ConversationDeviceEffectsCodec.canonicalHashJSON(data)==ConversationDeviceEffectsCodec.canonicalHash(journal),
              try ConversationDeviceEffectsCodec.decodeApprovedAction(frozenData:ConversationTaskActionJSON.encoded(journal.frozen),decisionData:ConversationTaskActionJSON.encoded(journal.decision),reference:reference)==action else {throw ConversationDeviceEffectServiceError.invalidJournal}
        if let latest=journal.latest {try validateSaved(latest,action:action);guard !latest.execution_current else {throw ConversationDeviceEffectServiceError.invalidJournal}}
        for (id,op) in journal.operations {
            guard id==op.request.operationID,ConversationTaskActionValidation.uuid(id),op.requestHash==(try ConversationDeviceEffectsCodec.canonicalHashJSON(op.request.body())) else {throw ConversationDeviceEffectServiceError.invalidJournal}
            if let base=op.base {
                try validateSaved(base,action:action)
                guard !base.execution_current,op.expectedSnapshotHash==(try hash(base)),let latest=journal.latest else {throw ConversationDeviceEffectServiceError.invalidJournal}
                try validateProgress(latest,after:base)
            }
            switch op.state {
            case .applied:guard op.issue==nil else {throw ConversationDeviceEffectServiceError.invalidJournal}
            case .unknown:guard op.issue == .unknown || op.issue == .originalNotFound else {throw ConversationDeviceEffectServiceError.invalidJournal}
            case .notSent:guard op.issue == .notSent else {throw ConversationDeviceEffectServiceError.invalidJournal}
            case .rejected:guard op.issue == .rejected else {throw ConversationDeviceEffectServiceError.invalidJournal}
            }
            switch op.request {
            case .admission(let r):guard op.base==nil,op.expectedSnapshotHash==nil,let id=UUID(uuidString:r.operation_id),try r==ConversationDeviceEffectAdmissionRequest(operationID:id,reference:reference,action:action,executionRevision:r.expected_execution_revision) else {throw ConversationDeviceEffectServiceError.invalidJournal}
            case .dispatch(let r):guard let base=op.base,r.expected_effect_revision==base.revision,r.binding_hash==base.binding_hash,r.lease_id==base.frozen.lease_id,base.stop==nil,base.subeffects[r.subeffect].state == .notDispatched,r.subeffect == .calendar || (base.subeffects.calendar.state == .succeeded && base.frozen.parameters.reminder_offset_seconds != nil) else {throw ConversationDeviceEffectServiceError.invalidJournal}
            case .result(let r):guard let base=op.base,let id=UUID(uuidString:r.operation_id),try r==ConversationDeviceEffectResultRequest(operationID:id,subeffect:r.subeffect,base:base,outcome:r.outcome,receipt:r.receipt) else {throw ConversationDeviceEffectServiceError.invalidJournal}
            case .stop(let r):guard let base=op.base,let id=UUID(uuidString:r.operation_id),try r==ConversationDeviceEffectStopRequest(operationID:id,base:base) else {throw ConversationDeviceEffectServiceError.invalidJournal}
            }
            if op.state == .applied {
                guard let response=op.response,matches(op.request,record:response),let latest=journal.latest else {throw ConversationDeviceEffectServiceError.invalidJournal}
                try validateSaved(response,action:action);try validateProgress(latest,after:response)
                if let base=op.base {guard response.revision>base.revision else {throw ConversationDeviceEffectServiceError.invalidJournal};try validateProgress(response,after:base)}
            }
            else {guard op.response==nil,!op.permitConsumed else {throw ConversationDeviceEffectServiceError.invalidJournal}}
            if op.permitConsumed {guard case .dispatch=op.request else {throw ConversationDeviceEffectServiceError.invalidJournal}}
        }
        return (journal,record)
    }
    private func validateSaved(_ record:ConversationDeviceEffectRecord,action:ConversationApprovedDeviceAction) throws {
        guard !record.execution_current else {throw ConversationDeviceEffectServiceError.invalidJournal}
        let envelope=ConversationTaskActionJSON.object(["schema_version":.integer(1),"contract":.string(ConversationDeviceEffectsCodec.effectContract),"effect":try .value(record),"dispatch_permit":.null])
        _=try ConversationDeviceEffectsCodec.decodeOriginal(ConversationTaskActionJSON.encoded(envelope),reference:action.reference,action:action)
    }
    private func save(_ journal:DeviceEffectJournal,record:StoredRecord?,action:ConversationApprovedDeviceAction,epoch:Int) async throws {
        try ensure(epoch);let conversation=try await repository.record(action.reference.binding.conversation_id,scope:scope);try ensure(epoch)
        let data=try ConversationTaskActionJSON.encoded(journal);guard data.count<=512_000 else {throw ConversationDeviceEffectServiceError.journalFull}
        let key=try key(action.reference),payload=Payload.preference(.init(key:key,value:String(decoding:data,as:UTF8.self)))
        let mutation:Mutation=record.map{.update($0.id,$0.header.revision,payload)} ?? .create(stableID(key),payload)
        try ensure(epoch);try await repository.commit(scope:scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation]);try ensure(epoch)
    }
    private func key(_ r:ConversationDeviceEffectReference) throws -> String {
        let binding=try ConversationTaskActionJSON.value(r.binding)
        let identity=ConversationTaskActionJSON.object(["profile":.string(scope.profileID.uuidString.lowercased()),"workspace":.string(scope.workspaceID.uuidString.lowercased()),"subject":.string(r.subjectID),"binding":binding,"action":.string(r.actionID),"digest":.string(r.actionDigest),"decision":.string(r.decisionOperationID),"revision":.integer(r.actionRevision)])
        return "conversation_device_effects:"+r.binding.conversation_id.uuidString.lowercased()+":"+(try identity.digest())
    }
    private func begin(_ key:String) throws {guard admitted,!invalidated,!active.contains(key),!Task.isCancelled else {throw ConversationDeviceEffectServiceError.busy};active.insert(key)}
    private func ensure(_ epoch:Int) throws {guard admitted,!invalidated,generation==epoch,!Task.isCancelled else {throw CancellationError()}}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock(){if waiters.isEmpty {locked=false}else{waiters.removeFirst().resume()}}
}
