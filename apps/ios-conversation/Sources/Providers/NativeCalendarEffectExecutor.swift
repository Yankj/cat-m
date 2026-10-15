import Foundation
#if canImport(EventKit) && canImport(UserNotifications)
import EventKit
import UserNotifications

/// Platform adapter only: no account, HTTP, task admission or permission-on-init.
/// Full calendar access is required because unknown recovery must read back the
/// original marker; write-only access cannot safely support that guarantee.
@MainActor public final class NativeCalendarEffectExecutor:ConversationDeviceEffectOSPort {
    private let events:EKEventStore
    private let notifications:UNUserNotificationCenter
    private let clock:@Sendable()->Date
    private var consumed:Set<String>=[]
    public init(eventStore:EKEventStore=EKEventStore(),notificationCenter:UNUserNotificationCenter = .current(),clock:@escaping @Sendable()->Date={Date()}) {
        events=eventStore;notifications=notificationCenter;self.clock=clock
    }
    public func permission(_ kind:ConversationDeviceSubeffectKind) async -> ConversationDeviceOSPermission {
        if kind == .calendar {
            let value=EKEventStore.authorizationStatus(for:.event)
            if #available(iOS 17.0,macOS 14.0,*) {if value == .fullAccess{return .authorized};if value == .writeOnly{return .denied}}
            switch value {case .authorized:return .authorized;case .notDetermined:return .notDetermined;case .denied:return .denied;case .restricted:return .restricted;default:return .unavailable}
        }
        let value=await notificationSettings()
        switch value.authorizationStatus {case .authorized,.provisional,.ephemeral:return .authorized;case .notDetermined:return .notDetermined;case .denied:return .denied;@unknown default:return .unavailable}
    }
    public func requestPermissionFromUserAction(_ kind:ConversationDeviceSubeffectKind) async throws -> ConversationDeviceOSPermission {
        if await permission(kind) != .notDetermined {return await permission(kind)}
        if kind == .calendar {
            if #available(iOS 17.0,macOS 14.0,*) {_=try await events.requestFullAccessToEvents()}
            else {_=try await events.requestAccess(to:.event)}
        } else {_=try await notifications.requestAuthorization(options:[.alert,.sound])}
        return await permission(kind)
    }
    /// Call only after explicit calendar access. Hashes describe the exact native
    /// calendar/source identity and writability, not a UI-selected display name.
    public func calendarTargets(deviceID:UUID,environmentID:UUID) async throws -> [ConversationDeviceCalendarTarget] {
        guard await permission(.calendar) == .authorized else {throw ConversationDeviceExecutionError.permissionDenied}
        return try events.calendars(for:.event).filter(\.allowsContentModifications).map {calendar in
            .init(device_id:deviceID.uuidString.lowercased(),environment_id:environmentID.uuidString.lowercased(),calendar_id:calendar.calendarIdentifier,calendar_display_name:calendar.title,calendar_snapshot_hash:try snapshotHash(calendar))
        }
    }
    public func query(_ intent:ConversationDeviceOSIntent,knownReference:ConversationTaskActionJSON?) async throws -> ConversationDeviceOSObservation {
        try validateIntent(intent)
        guard await permission(intent.kind) == .authorized else {throw ConversationDeviceExecutionError.permissionDenied}
        if intent.kind == .calendar {return try queryCalendar(intent,knownReference:knownReference)}
        return try await queryNotification(intent)
    }
    public func perform(_ intent:ConversationDeviceOSIntent,authorization:ConversationDeviceOSWriteAuthorization) async throws -> ConversationDeviceOSObservation {
        let permit=authorization.permit
        try validateIntent(intent)
        guard permit.dispatch == (try intent.dispatch),permit.leaseExpiresAt==intent.effect.frozen.lease_expires_at,
              let expires=ConversationTaskActionValidation.utc(permit.leaseExpiresAt),expires>clock(),!consumed.contains(permit.dispatch.operation_id) else {throw ConversationDeviceExecutionError.stale}
        guard await permission(intent.kind) == .authorized else {throw ConversationDeviceExecutionError.permissionDenied}
        try Task.checkCancellation()
        // Reserve before the first API that may have a side effect. The app's
        // durable executor journal has already reserved this identity on disk.
        consumed.insert(permit.dispatch.operation_id)
        if intent.kind == .calendar {
            let prior=try queryCalendar(intent,knownReference:nil)
            guard prior == .absent else {return prior}
            let calendar=try exactCalendar(intent)
            let p=intent.effect.frozen.parameters,event=EKEvent(eventStore:events)
            event.calendar=calendar;event.title=p.title;event.startDate=ConversationTaskActionValidation.utc(p.start_at)!
            event.endDate=ConversationTaskActionValidation.utc(p.end_at)!;event.timeZone=TimeZone(identifier:p.time_zone)
            event.isAllDay=false;event.url=URL(string:intent.marker);event.alarms=[];event.recurrenceRules=[]
            try Task.checkCancellation()
            guard expires>clock() else {throw ConversationDeviceExecutionError.stale}
            try authorization.withAuthorization {try events.save(event,span:.thisEvent,commit:true)}
            // Never infer success from save returning. Read the stored object.
            return try queryCalendar(intent,knownReference:nil)
        }
        guard intent.effect.subeffects.calendar.state == .succeeded,let due=try intent.dueAt,let date=ConversationTaskActionValidation.utc(due),date>clock() else {throw ConversationDeviceExecutionError.stale}
        let prior=try await queryNotification(intent)
        guard prior == .absent else {return prior}
        guard expires>clock() else {throw ConversationDeviceExecutionError.stale}
        try Task.checkCancellation()
        let content=UNMutableNotificationContent();content.title=intent.effect.frozen.parameters.title
        content.sound = .default;content.userInfo=try notificationInfo(intent)
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:intent.effect.frozen.parameters.time_zone)!
        var components=calendar.dateComponents([.year,.month,.day,.hour,.minute,.second],from:date)
        components.calendar=calendar;components.timeZone=calendar.timeZone
        let request=UNNotificationRequest(identifier:intent.effect.subeffects.notification.id,content:content,trigger:UNCalendarNotificationTrigger(dateMatching:components,repeats:false))
        try await add(request,authorization:authorization)
        return try await queryNotification(intent)
    }
    private func snapshotHash(_ calendar:EKCalendar) throws -> String {
        try ConversationTaskActionJSON.object(["contract":.string("catpaw.native-calendar-snapshot.v1"),"calendar_id":.string(calendar.calendarIdentifier),"title":.string(calendar.title),"source_id":.string(calendar.source.sourceIdentifier),"source_title":.string(calendar.source.title),"source_type":.integer(Int(calendar.source.sourceType.rawValue)),"calendar_type":.integer(Int(calendar.type.rawValue)),"writable":.bool(calendar.allowsContentModifications)]).digest()
    }
    private func exactCalendar(_ intent:ConversationDeviceOSIntent) throws -> EKCalendar {
        let target=intent.effect.frozen.target
        guard let calendar=events.calendar(withIdentifier:target.calendar_id),calendar.allowsContentModifications,
              calendar.title.utf16.elementsEqual(target.calendar_display_name.utf16),try snapshotHash(calendar)==target.calendar_snapshot_hash else {throw ConversationDeviceExecutionError.stale}
        return calendar
    }
    private func queryCalendar(_ intent:ConversationDeviceOSIntent,knownReference:ConversationTaskActionJSON?) throws -> ConversationDeviceOSObservation {
        let target=intent.effect.frozen.target,p=intent.effect.frozen.parameters
        guard let calendar=events.calendar(withIdentifier:target.calendar_id) else {return .absent}
        let start=ConversationTaskActionValidation.utc(p.start_at)!,end=ConversationTaskActionValidation.utc(p.end_at)!
        let predicate=events.predicateForEvents(withStart:start.addingTimeInterval(-86400),end:end.addingTimeInterval(86400),calendars:[calendar])
        var found=events.events(matching:predicate).filter{$0.url?.absoluteString==intent.marker}
        if let knownReference,let known=try? knownReference.decoded(ConversationDeviceCalendarReceiptReference.self),
           let event=events.event(withIdentifier:known.event_identifier),!found.contains(where:{$0.eventIdentifier==event.eventIdentifier}) {found.append(event)}
        guard !found.isEmpty else {return .absent};guard found.count==1,let event=found.first else {return .ambiguous}
        guard event.calendar.calendarIdentifier==target.calendar_id,event.url?.absoluteString==intent.marker,
              event.title.utf16.elementsEqual(p.title.utf16),event.startDate==start,event.endDate==end,event.timeZone?.identifier==TimeZone(identifier:p.time_zone)?.identifier,
              !event.isAllDay,event.recurrenceRules?.isEmpty ?? true,event.alarms?.isEmpty ?? true,
              let eventID=event.eventIdentifier,!eventID.isEmpty,!event.calendarItemIdentifier.isEmpty else {return .ambiguous}
        let hash=try ConversationTaskActionJSON.object(["calendar_id":.string(target.calendar_id),"title":.string(event.title),"start_at":.string(ConversationDeviceOSIntent.utc(event.startDate)),"end_at":.string(ConversationDeviceOSIntent.utc(event.endDate)),"time_zone":.string(event.timeZone!.identifier),"effect_marker":.string(intent.marker)]).digest()
        let reference=ConversationDeviceCalendarReceiptReference(calendar_id:target.calendar_id,event_identifier:eventID,calendar_item_identifier:event.calendarItemIdentifier,external_identifier:event.calendarItemExternalIdentifier,effect_marker:intent.marker,content_hash:hash)
        return .found(try .value(reference))
    }
    private func notificationInfo(_ intent:ConversationDeviceOSIntent) throws -> [String:String] {
        let f=intent.effect.frozen
        return ["catpaw_contract":ConversationDeviceEffectsCodec.effectContract,"catpaw_effect_id":intent.effect.id,"catpaw_subeffect_id":intent.effect.subeffects.notification.id,"catpaw_run_id":f.run_id,"catpaw_conversation_id":f.conversation_id,"catpaw_task_id":f.task_id,"catpaw_parameters_hash":try intent.parametersHash,"catpaw_schedule_hash":try intent.scheduleHash,"catpaw_due_at":try intent.dueAt!]
    }
    private func queryNotification(_ intent:ConversationDeviceOSIntent) async throws -> ConversationDeviceOSObservation {
        guard let due=try intent.dueAt,let date=ConversationTaskActionValidation.utc(due) else {throw ConversationDeviceExecutionError.invalidIntent}
        let id=intent.effect.subeffects.notification.id,pending=await pendingRequests(),delivered=await deliveredNotifications()
        let matches=pending.filter{$0.identifier==id}.map{($0,"pending")}+delivered.filter{$0.request.identifier==id}.map{($0.request,"delivered")}
        guard !matches.isEmpty else {return .absent};guard matches.count==1,let pair=matches.first else {return .ambiguous}
        let request=pair.0,expected=try notificationInfo(intent)
        guard request.content.title.utf16.elementsEqual(intent.effect.frozen.parameters.title.utf16),
              request.content.userInfo as? [String:String]==expected,let trigger=request.trigger as? UNCalendarNotificationTrigger,!trigger.repeats else {return .ambiguous}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:intent.effect.frozen.parameters.time_zone)!
        guard trigger.dateComponents.timeZone?.identifier==calendar.timeZone.identifier,
              let actual=calendar.date(from:trigger.dateComponents),abs(actual.timeIntervalSince(date))<0.001 else {return .ambiguous}
        let reference=ConversationDeviceNotificationReceiptReference(request_identifier:id,schedule_hash:try intent.scheduleHash,due_at:due,state:pair.1)
        return .found(try .value(reference))
    }
    private func validateIntent(_ intent:ConversationDeviceOSIntent) throws {
        let effect=intent.effect
        guard let dispatch=effect.subeffects[intent.kind].dispatch,dispatch.kind==intent.kind,dispatch.effect_id==effect.id,dispatch.subeffect_id==effect.subeffects[intent.kind].id,dispatch.binding_hash==effect.binding_hash else {throw ConversationDeviceExecutionError.invalidIntent}
        try effect.frozen.parameters.validate();try effect.frozen.target.validate()
    }
    private func notificationSettings() async -> UNNotificationSettings {await withCheckedContinuation{continuation in notifications.getNotificationSettings{continuation.resume(returning:$0)}}}
    private func pendingRequests() async -> [UNNotificationRequest] {await withCheckedContinuation{continuation in notifications.getPendingNotificationRequests{continuation.resume(returning:$0)}}}
    private func deliveredNotifications() async -> [UNNotification] {await withCheckedContinuation{continuation in notifications.getDeliveredNotifications{continuation.resume(returning:$0)}}}
    private func add(_ request:UNNotificationRequest,authorization:ConversationDeviceOSWriteAuthorization) async throws {
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            do {try authorization.withAuthorization {notifications.add(request){error in if let error {continuation.resume(throwing:error)}else{continuation.resume()}}}}
            catch {continuation.resume(throwing:error)}
        }
    }
}
#endif
