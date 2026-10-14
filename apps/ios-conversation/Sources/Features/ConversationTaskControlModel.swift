import Foundation
import Combine

@MainActor final class ConversationTaskControlModel:ObservableObject {
    let service:ConversationTaskControlService
    let reference:ConversationTaskControlReference
    private let onApplied:(@MainActor (ConversationTaskControlEnvelope) async throws -> Void)?
    @Published private(set) var state=ConversationTaskControlLocalState()
    @Published private(set) var loading=false
    @Published private(set) var submitting=false
    @Published private(set) var freshlyRead=false
    @Published private(set) var deliveryIssue:String?
    @Published var error:String?
    private var generation=0
    init(service:ConversationTaskControlService,reference:ConversationTaskControlReference,onApplied:(@MainActor (ConversationTaskControlEnvelope) async throws -> Void)?=nil){self.service=service;self.reference=reference;self.onApplied=onApplied}
    func canSubmit(_ action:ConversationTaskControlAction)->Bool {freshlyRead && state.controlAvailable && !loading && !submitting && !state.hasUnresolvedSubmission && (state.latest?.allows(action) ?? false)}
    func load(admissionAllowed:Bool) async {
        guard !loading,!submitting else {return};generation += 1;let epoch=generation
        loading=true;freshlyRead=false;defer{if epoch==generation {loading=false}}
        await service.setAdmissionAllowed(admissionAllowed)
        do {
            let local=try await service.localState(reference);guard epoch==generation else {return};state=local
            guard admissionAllowed else {return}
            let latest=try await service.refresh(reference);guard epoch==generation else {return};state=latest;freshlyRead=await service.isFresh(reference);error=nil
            if let applied=try await service.appliedEnvelope(reference) {await deliver(applied)}
        } catch {if epoch==generation {self.error=error.localizedDescription;freshlyRead=false}}
    }
    func submit(_ action:ConversationTaskControlAction,admissionAllowed:Bool) async {
        guard admissionAllowed,canSubmit(action),let shown=state.latest else {return}
        submitting=true;let epoch=generation;defer{if epoch==generation {submitting=false}}
        await service.setAdmissionAllowed(admissionAllowed)
        do {
            let envelope=try await service.submit(reference,action:action,expectedSnapshotHash:shown.snapshot_hash)
            // Delivery refreshes the existing Task; it cannot manufacture a task or a completion fact.
            await deliver(envelope)
            guard epoch==generation else {return}
            state=try await service.localState(reference);freshlyRead=false;error=nil
        } catch {
            guard epoch==generation else {return}
            if let saved=try? await service.localState(reference){state=saved}
            freshlyRead=false;self.error=error.localizedDescription
        }
    }
    func close(){generation += 1;freshlyRead=false;loading=false;submitting=false}
    private func deliver(_ envelope:ConversationTaskControlEnvelope) async {
        guard let onApplied else {return}
        do {try await onApplied(envelope);deliveryIssue=nil}
        catch {deliveryIssue="控制回执已保存，工作展示尚未更新。请读取最新工作。";self.error=error.localizedDescription}
    }
}
