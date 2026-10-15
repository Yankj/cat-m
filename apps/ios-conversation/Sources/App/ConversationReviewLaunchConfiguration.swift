import Foundation
import CoreFoundation

/// Restores only an explicitly opted-in DEBUG loopback launch descriptor.
/// It carries no account, credential, grant, model route, or execution authority.
@MainActor enum ConversationReviewLaunchConfiguration {
    static let storageKey="catpaw.review.launch.v1"
    static func resolve(environment:[String:String],defaults:UserDefaults = .standard,now:Date = Date())->[String:String] {
        #if DEBUG
        // Even an empty or invalid explicit test selection is authoritative. A QA
        // invocation must never silently fall back into the user's review store.
        if environment["CF_UI_TEST_STORE"] != nil || environment["CF_UI_TEST_SCENARIO"] != nil {
            if environment["CATPAW_REVIEW_PERSIST"]=="1",environment["CATPAW_QA_VISUAL_REVIEW"]=="1",
               environment["CF_UI_TEST_SCENARIO"]=="p0-ui-accepted-work",
               let store=environment["CF_UI_TEST_STORE"],validStore(store),
               let rawPort=environment["CATPAW_ACCEPTED_WORK_PORT"],let port=decimal(rawPort),(1024...65535).contains(port),
               let rawExpiry=environment["CATPAW_REVIEW_EXPIRES_AT"],let expiry=decimal(rawExpiry),
               validClock(now),Double(expiry)>now.timeIntervalSince1970,Double(expiry)-now.timeIntervalSince1970<=21600,
               let bytes=try? JSONSerialization.data(withJSONObject:["schema_version":1,"store":store,"port":port,"expires_at":expiry],options:.sortedKeys) {
                defaults.set(bytes,forKey:storageKey)
            }
            return environment
        }
        guard environment["CATPAW_REVIEW_DISABLE"] != "1",validClock(now),
              let bytes=defaults.data(forKey:storageKey),let descriptor=descriptor(bytes,now:now) else {return environment}
        // An expired QA loopback descriptor must not trap a normal launch on the
        // "offline review expired" screen: drop it and start the real app path.
        // (The QA store's files stay on disk; only the relaunch descriptor goes.)
        if Double(descriptor.expiry)<=now.timeIntervalSince1970 {defaults.removeObject(forKey:storageKey);return environment}
        var restored=environment
        restored["CF_UI_TEST_SCENARIO"]="p0-ui-accepted-work"
        restored["CF_UI_TEST_STORE"]=descriptor.store
        restored["CATPAW_ACCEPTED_WORK_PORT"]=String(descriptor.port)
        restored["CATPAW_QA_VISUAL_REVIEW"]="1"
        restored["CATPAW_REVIEW_EXPIRES_AT"]=String(descriptor.expiry)
        restored.removeValue(forKey:"CATPAW_REVIEW_EXPIRED")
        return restored
        #else
        return environment
        #endif
    }
    #if DEBUG
    private struct Descriptor {let store:String,port:Int,expiry:Int}
    private static func validClock(_ now:Date)->Bool {now.timeIntervalSince1970.isFinite && now.timeIntervalSince1970>=0 && now.timeIntervalSince1970<=9_007_199_254_740_991}
    private static func validStore(_ raw:String)->Bool {
        raw.utf8.count==36 && raw.range(of:"^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$",options:.regularExpression) != nil && UUID(uuidString:raw) != nil
    }
    private static func decimal(_ raw:String)->Int? {
        guard !raw.isEmpty,raw.utf8.count<=19,raw.utf8.allSatisfy({(48...57).contains($0)}),
              let value=Int(raw),value>0,String(value)==raw,value<=9_007_199_254_740_991 else {return nil};return value
    }
    private static func integer(_ value:Any?)->Int? {
        guard let value=value as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),
              !["f","d"].contains(String(cString:value.objCType)) else {return nil}
        return decimal(value.stringValue)
    }
    private static func descriptor(_ bytes:Data,now:Date)->Descriptor? {
        guard let object=try? ConversationStrictJSON.object(bytes,maxBytes:2048),
              Set(object.keys)==["schema_version","store","port","expires_at"],integer(object["schema_version"])==1,
              let store=object["store"] as? String,validStore(store),
              let port=integer(object["port"]),(1024...65535).contains(port),let expiry=integer(object["expires_at"]),
              Double(expiry)-now.timeIntervalSince1970<=21600,
              // Our four-field descriptor is stored canonically. This also rejects
              // lexical fractions/exponents rather than coercing them to an Int.
              let canonical=try? JSONSerialization.data(withJSONObject:object,options:.sortedKeys),canonical==bytes else {return nil}
        return .init(store:store,port:port,expiry:expiry)
    }
    #endif
}
