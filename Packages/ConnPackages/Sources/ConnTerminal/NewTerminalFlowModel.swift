import ConnKit
import ConnMultiplexer
import ConnSSH
import ConnUI
import Foundation
import Observation

public struct NewTerminalFlowCompletion: Sendable, Equatable {
    public let host: ConnKit.Host
    public let tabID: String

    public init(host: ConnKit.Host, tabID: String) {
        self.host = host
        self.tabID = tabID
    }
}

/// Provider-neutral state for creating a local terminal tab before presenting the
/// terminal screen. Remote workspace discovery only exists in the persistent branch.
@Observable
@MainActor
public final class NewTerminalFlowModel {
    public enum Phase: Sendable, Equatable {
        case hostSelection
        case terminalTypeSelection
        case providerLoading
        case providerSelection
        case workspaceSelection
        case creating
    }

    public struct Operations {
        public let loadHosts: @MainActor () throws -> [ConnKit.Host]
        public let persistentBackendCandidates:
            @MainActor (ConnKit.Host) async -> [PersistentBackendCandidate]
        public let persistentWorkspaceOptions:
            @MainActor (PersistentBackendCandidate, ConnKit.Host) async throws -> [RemoteWorkspaceSummary]
        public let makeExistingBackend:
            @MainActor (PersistentBackendCandidate, RemoteWorkspaceRef, ConnKit.Host) async throws -> TerminalLaunchBackend
        public let makeCreateBackend:
            @MainActor (PersistentBackendCandidate, PersistentWorkspaceCreateSelection, ConnKit.Host) async throws -> TerminalLaunchBackend
        public let beginLaunchAttempt: @MainActor () -> TerminalLaunchAttemptID
        public let prepareLaunch:
            @MainActor (TerminalLaunchRequest, TerminalLaunchAttemptID) async -> Result<Void, TerminalLaunchFailure>
        public let commitLaunch:
            @MainActor (TerminalLaunchAttemptID) async -> Result<String, TerminalLaunchFailure>
        public let cancelLaunch: @MainActor (TerminalLaunchAttemptID) async -> Void

        public init(
            loadHosts: @escaping @MainActor () throws -> [ConnKit.Host],
            persistentBackendCandidates: @escaping @MainActor (ConnKit.Host) async -> [PersistentBackendCandidate],
            persistentWorkspaceOptions: @escaping @MainActor (PersistentBackendCandidate, ConnKit.Host) async throws -> [RemoteWorkspaceSummary],
            makeExistingBackend: @escaping @MainActor (PersistentBackendCandidate, RemoteWorkspaceRef, ConnKit.Host) async throws -> TerminalLaunchBackend,
            makeCreateBackend: @escaping @MainActor (PersistentBackendCandidate, PersistentWorkspaceCreateSelection, ConnKit.Host) async throws -> TerminalLaunchBackend,
            beginLaunchAttempt: @escaping @MainActor () -> TerminalLaunchAttemptID,
            prepareLaunch: @escaping @MainActor (TerminalLaunchRequest, TerminalLaunchAttemptID) async -> Result<Void, TerminalLaunchFailure>,
            commitLaunch: @escaping @MainActor (TerminalLaunchAttemptID) async -> Result<String, TerminalLaunchFailure>,
            cancelLaunch: @escaping @MainActor (TerminalLaunchAttemptID) async -> Void
        ) {
            self.loadHosts = loadHosts
            self.persistentBackendCandidates = persistentBackendCandidates
            self.persistentWorkspaceOptions = persistentWorkspaceOptions
            self.makeExistingBackend = makeExistingBackend
            self.makeCreateBackend = makeCreateBackend
            self.beginLaunchAttempt = beginLaunchAttempt
            self.prepareLaunch = prepareLaunch
            self.commitLaunch = commitLaunch
            self.cancelLaunch = cancelLaunch
        }

        public static func live(
            hostRepository: any HostRepository,
            coordinator: TerminalSessionCoordinator
        ) -> Operations {
            Operations(
                loadHosts: { try hostRepository.allHosts() },
                persistentBackendCandidates: { host in
                    await coordinator.persistentBackendCandidates(for: host)
                },
                persistentWorkspaceOptions: { candidate, host in
                    try await coordinator.persistentWorkspaceOptions(for: candidate, host: host)
                },
                makeExistingBackend: { candidate, workspace, host in
                    try await coordinator.makePersistentBackend(
                        from: candidate,
                        workspace: workspace,
                        for: host
                    )
                },
                makeCreateBackend: { candidate, selection, host in
                    try await coordinator.makePersistentBackend(
                        from: candidate,
                        create: selection,
                        for: host
                    )
                },
                beginLaunchAttempt: { coordinator.beginLaunchAttempt() },
                prepareLaunch: { request, attemptID in
                    await coordinator.prepareLaunch(request, attemptID: attemptID)
                },
                commitLaunch: { attemptID in
                    switch await coordinator.commitLaunch(attemptID: attemptID) {
                    case let .success(tab): .success(tab.id)
                    case let .failure(failure): .failure(failure)
                    }
                },
                cancelLaunch: { attemptID in
                    await coordinator.cancelLaunch(attemptID: attemptID)
                }
            )
        }
    }

    public private(set) var phase: Phase
    public private(set) var hosts: [ConnKit.Host] = []
    public private(set) var selectedHost: ConnKit.Host?
    public private(set) var candidates: [PersistentBackendCandidate] = []
    public private(set) var selectedCandidate: PersistentBackendCandidate?
    public private(set) var workspaces: [RemoteWorkspaceSummary] = []
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false
    public private(set) var isCreating = false
    public private(set) var errorMessage: String?

    public var usableCandidates: [PersistentBackendCandidate] {
        candidates.filter { candidate in
            candidate.availability == .available || candidate.availability == .degraded
        }
    }

    private let operations: Operations
    @ObservationIgnored private let onCompleted: @MainActor (NewTerminalFlowCompletion) -> Void
    private var generation: UInt64 = 0
    private var activeAttemptID: TerminalLaunchAttemptID?
    @ObservationIgnored private var activeOperationTask: Task<Void, Never>?
    private var activeOperationToken: UUID?
    private var closed = false
    private var didComplete = false
    private let hasFixedHost: Bool

    public init(
        fixedHost: ConnKit.Host?,
        operations: Operations,
        onCompleted: @escaping @MainActor (NewTerminalFlowCompletion) -> Void
    ) {
        selectedHost = fixedHost
        phase = fixedHost == nil ? .hostSelection : .terminalTypeSelection
        self.operations = operations
        self.onCompleted = onCompleted
        hasFixedHost = fixedHost != nil
    }

    public func start() {
        guard !closed, selectedHost == nil else { return }
        do {
            hosts = try operations.loadHosts()
            errorMessage = nil
        } catch {
            hosts = []
            errorMessage = diagnosis(for: error)
        }
        phase = .hostSelection
    }

    public func selectHost(_ host: ConnKit.Host) {
        guard !closed else { return }
        generation &+= 1
        selectedHost = host
        candidates = []
        selectedCandidate = nil
        workspaces = []
        errorMessage = nil
        phase = .terminalTypeSelection
    }

    public func selectPlainPTY() async {
        await runTrackedOperation { model in
            await model.launch(backend: .plainPTY, failurePhase: .terminalTypeSelection)
        }
    }

    public func selectPersistent() async {
        await runTrackedOperation { model in
            await model.performPersistentSelection()
        }
    }

    private func performPersistentSelection() async {
        guard !closed, let host = selectedHost else { return }
        generation &+= 1
        let loadingGeneration = generation
        errorMessage = nil
        isLoading = true
        phase = .providerLoading

        let loadedCandidates = await operations.persistentBackendCandidates(host)
        guard isCurrent(loadingGeneration) else { return }
        candidates = loadedCandidates
        isLoading = false

        let usable = usableCandidates
        guard !usable.isEmpty else {
            selectedCandidate = nil
            workspaces = []
            phase = .providerSelection
            let diagnoses = loadedCandidates.compactMap { $0.issue?.userFacingDiagnosis }
            errorMessage = diagnoses.isEmpty
                ? L("没有可用的持久终端")
                : diagnoses.joined(separator: "\n")
            return
        }

        if usable.count == 1, let candidate = usable.first {
            await loadWorkspaces(
                for: candidate,
                host: host,
                generation: loadingGeneration,
                preserveExisting: false
            )
        } else {
            selectedCandidate = nil
            workspaces = []
            phase = .providerSelection
        }
    }

    public func selectCandidate(_ candidate: PersistentBackendCandidate) async {
        await runTrackedOperation { model in
            await model.performCandidateSelection(candidate)
        }
    }

    private func performCandidateSelection(_ candidate: PersistentBackendCandidate) async {
        guard !closed, let host = selectedHost, usableCandidates.contains(candidate) else { return }
        generation &+= 1
        let loadingGeneration = generation
        errorMessage = nil
        await loadWorkspaces(
            for: candidate,
            host: host,
            generation: loadingGeneration,
            preserveExisting: false
        )
    }

    public func refresh() async {
        await runTrackedOperation { model in
            await model.performRefresh()
        }
    }

    private func performRefresh() async {
        guard !closed, let host = selectedHost else { return }
        generation &+= 1
        let refreshGeneration = generation
        isRefreshing = true
        errorMessage = nil

        let refreshedCandidates = await operations.persistentBackendCandidates(host)
        guard isCurrent(refreshGeneration) else { return }
        candidates = refreshedCandidates
        let usable = usableCandidates
        guard !usable.isEmpty else {
            isRefreshing = false
            selectedCandidate = nil
            phase = .providerSelection
            let diagnoses = refreshedCandidates.compactMap { $0.issue?.userFacingDiagnosis }
            errorMessage = diagnoses.isEmpty
                ? L("没有可用的持久终端")
                : diagnoses.joined(separator: "\n")
            return
        }

        let refreshedSelection = selectedCandidate.flatMap { selected in
            usable.first { $0.profileID == selected.profileID && $0.providerID == selected.providerID }
        } ?? (usable.count == 1 ? usable.first : nil)
        guard let refreshedSelection else {
            isRefreshing = false
            selectedCandidate = nil
            phase = .providerSelection
            return
        }
        await loadWorkspaces(
            for: refreshedSelection,
            host: host,
            generation: refreshGeneration,
            preserveExisting: true
        )
    }

    public func attach(_ workspace: RemoteWorkspaceSummary) async {
        await runTrackedOperation { model in
            await model.performAttach(workspace)
        }
    }

    private func performAttach(_ workspace: RemoteWorkspaceSummary) async {
        guard !closed,
              let host = selectedHost,
              let candidate = selectedCandidate,
              workspaces.contains(workspace)
        else { return }
        generation &+= 1
        let descriptorGeneration = generation
        isCreating = true
        errorMessage = nil
        phase = .creating
        do {
            let backend = try await operations.makeExistingBackend(
                candidate,
                workspace.workspace,
                host
            )
            guard isCurrent(descriptorGeneration) else { return }
            isCreating = false
            await launch(backend: backend, failurePhase: .workspaceSelection)
        } catch {
            guard isCurrent(descriptorGeneration) else { return }
            isCreating = false
            phase = .workspaceSelection
            errorMessage = diagnosis(for: error)
        }
    }

    public func createWorkspace(name: String?) async {
        await runTrackedOperation { model in
            await model.performCreateWorkspace(name: name)
        }
    }

    private func performCreateWorkspace(name: String?) async {
        guard !closed, let host = selectedHost, let candidate = selectedCandidate else { return }
        let cleanedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        generation &+= 1
        let descriptorGeneration = generation
        isCreating = true
        errorMessage = nil
        phase = .creating
        do {
            let backend = try await operations.makeCreateBackend(
                candidate,
                PersistentWorkspaceCreateSelection(name: cleanedName),
                host
            )
            guard isCurrent(descriptorGeneration) else { return }
            isCreating = false
            await launch(backend: backend, failurePhase: .workspaceSelection)
        } catch {
            guard isCurrent(descriptorGeneration) else { return }
            isCreating = false
            phase = .workspaceSelection
            errorMessage = diagnosis(for: error)
        }
    }

    public func back() async {
        guard !closed, !didComplete else { return }
        cancelActiveOperation()
        generation &+= 1
        if let activeAttemptID {
            self.activeAttemptID = nil
            await operations.cancelLaunch(activeAttemptID)
        }
        isLoading = false
        isRefreshing = false
        isCreating = false
        errorMessage = nil
        switch phase {
        case .hostSelection:
            break
        case .terminalTypeSelection:
            if !hasFixedHost {
                selectedHost = nil
                phase = .hostSelection
            }
        case .providerLoading, .providerSelection, .workspaceSelection, .creating:
            candidates = []
            selectedCandidate = nil
            workspaces = []
            phase = .terminalTypeSelection
        }
    }

    public func close() async {
        await closeImmediately()?.value
    }

    /// Invalidates the UI generation synchronously so a Close tap wins before any
    /// already-enqueued MainActor continuation can commit or emit completion.
    @discardableResult
    public func closeImmediately() -> Task<Void, Never>? {
        guard !closed else { return nil }
        closed = true
        cancelActiveOperation()
        generation &+= 1
        guard let activeAttemptID else { return nil }
        self.activeAttemptID = nil
        return Task { @MainActor [operations] in
            await operations.cancelLaunch(activeAttemptID)
        }
    }

    private func launch(
        backend: TerminalLaunchBackend,
        failurePhase: Phase
    ) async {
        guard !closed, !didComplete, let host = selectedHost else { return }
        generation &+= 1
        let launchGeneration = generation
        errorMessage = nil
        isCreating = true
        phase = .creating

        // Registration is intentionally synchronous and happens before this method's
        // first suspension, so close() always has an attempt to cancel.
        let attemptID = operations.beginLaunchAttempt()
        activeAttemptID = attemptID
        let request = TerminalLaunchRequest(
            host: host,
            policy: .createNew,
            source: .shell,
            backend: backend
        )

        switch await operations.prepareLaunch(request, attemptID) {
        case .success:
            guard isCurrent(launchGeneration, attemptID: attemptID) else {
                await operations.cancelLaunch(attemptID)
                return
            }
            switch await operations.commitLaunch(attemptID) {
            case let .success(tabID):
                guard isCurrent(launchGeneration, attemptID: attemptID) else { return }
                activeAttemptID = nil
                isCreating = false
                didComplete = true
                onCompleted(NewTerminalFlowCompletion(host: host, tabID: tabID))
            case let .failure(failure):
                finishLaunchFailure(
                    failure,
                    phase: failurePhase,
                    generation: launchGeneration,
                    attemptID: attemptID
                )
            }
        case let .failure(failure):
            finishLaunchFailure(
                failure,
                phase: failurePhase,
                generation: launchGeneration,
                attemptID: attemptID
            )
        }
    }

    private func runTrackedOperation(
        _ operation: @escaping @MainActor (NewTerminalFlowModel) async -> Void
    ) async {
        guard !closed, !didComplete else { return }
        cancelActiveOperation()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await operation(self)
        }
        activeOperationToken = token
        activeOperationTask = task
        await task.value
        if activeOperationToken == token {
            activeOperationToken = nil
            activeOperationTask = nil
        }
    }

    private func cancelActiveOperation() {
        activeOperationTask?.cancel()
        activeOperationTask = nil
        activeOperationToken = nil
    }

    private func diagnosis(for error: any Error) -> String {
        terminalUserFacingDiagnosis(error)
    }

    private func isCurrent(
        _ expectedGeneration: UInt64,
        attemptID: TerminalLaunchAttemptID
    ) -> Bool {
        !closed && generation == expectedGeneration && activeAttemptID == attemptID
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        !closed && generation == expectedGeneration
    }

    private func loadWorkspaces(
        for candidate: PersistentBackendCandidate,
        host: ConnKit.Host,
        generation expectedGeneration: UInt64,
        preserveExisting: Bool
    ) async {
        selectedCandidate = candidate
        isLoading = !preserveExisting
        isRefreshing = preserveExisting
        phase = .workspaceSelection
        do {
            let loadedWorkspaces = try await operations.persistentWorkspaceOptions(candidate, host)
            guard isCurrent(expectedGeneration) else { return }
            workspaces = loadedWorkspaces
            errorMessage = nil
        } catch {
            guard isCurrent(expectedGeneration) else { return }
            if !preserveExisting { workspaces = [] }
            errorMessage = diagnosis(for: error)
        }
        guard isCurrent(expectedGeneration) else { return }
        isLoading = false
        isRefreshing = false
    }

    private func finishLaunchFailure(
        _ failure: TerminalLaunchFailure,
        phase failurePhase: Phase,
        generation expectedGeneration: UInt64,
        attemptID: TerminalLaunchAttemptID
    ) {
        guard isCurrent(expectedGeneration, attemptID: attemptID) else { return }
        activeAttemptID = nil
        isCreating = false
        phase = failurePhase
        errorMessage = failure.message
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
