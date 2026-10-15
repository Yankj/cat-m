import Foundation

// Bridge to 三角's catpaw.device.v1 network layer (PR #49, feat/device-call-protocol). Ours, not a network file.
//
// Guarded by the CATPAW_DEVICE_V1 compilation condition because #49 is not in feat/ios-mvp-integration-v2 yet and
// `ConversationDeviceCall` / `ConversationDeviceResultSubmitter` don't exist on this base.
// Merge order: #49 → #44, then add `CATPAW_DEVICE_V1` to SWIFT_ACTIVE_COMPILATION_CONDITIONS (or delete the #if).
// Install at sign-in next to installUIDecisionSubmitter (三角 owns that file, one line):
//     DeviceCallHub.submitter = ConversationDeviceResultSubmitter(service: service, scope: scope)
// and set it to nil at sign-out.
// CATPAW_DEVICE_V1: #49 merged, guard removed.
/// #49 comment: the session service fills in operation_id, args_hash and the turn from `call_id`; we pass status + data only.
/// `openURL` stays on the device (not encoded).
extension ConversationDeviceResultSubmitter: DeviceResultSubmitting {
    func submit(_ result: DeviceCallResult) async throws {
        let data = try result.data.map { try JSONEncoder().encode($0) }
        try await submit(callID: result.call_id, status: result.status.rawValue, data: data)
    }
}

extension DeviceCall {
    /// Full catpaw.device.v1 fields (the session's `wireJSON` only carries call_id, tool, args, confirm, ttl_sec).
    init?(_ call: ConversationDeviceCall) {
        guard let args = try? JSONDecoder().decode([String: DeviceCallValue].self, from: call.args) else { return nil }
        self.init(call_id: call.callID, tool: call.tool, args: args, confirm: Confirm(rawValue: call.confirm) ?? .card,
                  ttl_sec: call.ttlSec, interrupt_id: call.interruptID, args_hash: call.argsHash, expires_at: call.expiresAt)
    }
}
