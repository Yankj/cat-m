import Foundation

// Legacy ProviderEvent bridge is admission/status-only. Rich immutable projection stays in OpenMuseTaskService.
// No frozen AG-UI chat HTTP route exists: reply() explicitly refuses rather than guessing a wire endpoint.
public actor OpenMuseAgentProvider: AgentProvider {
    public static let providerID = "catpaw.openmuse.tasks.v1"
    private let service: OpenMuseTaskService
    private var sequences: [UUID: Int] = [:]
    public init(service: OpenMuseTaskService) { self.service = service }
    public func descriptor() async -> ProviderDescriptor {
        ProviderDescriptor(id: Self.providerID, version: "catpaw.facade.v1", capabilities: [
            ProviderCapability(capabilityID: "persistent_task_admission", availability: service.provenance == .fixtureTransport ? .fixtureAvailable : .unverified, requiredAuthorizationKinds: []),
            ProviderCapability(capabilityID: "original_task_status_read", availability: service.provenance == .fixtureTransport ? .fixtureAvailable : .unverified, requiredAuthorizationKinds: [])])
    }
    public static func nativeTaskID(operationID: UUID) -> UUID { stableID("openmuse-native-task-\(operationID)") }
    private func context(_ context: ProviderContext) async throws -> OpenMuseTaskSession {
        let value = try await service.session(operationID: context.operationID, scope: context.scope)
        guard context.providerID == Self.providerID, context.environmentID == value.request.input.environmentID,
              context.runtimeEpoch == value.observationEpoch else { throw CatpawError.scopeMismatch }
        return value
    }
    private func event(_ session: OpenMuseTaskSession, context: ProviderContext, payload: ProviderEventPayload) -> ProviderEvent {
        let sequence = (sequences[context.operationID] ?? 0) + 1; sequences[context.operationID] = sequence
        return ProviderEvent(operationID: context.operationID, sequence: sequence, runtimeEpoch: context.runtimeEpoch,
                             reality: service.provenance == .cloudIntelligence ? .remoteAccepted : .simulated, payload: payload)
    }
    public func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        throw CatpawError.unavailable("Native AG-UI chat wire/connect is unverified; the frozen facade only supports persistent Task HTTP reads.")
    }
    public func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        let value = try await context(request.context)
        guard request.taskID == Self.nativeTaskID(operationID: request.context.operationID), request.taskRevision == value.request.input.delegationRevision else { throw CatpawError.scopeMismatch }
        let admitted = try await service.admit(operationID: request.context.operationID, scope: request.context.scope)
        guard let task = admitted.serverTaskID, admitted.admission == .accepted else { throw CatpawError.unavailable("Original task admission is unresolved.") }
        let accepted = event(admitted, context: request.context, payload: .accepted(providerOperationID: task))
        return AsyncThrowingStream { continuation in continuation.yield(accepted); continuation.finish() }
        // Admission EOF is intentionally not taskCompleted/messageCompleted. Call observe or the richer Task service.
    }
    public func observe(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent {
        guard operationID == context.operationID else { throw CatpawError.scopeMismatch }
        _ = try await self.context(context)
        let current = try await service.refresh(operationID: operationID, scope: context.scope)
        if current.control != .active || current.projection?.status == .outcomeUnknown {
            return event(current, context: context, payload: .outcomeUnknown)
        }
        return event(current, context: context, payload: .progress(ProgressSnapshot(label: current.projection?.status.rawValue ?? "unresolved_original_task", completedUnits: nil, totalUnits: nil)))
    }
    public func cancel(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent {
        guard operationID == context.operationID else { throw CatpawError.scopeMismatch }; _ = try await self.context(context)
        try await service.stopObserving(operationID: operationID, scope: context.scope)
        let stopped = try await service.session(operationID: operationID, scope: context.scope)
        return event(stopped, context: context, payload: .outcomeUnknown) // no remote cancellation claim
    }
}
