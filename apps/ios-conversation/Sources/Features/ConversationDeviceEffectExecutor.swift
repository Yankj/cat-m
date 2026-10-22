import Foundation

public enum ConversationDeviceOSPermission:String,Sendable {case notDetermined,authorized,denied,restricted,unavailable}
public enum ConversationDeviceExecutionError:Error,Sendable {case closed,busy,permissionRequired,permissionDenied,invalidIntent,stale,invalidJournal}
public enum ConversationDeviceOSObservation:Sendable,Equatable {case found(ConversationTaskActionJSON),absent,ambiguous}
public enum ConversationDeviceExecutionOutcome:Sendable,Equatable {case succeeded(ConversationDeviceEffectReceipt),unknown}

/// Historical identity only. Decoding an intent never grants a second OS write.
public struct ConversationDeviceOSIntent:Codable,Sendable,Equatable {
    public let effect:ConversationDeviceEffectRecord
    public let kind:ConversationDeviceSubeffectKind
    public var dispatch:ConversationDeviceEffectDispatchRecord {get throws {guard let value=effect.subeffects[kind].dispatch else {throw ConversationDeviceExecutionError.invalidIntent};return value}}
    public var marker:String {"catpawm://calendar-effect/"+effect.subeffects.calendar.id}
    public var parametersHash:String {get throws {try ConversationDeviceEffectsCodec.canonicalHash(effect.frozen.parameters)}}
    public var dueAt:String? {get throws {
        guard let offset=effect.frozen.parameters.reminder_offset_seconds,let start=ConversationTaskActionValidation.utc(effect.frozen.parameters.start_at) else {return nil}
        return Self.utc(start.addingTimeInterval(Double(offset)))
    }}
    public var scheduleHash:String {get throws {
        guard let due=try dueAt else {throw ConversationDeviceExecutionError.invalidIntent}
        return try ConversationTaskActionJSON.object(["subeffect_id":.string(effect.subeffects.notification.id),"due_at":.string(due),"parameters_hash":.string(parametersHash),"channel":.string("catpaw_local_notification")]).digest()
    }}
    public static func utc(_ date:Date)->String {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:date)}
}

/// Nonserializable, one-use final OS submission fence. Closing the application
/// waits for a submission already inside this critical section, and blocks every
/// later submission after an async permission/query callback. It grants nothing
/// beyond the exact fresh permit it contains.
public final class ConversationDeviceOSWriteAuthorization:@unchecked Sendable {
    public let permit:ConversationDeviceDispatchPermit
    private let lock=NSLock()
    private let clock:@Sendable()->Date
    private var open=true,used=false
    fileprivate init(permit:ConversationDeviceDispatchPermit,clock:@escaping @Sendable()->Date){self.permit=permit;self.clock=clock}
    fileprivate func invalidate(){lock.lock();open=false;lock.unlock()}
    public func withAuthorization<T>(_ submission:() throws -> T) throws -> T {
        lock.lock();defer{lock.unlock()}
        guard open,!used,!Task.isCancelled,let expires=ConversationTaskActionValidation.utc(permit.leaseExpiresAt),expires>clock() else {throw ConversationDeviceExecutionError.stale}
        used=true
        return try submission()
    }
}

/// Implementations must not request permission inside query/perform. Only the
/// explicitly named user-action method may invoke a system permission prompt.
public protocol ConversationDeviceEffectOSPort:Sendable {
    func permission(_ kind:ConversationDeviceSubeffectKind) async -> ConversationDeviceOSPermission
    func requestPermissionFromUserAction(_ kind:ConversationDeviceSubeffectKind) async throws -> ConversationDeviceOSPermission
    func query(_ intent:ConversationDeviceOSIntent,knownReference:ConversationTaskActionJSON?) async throws -> ConversationDeviceOSObservation
    func perform(_ intent:ConversationDeviceOSIntent,authorization:ConversationDeviceOSWriteAuthorization) async throws -> ConversationDeviceOSObservation
}

private struct ConversationDeviceOSJournal:Codable {
    let schemaVersion:Int
    let identity:String
    let subjectID:String
    let intent:ConversationDeviceOSIntent
    var receipt:ConversationDeviceEffectReceipt?
}

/// The existing service owns HTTP admission and permit consumption. This actor
/// owns only the final durable intent -> one OS invocation -> original observation.
/// A crash after intent persistence always recovers by querying, even if no object
/// can be found; absence is never proof that an earlier OS invocation did not run.
public actor ConversationDeviceEffectExecutor {
    private let repository:Repository
    private let service:ConversationDeviceEffectService
    private let scope:DataScope
    private let subjectID,deviceID,environmentID:String
    private let os:any ConversationDeviceEffectOSPort
    private let clock:@Sendable()->Date
    private var admitted=false,invalidated=false,busy=false,generation=0
    private var writes:[String:ConversationDeviceOSWriteAuthorization]=[:]
    public init(repository:Repository,service:ConversationDeviceEffectService,scope:DataScope=Profiles.user,subjectID:UUID,deviceID:UUID,environmentID:UUID,os:any ConversationDeviceEffectOSPort,clock:@escaping @Sendable()->Date={Date()}) {
        self.repository=repository;self.service=service;self.scope=scope;self.subjectID=subjectID.uuidString.lowercased();self.deviceID=deviceID.uuidString.lowercased();self.environmentID=environmentID.uuidString.lowercased();self.os=os;self.clock=clock
    }
    public func setAdmissionAllowed(_ allowed:Bool) {if !allowed {generation += 1;writes.values.forEach{$0.invalidate()}};admitted=allowed && !invalidated}
    public func invalidate(){generation += 1;admitted=false;invalidated=true;writes.values.forEach{$0.invalidate()}}
    public func requestPermissionFromUserAction(_ kind:ConversationDeviceSubeffectKind) async throws -> ConversationDeviceOSPermission {
        let epoch=try begin();defer{busy=false}
        let value=try await os.requestPermissionFromUserAction(kind);try ensure(epoch);return value
    }
    public func execute(_ action:ConversationApprovedDeviceAction,subeffect:ConversationDeviceSubeffectKind,expectedSnapshotHash:String) async throws -> ConversationDeviceExecutionOutcome {
        let epoch=try begin();defer{busy=false};try validate(action)
        if try await load(action,kind:subeffect) != nil {try ensure(epoch);return try await recoverOriginal(action,kind:subeffect,epoch:epoch)}
        try ensure(epoch);try requirePermission(await os.permission(subeffect));try ensure(epoch)
        do {
            _=try await service.dispatch(action,subeffect:subeffect,expectedSnapshotHash:expectedSnapshotHash) {permit in
                try await self.consume(permit,action:action,kind:subeffect,epoch:epoch)
            }
            try ensure(epoch)
        } catch {
            try ensure(epoch)
            // A durable OS intent is never removed or retried because a callback
            // failed. Recovery below can only query the same original marker.
            guard try await load(action,kind:subeffect) != nil else {throw error}
        }
        return try await recoverOriginal(action,kind:subeffect,epoch:epoch)
    }
    public func recover(_ action:ConversationApprovedDeviceAction,subeffect:ConversationDeviceSubeffectKind) async throws -> ConversationDeviceExecutionOutcome {
        let epoch=try begin();defer{busy=false};try validate(action)
        return try await recoverOriginal(action,kind:subeffect,epoch:epoch)
    }
    private func consume(_ permit:ConversationDeviceDispatchPermit,action:ConversationApprovedDeviceAction,kind:ConversationDeviceSubeffectKind,epoch:Int) async throws {
        try ensure(epoch)
        guard try await load(action,kind:kind)==nil else {throw ConversationDeviceExecutionError.stale}
        let local=try await service.localState(action);try ensure(epoch)
        guard let effect=local.latest,effect.stop==nil,effect.frozen.target.device_id==deviceID,effect.frozen.target.environment_id==environmentID,
              effect.subeffects[kind].dispatch==permit.dispatch,permit.dispatch.kind==kind,permit.dispatch.binding_hash==effect.binding_hash,
              permit.leaseExpiresAt==effect.frozen.lease_expires_at,let expiry=ConversationTaskActionValidation.utc(permit.leaseExpiresAt),expiry>clock(),
              effect.subeffects[kind].state == .dispatched,
              kind == .calendar || (effect.subeffects.calendar.state == .succeeded && effect.frozen.parameters.reminder_offset_seconds != nil) else {throw ConversationDeviceExecutionError.stale}
        let intent=ConversationDeviceOSIntent(effect:effect,kind:kind)
        var journal=ConversationDeviceOSJournal(schemaVersion:1,identity:try key(action,kind:kind),subjectID:subjectID,intent:intent,receipt:nil)
        // Both service dispatch reservation and this exact OS identity are on
        // disk before querying or invoking EventKit/UNUserNotificationCenter.
        try await save(journal,action:action,epoch:epoch);try ensure(epoch)
        try requirePermission(await os.permission(kind));try ensure(epoch)
        let found=try await os.query(intent,knownReference:nil);try ensure(epoch)
        let observation:ConversationDeviceOSObservation
        switch found {
        case .found,.ambiguous:observation=found
        case .absent:
            guard expiry>clock() else {throw ConversationDeviceExecutionError.stale}
            try ensure(epoch)
            let authorization=ConversationDeviceOSWriteAuthorization(permit:permit,clock:clock)
            writes[permit.dispatch.operation_id]=authorization
            defer{authorization.invalidate();writes[permit.dispatch.operation_id]=nil}
            observation=try await os.perform(intent,authorization:authorization);try ensure(epoch)
        }
        if case .found(let external)=observation {
            journal.receipt=try receipt(intent,external:external)
            try await save(journal,action:action,epoch:epoch)
        }
    }
    private func recoverOriginal(_ action:ConversationApprovedDeviceAction,kind:ConversationDeviceSubeffectKind,epoch:Int) async throws -> ConversationDeviceExecutionOutcome {
        var saved=try await load(action,kind:kind);try ensure(epoch)
        var live=try await service.refresh(action);try ensure(epoch)
        guard let original=live.latest else {return .unknown}
        if let old=saved {
            guard original.frozen==old.intent.effect.frozen,original.binding_hash==old.intent.effect.binding_hash,
                  original.subeffects[kind].dispatch==old.intent.effect.subeffects[kind].dispatch else {throw ConversationDeviceExecutionError.stale}
        }
        if original.subeffects[kind].state == .succeeded,let value=original.subeffects[kind].receipt {return .succeeded(value)}
        // A crash may precede local OS-intent persistence, or the dispatch reply
        // may have been lost. Original GET can create a query-only journal; it
        // cannot manufacture a permit or enter perform().
        if saved==nil {
            guard original.subeffects[kind].dispatch != nil else {return .unknown}
            let queryOnly=ConversationDeviceOSJournal(schemaVersion:1,identity:try key(action,kind:kind),subjectID:subjectID,intent:.init(effect:original,kind:kind),receipt:nil)
            try await save(queryOnly,action:action,epoch:epoch);try ensure(epoch);saved=queryOnly
        }
        guard var journal=saved else {return .unknown}
        guard [.dispatched,.unknown].contains(original.subeffects[kind].state) else {return .unknown}
        if journal.receipt==nil {
            guard await os.permission(kind) == .authorized else {try ensure(epoch);return .unknown}
            try ensure(epoch)
            let observation=try await os.query(journal.intent,knownReference:nil);try ensure(epoch)
            guard case .found(let external)=observation else {return .unknown}
            journal.receipt=try receipt(journal.intent,external:external)
            try await save(journal,action:action,epoch:epoch);try ensure(epoch)
        }
        guard let proof=journal.receipt else {return .unknown}
        // A result POST is the existing service's durable observation delivery,
        // not another dispatch or OS write. Lost result replies keep its UUID.
        guard !live.hasUnresolvedOperation,let hash=live.snapshotHash else {return .unknown}
        live=try await service.recordOriginalObservation(action,subeffect:kind,outcome:.succeeded,receipt:proof,expectedSnapshotHash:hash);try ensure(epoch)
        if live.latest?.subeffects[kind].state == .succeeded {return .succeeded(proof)}
        return .unknown
    }
    private func receipt(_ intent:ConversationDeviceOSIntent,external:ConversationTaskActionJSON) throws -> ConversationDeviceEffectReceipt {
        let effect=intent.effect,dispatch=try intent.dispatch
        let value=ConversationDeviceEffectReceipt(contract:ConversationDeviceEffectsCodec.effectContract,effect_id:effect.id,subeffect_id:effect.subeffects[intent.kind].id,dispatch_operation_id:dispatch.operation_id,action_digest:effect.frozen.action_digest,binding_hash:effect.binding_hash,device_id:deviceID,device_generation:effect.frozen.device_generation,outcome:.succeeded,external_reference:external,observed_at:ConversationDeviceOSIntent.utc(clock()))
        try ConversationDeviceEffectsCodec.validateObservation(value,base:effect,kind:intent.kind);return value
    }
    private func validate(_ action:ConversationApprovedDeviceAction) throws {
        guard service.scope==scope,action.reference.scope==scope,action.reference.subjectID==subjectID,action.frozen.target.device_id==deviceID,action.frozen.target.environment_id==environmentID else {throw ConversationDeviceExecutionError.invalidIntent}
        try action.frozen.parameters.validate();try action.frozen.target.validate()
    }
    private func key(_ action:ConversationApprovedDeviceAction,kind:ConversationDeviceSubeffectKind) throws -> String {
        let identity=ConversationTaskActionJSON.object(["scope":try .value(scope),"subject":.string(subjectID),"action":.string(action.reference.actionID),"digest":.string(action.reference.actionDigest),"subeffect":.string(kind.rawValue),"device":.string(deviceID),"environment":.string(environmentID)])
        return "conversation_device_os:"+(try identity.digest())
    }
    private func load(_ action:ConversationApprovedDeviceAction,kind:ConversationDeviceSubeffectKind) async throws -> ConversationDeviceOSJournal? {
        let key=try key(action,kind:kind),record:StoredRecord
        do {record=try await repository.record(stableID(key),scope:scope)}catch catError.missing{return nil}
        guard case .preference(let p)=record.payload,p.key==key,p.value.utf8.count<=512_000 else {throw ConversationDeviceExecutionError.invalidJournal}
        let data=Data(p.value.utf8);_=try ConversationStrictJSON.object(data,maxBytes:512_000)
        let value=try JSONDecoder().decode(ConversationDeviceOSJournal.self,from:data),intent=value.intent
        guard value.schemaVersion==1,value.identity==key,value.subjectID==subjectID,intent.kind==kind,
              intent.effect.frozen.action_digest==action.reference.actionDigest,intent.effect.frozen.action_id==action.reference.actionID,
              intent.effect.frozen.target==action.frozen.target,intent.effect.frozen.parameters==action.frozen.parameters,
              intent.effect.subeffects[kind].dispatch != nil,!intent.effect.execution_current,
              try ConversationDeviceEffectsCodec.canonicalHash(value)==ConversationDeviceEffectsCodec.canonicalHashJSON(data) else {throw ConversationDeviceExecutionError.invalidJournal}
        let envelope=ConversationTaskActionJSON.object(["schema_version":.integer(1),"contract":.string(ConversationDeviceEffectsCodec.effectContract),"effect":try .value(intent.effect),"dispatch_permit":.null])
        _=try ConversationDeviceEffectsCodec.decodeOriginal(ConversationTaskActionJSON.encoded(envelope),reference:action.reference,action:action)
        if let proof=value.receipt {try ConversationDeviceEffectsCodec.validateObservation(proof,base:intent.effect,kind:kind)}
        return value
    }
    private func save(_ value:ConversationDeviceOSJournal,action:ConversationApprovedDeviceAction,epoch:Int) async throws {
        try ensure(epoch)
        let conversation=try await repository.record(action.reference.binding.conversation_id,scope:scope);try ensure(epoch)
        let key=try key(action,kind:value.intent.kind),existing:StoredRecord?
        do {existing=try await repository.record(stableID(key),scope:scope)}catch catError.missing{existing=nil}
        try ensure(epoch)
        if let existing {
            guard case .preference(let p)=existing.payload,p.key==key else {throw ConversationDeviceExecutionError.invalidJournal}
            let old=try JSONDecoder().decode(ConversationDeviceOSJournal.self,from:Data(p.value.utf8))
            guard old.intent==value.intent,old.receipt==nil || old.receipt==value.receipt else {throw ConversationDeviceExecutionError.invalidJournal}
        }
        let data=try ConversationTaskActionJSON.encoded(value);guard data.count<=512_000 else {throw ConversationDeviceExecutionError.invalidJournal}
        let payload=Payload.preference(.init(key:key,value:String(decoding:data,as:UTF8.self)))
        let mutation:Mutation=existing.map{.update($0.id,$0.header.revision,payload)} ?? .create(stableID(key),payload)
        try ensure(epoch);try await repository.commit(scope:scope,mutations:[.requireRevision(conversation.id,conversation.header.revision),mutation]);try ensure(epoch)
    }
    private func requirePermission(_ value:ConversationDeviceOSPermission) throws {
        guard value == .authorized else {throw value == .notDetermined ? ConversationDeviceExecutionError.permissionRequired:ConversationDeviceExecutionError.permissionDenied}
    }
    private func begin() throws -> Int {guard admitted,!invalidated,!Task.isCancelled else {throw ConversationDeviceExecutionError.closed};guard !busy else {throw ConversationDeviceExecutionError.busy};busy=true;return generation}
    private func ensure(_ epoch:Int) throws {guard admitted,!invalidated,generation==epoch,!Task.isCancelled else {throw CancellationError()}}
}
