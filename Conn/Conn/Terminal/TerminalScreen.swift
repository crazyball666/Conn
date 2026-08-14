import ConnKit
import ConnMultiplexer
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 一个已存在或即将创建的全局终端会话的全屏呈现。
///
/// 返回只关闭这个界面；只有「退出」才会关闭对应 PTY。SSH 连接由全局连接池继续复用。
struct TerminalScreen: View {
    private enum LaunchIntent: Equatable {
        case initial
        case additional
    }

    private struct LaunchContext {
        let policy: TerminalLaunchPolicy
        let source: TerminalSessionSource
        let initialCommand: String?
        let replayInitialCommandOnReconnect: Bool
        let dismissOnFailure: Bool

        func replacingPolicy(with policy: TerminalLaunchPolicy) -> Self {
            Self(
                policy: policy,
                source: source,
                initialCommand: initialCommand,
                replayInitialCommandOnReconnect: replayInitialCommandOnReconnect,
                dismissOnFailure: dismissOnFailure
            )
        }
    }

    let host: Host
    private let terminalSessions: TerminalSessionCoordinator
    private let snippetRepository: (any SnippetRepository)?
    private let snippetGroupRepository: (any SnippetGroupRepository)?
    private let launchPolicy: TerminalLaunchPolicy
    private let source: TerminalSessionSource
    private let requestedBackend: TerminalLaunchBackend?
    private let initialCommand: String?
    private let replayInitialCommandOnReconnect: Bool

    @State private var tabID: String?
    @State private var isLaunching = false
    @State private var isReconnecting = false
    @State private var isCommandPickerPresented = false
    @State private var isSessionListPresented = false
    @State private var isBackendPickerPresented = false
    @State private var isWorkspacePickerPresented = false
    @State private var backendCandidates: [PersistentBackendCandidate] = []
    @State private var selectedBackendCandidate: PersistentBackendCandidate?
    @State private var persistentWorkspaces: [RemoteWorkspaceSummary] = []
    @State private var isLoadingPersistentWorkspaces = false
    @State private var pendingLaunchContext: LaunchContext?
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        dependencies: AppDependencies,
        terminalSessions: TerminalSessionCoordinator? = nil,
        launchPolicy: TerminalLaunchPolicy = .reuseRecentOrCreate,
        source: TerminalSessionSource = .shell,
        backend: TerminalLaunchBackend? = nil,
        initialCommand: String? = nil,
        replayInitialCommandOnReconnect: Bool = false
    ) {
        self.host = host
        self.terminalSessions = terminalSessions ?? dependencies.terminalSessions
        snippetRepository = dependencies.snippetRepository
        snippetGroupRepository = dependencies.snippetGroupRepository
        self.launchPolicy = launchPolicy
        self.source = source
        requestedBackend = backend
        self.initialCommand = initialCommand
        self.replayInitialCommandOnReconnect = replayInitialCommandOnReconnect
    }

    var body: some View {
        NavigationStack {
            terminalContent
                .navigationTitle(hostTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(hostTitle)
                                .font(.headline)
                                .foregroundStyle(.connInk)
                                .lineLimit(1)
                            Text(sessionSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.connMuted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 220)
                        .accessibilityElement(children: .combine)
                    }
                    terminalToolbar
                }
        }
        .preferredColorScheme(.dark)
        .task { await launchIfNeeded() }
        .sheet(isPresented: $isCommandPickerPresented) {
            if let snippetRepository, let snippetGroupRepository {
                TerminalCommandPickerView(
                    repository: snippetRepository,
                    groupRepository: snippetGroupRepository,
                    onSelect: insertCommand
                )
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isSessionListPresented) {
            TerminalSessionListSheet(
                host: host,
                store: terminalSessions.store,
                selectedTabID: tabID,
                onSelect: { selectedID in
                    terminalSessions.store.select(selectedID)
                    tabID = selectedID
                    isSessionListPresented = false
                },
                onCreate: {
                    isSessionListPresented = false
                    Task { await beginLaunchChoice(for: .additional) }
                },
                onRename: { id, alias in
                    terminalSessions.store.updateAlias(id, to: alias)
                },
                onClose: { id in
                    Task {
                        await terminalSessions.close(id)
                        if tabID == id {
                            tabID = terminalSessions.store.recentTab(forHost: host.id)?.id
                            if tabID == nil { dismiss() }
                        }
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isBackendPickerPresented) {
            TerminalBackendPicker(
                candidates: backendCandidates,
                onPlainPTY: { choosePlainPTY() },
                onPersistent: { candidate in choosePersistent(candidate) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isWorkspacePickerPresented) {
            if let selectedBackendCandidate {
                PersistentWorkspacePicker(
                    candidate: selectedBackendCandidate,
                    workspaces: persistentWorkspaces,
                    isLoading: isLoadingPersistentWorkspaces,
                    onPlainPTY: {
                        isWorkspacePickerPresented = false
                        choosePlainPTY()
                    },
                    onExisting: { workspace in
                        attachPersistentWorkspace(workspace, candidate: selectedBackendCandidate)
                    },
                    onCreate: { name in
                        createPersistentWorkspace(name: name, candidate: selectedBackendCandidate)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
        }
    }

    private var activeTab: TerminalTab? {
        guard let tabID else { return nil }
        return terminalSessions.store.tab(id: tabID)
    }

    private var hostTitle: String {
        let name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? host.address : name
    }

    private var sessionSubtitle: String {
        activeTab?.displayName ?? L("终端")
    }

    @ViewBuilder
    private var terminalContent: some View {
        let configuration = settings.terminalConfiguration
        ZStack {
            terminalColor(configuration.theme.background).ignoresSafeArea()
            if let tab = activeTab {
                TerminalHostingView(
                    session: tab.session,
                    transcript: tab.transcript,
                    configuration: configuration,
                    onChooseCommand: showCommandPicker,
                    onReconnect: { Task { await reconnect(tab.id) } }
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay(alignment: .top) {
                    if case let .disconnected(message) = tab.status {
                        reconnectNotice(message)
                    } else if case .reconnecting = tab.status {
                        ProgressView(L("正在重新连接…"))
                            .tint(.connAccent)
                            .padding(ConnSpacing.sm)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(.top, ConnSpacing.xs)
                    }
                }
            } else if isLaunching {
                ProgressView(String(format: L("正在连接 %@…"), host.name))
                    .tint(.connAccent)
                    .foregroundStyle(.connMuted)
            }
        }
    }

    @ToolbarContentBuilder
    private var terminalToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel(L("返回"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                guard let tabID else { dismiss(); return }
                Task {
                    await terminalSessions.close(tabID)
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel(L("退出终端"))

            Button { isSessionListPresented = true } label: {
                Image(systemName: "rectangle.stack")
            }
            .accessibilityLabel(L("会话列表"))
        }
    }

    private func reconnectNotice(_ message: String?) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.connWarn)
            Text(message ?? L("终端连接已断开"))
                .font(.connFootnote)
                .lineLimit(2)
            Button(L("重连")) {
                if let tabID { Task { await reconnect(tabID) } }
            }
            .buttonStyle(.bordered)
            .disabled(isReconnecting)
        }
        .foregroundStyle(.white)
        .padding(ConnSpacing.sm)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: ConnRadius.control))
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
    }

    private func terminalColor(_ rgb: TerminalTheme.RGB) -> Color {
        Color(
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255
        )
    }

    private func launchIfNeeded() async {
        guard tabID == nil, !isLaunching, pendingLaunchContext == nil else { return }
        await beginLaunchChoice(for: .initial)
    }

    private func beginLaunchChoice(for intent: LaunchIntent) async {
        guard !isLaunching, pendingLaunchContext == nil else { return }
        let context: LaunchContext = switch intent {
        case .initial:
            LaunchContext(
                policy: launchPolicy,
                source: source,
                initialCommand: initialCommand,
                replayInitialCommandOnReconnect: replayInitialCommandOnReconnect,
                dismissOnFailure: true
            )
        case .additional:
            LaunchContext(
                policy: .createNew,
                source: .shell,
                initialCommand: nil,
                replayInitialCommandOnReconnect: false,
                dismissOnFailure: false
            )
        }
        pendingLaunchContext = context

        let explicitBackend = intent == .initial ? requestedBackend : nil
        let shouldOfferBackendPicker: Bool = switch context.policy {
        case .existing:
            false
        case .reuseRecentOrCreate, .createNew:
            true
        }
        if explicitBackend == nil,
           context.source == .shell,
           shouldOfferBackendPicker {
            let candidates = await terminalSessions.persistentBackendCandidates(for: host)
                .filter { $0.availability == .available || $0.availability == .degraded }
            if !candidates.isEmpty {
                // Once the user is asked to choose PTY/tmux, that choice is an explicit
                // request for a new tab. Reusing a recent tab here would silently discard
                // the selected backend or remote workspace.
                pendingLaunchContext = context.replacingPolicy(with: .createNew)
                backendCandidates = candidates
                isBackendPickerPresented = true
                return
            }
        }
        await launch(backend: explicitBackend ?? .plainPTY, context: context)
    }

    private func launch(
        backend: TerminalLaunchBackend,
        context: LaunchContext
    ) async {
        isLaunching = true
        defer {
            isLaunching = false
            pendingLaunchContext = nil
        }
        let request = TerminalLaunchRequest(
            host: host,
            policy: context.policy,
            source: context.source,
            backend: backend,
            initialCommand: context.initialCommand,
            replayInitialCommandOnReconnect: context.replayInitialCommandOnReconnect
        )
        switch await terminalSessions.launch(request) {
        case let .success(tab):
            tabID = tab.id
        case let .failure(failure):
            show(failure)
            if context.dismissOnFailure { dismiss() }
        }
    }

    private func choosePlainPTY() {
        guard let context = pendingLaunchContext else { return }
        isBackendPickerPresented = false
        Task { await launch(backend: .plainPTY, context: context) }
    }

    private func choosePersistent(_ candidate: PersistentBackendCandidate) {
        isBackendPickerPresented = false
        selectedBackendCandidate = candidate
        persistentWorkspaces = []
        isLoadingPersistentWorkspaces = true
        isWorkspacePickerPresented = true
        Task {
            do {
                persistentWorkspaces = try await terminalSessions.persistentWorkspaceOptions(
                    for: candidate,
                    host: host
                )
            } catch {
                // A server can disappear between probe and selection. The user chose
                // tmux explicitly, so report the failure instead of silently changing
                // the remote lifecycle to a plain shell.
                isWorkspacePickerPresented = false
                pendingLaunchContext = nil
                show(TerminalLaunchFailure(message: error.friendlyDiagnosis))
            }
            isLoadingPersistentWorkspaces = false
        }
    }

    private func attachPersistentWorkspace(
        _ workspace: RemoteWorkspaceSummary,
        candidate: PersistentBackendCandidate
    ) {
        guard let context = pendingLaunchContext else { return }
        isWorkspacePickerPresented = false
        Task {
            do {
                let backend = try await terminalSessions.makePersistentBackend(
                    from: candidate,
                    workspace: workspace.workspace,
                    for: host
                )
                await launch(backend: backend, context: context)
            } catch {
                pendingLaunchContext = nil
                show(TerminalLaunchFailure(message: error.friendlyDiagnosis))
            }
        }
    }

    private func createPersistentWorkspace(
        name: String?,
        candidate: PersistentBackendCandidate
    ) {
        guard let context = pendingLaunchContext else { return }
        isWorkspacePickerPresented = false
        Task {
            do {
                let backend = try await terminalSessions.makePersistentBackend(
                    from: candidate,
                    create: PersistentWorkspaceCreateSelection(name: name),
                    for: host
                )
                await launch(backend: backend, context: context)
            } catch {
                pendingLaunchContext = nil
                show(TerminalLaunchFailure(message: error.friendlyDiagnosis))
            }
        }
    }

    private func reconnect(_ id: String) async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        if case let .failure(failure) = await terminalSessions.reconnect(id) {
            show(failure)
        }
    }

    private func show(_ failure: TerminalLaunchFailure) {
        if let message = terminalSessions.consumeFailure(failure) {
            toastCenter.show(message)
        }
    }

    private func showCommandPicker() {
        guard snippetRepository != nil, snippetGroupRepository != nil else { return }
        isCommandPickerPresented = true
    }

    /// 本地脚本只写入当前 PTY，用户仍需在终端里自行确认并执行。
    private func insertCommand(_ command: String) {
        isCommandPickerPresented = false
        guard let tab = activeTab else { return }
        Task { try? await tab.session.send(Array(command.utf8)) }
    }
}

private struct TerminalBackendPicker: View {
    let candidates: [PersistentBackendCandidate]
    let onPlainPTY: () -> Void
    let onPersistent: (PersistentBackendCandidate) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(L("终端类型")) {
                    Button(action: onPlainPTY) {
                        Label(L("普通 PTY"), systemImage: "terminal")
                    }
                    ForEach(candidates) { candidate in
                        Button { onPersistent(candidate) } label: {
                            Label(candidate.displayName, systemImage: "rectangle.connected.to.line.below")
                        }
                    }
                }
            }
            .navigationTitle(L("启动终端"))
        }
    }
}

private struct PersistentWorkspacePicker: View {
    let candidate: PersistentBackendCandidate
    let workspaces: [RemoteWorkspaceSummary]
    let isLoading: Bool
    let onPlainPTY: () -> Void
    let onExisting: (RemoteWorkspaceSummary) -> Void
    let onCreate: (String?) -> Void

    @State private var newWorkspaceName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: onPlainPTY) {
                        Label(L("普通 PTY"), systemImage: "terminal")
                    }
                }

                Section(L("Attach 已有 Session")) {
                    if isLoading {
                        HStack(spacing: ConnSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text(L("正在读取远端 Session…"))
                                .foregroundStyle(.connMuted)
                        }
                    } else if workspaces.isEmpty {
                        Text(L("当前没有已存在的 Session"))
                            .foregroundStyle(.connMuted)
                    } else {
                        ForEach(workspaces, id: \.workspace.workspaceID) { workspace in
                            Button { onExisting(workspace) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workspace.name)
                                            .foregroundStyle(.connInk)
                                        Text(String(format: L("远端 Session · %@"), workspace.workspace.workspaceID))
                                            .font(.connData(.caption2))
                                            .foregroundStyle(.connMuted)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app")
                                        .foregroundStyle(.connMuted)
                                }
                            }
                        }
                    }
                }

                Section(L("新建 Session")) {
                    TextField(L("Session 名称（可选）"), text: $newWorkspaceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(name.isEmpty ? nil : name)
                    } label: {
                        Label(L("新建并进入"), systemImage: "plus.rectangle")
                    }
                    .disabled(isLoading)
                }
            }
            .navigationTitle(candidate.displayName)
        }
    }
}
