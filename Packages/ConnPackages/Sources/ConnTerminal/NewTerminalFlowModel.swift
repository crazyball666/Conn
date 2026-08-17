import ConnKit
import ConnMultiplexer
import ConnSSH
import ConnUI
import Foundation
import Observation

public struct NewTerminalFlowCompletion: Sendable, Equatable {
    public let host: ConnKit.Host
    public let tabID: String
    public let notice: String?

    public init(host: ConnKit.Host, tabID: String, notice: String? = nil) {
        self.host = host
        self.tabID = tabID
        self.notice = notice
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
        public let persistentBackendOptions:
            @MainActor () -> [PersistentBackendOption]
        public let persistentWorkspaceOptions:
            @MainActor (PersistentBackendOption, ConnKit.Host) async throws -> [RemoteWorkspaceSummary]
        public let makeExistingBackend:
            @MainActor (PersistentBackendOption, RemoteWorkspaceSummary, ConnKit.Host) async throws -> PersistentTerminalLaunch
        public let makeCreateBackend:
            @MainActor (PersistentBackendOption, PersistentWorkspaceCreateSelection, ConnKit.Host) async throws -> PersistentTerminalLaunch
        public let beginLaunchAttempt: @MainActor () -> TerminalLaunchAttemptID
        public let prepareLaunch:
            @MainActor (TerminalLaunchRequest, TerminalLaunchAttemptID) async -> Result<Void, TerminalLaunchFailure>
        public let commitLaunch:
            @MainActor (TerminalLaunchAttemptID) async -> Result<String, TerminalLaunchFailure>
        public let cancelLaunch: @MainActor (TerminalLaunchAttemptID) async -> Void

        public init(
            loadHosts: @escaping @MainActor () throws -> [ConnKit.Host],
            persistentBackendOptions: @escaping @MainActor () -> [PersistentBackendOption],
            persistentWorkspaceOptions: @escaping @MainActor (PersistentBackendOption, ConnKit.Host) async throws -> [RemoteWorkspaceSummary],
            makeExistingBackend: @escaping @MainActor (PersistentBackendOption, RemoteWorkspaceSummary, ConnKit.Host) async throws -> PersistentTerminalLaunch,
            makeCreateBackend: @escaping @MainActor (PersistentBackendOption, PersistentWorkspaceCreateSelection, ConnKit.Host) async throws -> PersistentTerminalLaunch,
            beginLaunchAttempt: @escaping @MainActor () -> TerminalLaunchAttemptID,
            prepareLaunch: @escaping @MainActor (TerminalLaunchRequest, TerminalLaunchAttemptID) async -> Result<Void, TerminalLaunchFailure>,
            commitLaunch: @escaping @MainActor (TerminalLaunchAttemptID) async -> Result<String, TerminalLaunchFailure>,
            cancelLaunch: @escaping @MainActor (TerminalLaunchAttemptID) async -> Void
        ) {
            self.loadHosts = loadHosts
            self.persistentBackendOptions = persistentBackendOptions
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
                persistentBackendOptions: {
                    coordinator.persistentBackendOptions()
                },
                persistentWorkspaceOptions: { option, host in
                    try await coordinator.persistentWorkspaceOptions(for: option, host: host)
                },
                makeExistingBackend: { option, workspace, host in
                    try await coordinator.makePersistentBackend(
                        from: option,
                        workspace: workspace,
                        for: host
                    )
                },
                makeCreateBackend: { option, selection, host in
                    try await coordinator.makePersistentBackend(
                        from: option,
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
    public private(set) var options: [PersistentBackendOption] = []
    public private(set) var selectedOption: PersistentBackendOption?
    public private(set) var workspaces: [RemoteWorkspaceSummary] = []
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false
    public private(set) var isCreating = false
    public private(set) var errorMessage: String?

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
        options = []
        selectedOption = nil
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

        let loadedOptions = operations.persistentBackendOptions()
        guard isCurrent(loadingGeneration) else { return }
        options = loadedOptions
        isLoading = false

        guard !loadedOptions.isEmpty else {
            selectedOption = nil
            workspaces = []
            phase = .providerSelection
            errorMessage = L("没有可用的持久终端")
            return
        }

        if loadedOptions.count == 1, let option = loadedOptions.first {
            await loadWorkspaces(
                for: option,
                host: host,
                generation: loadingGeneration,
                preserveExisting: false
            )
        } else {
            selectedOption = nil
            workspaces = []
            phase = .providerSelection
        }
    }

    public func selectOption(_ option: PersistentBackendOption) async {
        await runTrackedOperation { model in
            await model.performOptionSelection(option)
        }
    }

    private func performOptionSelection(_ option: PersistentBackendOption) async {
        guard !closed, let host = selectedHost, options.contains(option) else { return }
        generation &+= 1
        let loadingGeneration = generation
        errorMessage = nil
        await loadWorkspaces(
            for: option,
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

        guard let selectedOption else {
            isRefreshing = false
            phase = .providerSelection
            return
        }
        await loadWorkspaces(
            for: selectedOption,
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
              let option = selectedOption,
              workspaces.contains(workspace)
        else { return }
        generation &+= 1
        let descriptorGeneration = generation
        isCreating = true
        errorMessage = nil
        phase = .creating
        do {
            let persistentLaunch = try await operations.makeExistingBackend(
                option,
                workspace,
                host
            )
            guard isCurrent(descriptorGeneration) else { return }
            isCreating = false
            await launch(
                backend: .persistent(persistentLaunch.descriptor),
                failurePhase: .workspaceSelection,
                automaticAlias: persistentLaunch.workspaceName
            )
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
        guard !closed, let host = selectedHost, let option = selectedOption else { return }
        let cleanedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        generation &+= 1
        let descriptorGeneration = generation
        isCreating = true
        errorMessage = nil
        phase = .creating
        do {
            let persistentLaunch = try await operations.makeCreateBackend(
                option,
                PersistentWorkspaceCreateSelection(name: cleanedName),
                host
            )
            guard isCurrent(descriptorGeneration) else { return }
            isCreating = false
            await launch(
                backend: .persistent(persistentLaunch.descriptor),
                failurePhase: .workspaceSelection,
                automaticAlias: persistentLaunch.workspaceName
            )
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
            options = []
            selectedOption = nil
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
        failurePhase: Phase,
        automaticAlias: String? = nil,
        notice: String? = nil
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
            backend: backend,
            automaticAlias: automaticAlias
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
                onCompleted(NewTerminalFlowCompletion(host: host, tabID: tabID, notice: notice))
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
        for option: PersistentBackendOption,
        host: ConnKit.Host,
        generation expectedGeneration: UInt64,
        preserveExisting: Bool
    ) async {
        selectedOption = option
        isLoading = !preserveExisting
        isRefreshing = preserveExisting
        phase = .workspaceSelection
        do {
            let loadedWorkspaces = try await operations.persistentWorkspaceOptions(option, host)
            guard isCurrent(expectedGeneration) else { return }
            workspaces = loadedWorkspaces
            errorMessage = nil
        } catch {
            guard isCurrent(expectedGeneration) else { return }
            if shouldFallBackToPlainPTY(for: error) {
                isLoading = false
                isRefreshing = false
                await launch(
                    backend: .plainPTY,
                    failurePhase: .terminalTypeSelection,
                    notice: String(
                        format: L("%@ 不可用，已改用普通终端"),
                        option.displayName
                    )
                )
                return
            }
            if !preserveExisting { workspaces = [] }
            errorMessage = diagnosis(for: error)
        }
        guard isCurrent(expectedGeneration) else { return }
        isLoading = false
        isRefreshing = false
    }

    private func shouldFallBackToPlainPTY(for error: any Error) -> Bool {
        guard let issue = error as? PersistentTerminalError else { return false }
        return switch issue {
        case .executableMissing, .unsupportedPlatform:
            true
        default:
            false
        }
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
