import ConnKit
import ConnEntitlement
import ConnMultiplexer
import ConnSSH
import ConnTerminal
import ConnUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Presents an already-created local tab. Backend selection and initial launch are
/// intentionally owned by the source page before this screen is shown.
struct TerminalScreen: View {
    let host: Host
    let dependencies: AppDependencies
    private let settings: SettingsStore
    private let terminalSessions: TerminalSessionCoordinator
    private let snippetRepository: (any SnippetRepository)?
    private let snippetGroupRepository: (any SnippetGroupRepository)?

    @State private var tabID: String
    @State private var isReconnecting = false
    @State private var isCommandPickerPresented = false
    @State private var isSessionActionsPresented = false
    @State private var isSessionListPresented = false
    @State private var sessionActionsDetent: PresentationDetent = .medium
    @State private var isNewTerminalPresented = false
    @State private var deferredSessionAction: DeferredTerminalSessionAction?
    @State private var createAfterSessionListDismisses = false
    @State private var pendingCompletion: NewTerminalFlowCompletion?
    @StateObject private var insertionMailbox: TerminalTextInsertionMailbox
    @StateObject private var attachmentCoordinator: TerminalAttachmentCoordinator
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var providerWorkingDirectory: String?
    @State private var terminalWorkingDirectoryResolvers: [String: TerminalWorkingDirectoryResolver] = [:]
    @State private var terminalFileBrowserViewModels: [String: FileBrowserViewModel] = [:]
    @State private var terminalFileBrowserRoute: TerminalFileBrowserRoute?
    @State private var paywallContext: PaywallContext?
    @State private var pendingAttachmentContext: TerminalTextInsertionContext?
    @State private var pendingAttachmentWorkingDirectory: String?
    @Environment(\.connToastCenter) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        tabID: String,
        dependencies: AppDependencies,
        settings: SettingsStore,
        terminalSessions: TerminalSessionCoordinator? = nil
    ) {
        self.host = host
        self.dependencies = dependencies
        self.settings = settings
        self.terminalSessions = terminalSessions ?? dependencies.terminalSessions
        snippetRepository = dependencies.snippetRepository
        snippetGroupRepository = dependencies.snippetGroupRepository
        _tabID = State(initialValue: tabID)
        _insertionMailbox = StateObject(wrappedValue: TerminalTextInsertionMailbox())
        _attachmentCoordinator = StateObject(wrappedValue: TerminalAttachmentCoordinator(
            host: host,
            connectionManager: dependencies.connectionManager
        ))
    }

    var body: some View {
        terminalContent
            // TerminalScreen is presented as a full-screen modal. The App-root toast
            // overlay sits below that presentation, so terminal interaction notices need
            // a presentation-local overlay backed by the same environment toast center.
            .connGlobalToast()
            .onAppear {
                verifyExistingTab()
                synchronizeWorkingDirectory(for: activeTab)
            }
            .onChange(of: activeTab?.id) { previousID, currentID in
                guard previousID == tabID, currentID == nil else { return }
                leaveClosedTab()
            }
            .onChange(of: activeTab?.generation) { _, _ in
                synchronizeWorkingDirectory(for: activeTab)
            }
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
            .sheet(
                isPresented: $isSessionActionsPresented,
                onDismiss: {
                    isSessionListPresented = false
                    performDeferredSessionAction()
                    presentDeferredNewTerminal()
                    sessionActionsDetent = .medium
                }
            ) {
                sessionActionsSheet
            }
            .sheet(item: $paywallContext) { context in
                PaywallView(dependencies: dependencies, context: context)
            }
            .sheet(
                isPresented: $isNewTerminalPresented,
                onDismiss: switchToPendingCompletion
            ) {
                NewTerminalSheet(
                    fixedHost: host,
                    hostRepository: dependencies.hostRepository,
                    terminalSessions: terminalSessions,
                    onCompleted: { completion in
                        pendingCompletion = completion
                        isNewTerminalPresented = false
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $photoSelection,
                maxSelectionCount: 10,
                matching: .images,
                preferredItemEncoding: .automatic
            )
            .onChange(of: photoSelection.count) { _, count in
                guard count > 0 else { return }
                let selected = photoSelection
                photoSelection = []
                attachmentCoordinator.uploadPhotos(
                    selected,
                    providerWorkingDirectory: pendingAttachmentWorkingDirectory,
                    insertionContext: pendingAttachmentContext,
                    insertionMailbox: insertionMailbox
                )
                pendingAttachmentContext = nil
                pendingAttachmentWorkingDirectory = nil
            }
            .onChange(of: isPhotoPickerPresented) { _, isPresented in
                if !isPresented, photoSelection.isEmpty {
                    pendingAttachmentContext = nil
                    pendingAttachmentWorkingDirectory = nil
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                defer {
                    pendingAttachmentContext = nil
                    pendingAttachmentWorkingDirectory = nil
                }
                guard case let .success(urls) = result, !urls.isEmpty else { return }
                attachmentCoordinator.uploadFiles(
                    urls,
                    providerWorkingDirectory: pendingAttachmentWorkingDirectory,
                    insertionContext: pendingAttachmentContext,
                    insertionMailbox: insertionMailbox
                )
            }
            .onDisappear { attachmentCoordinator.cancel() }
            .onChange(of: attachmentCoordinator.panelState.phase) { _, phase in
                presentAttachmentResult(phase)
            }
    }
}

private extension TerminalScreen {
    @ViewBuilder
    private var sessionActionsSheet: some View {
        if let tab = activeTab {
            TerminalSessionActionsSheet(
                host: host,
                tab: tab,
                dependencies: dependencies,
                isSessionListPresented: $isSessionListPresented,
                terminalFileBrowserRoute: $terminalFileBrowserRoute,
                store: terminalSessions.store,
                selectedTabID: tabID,
                onSwitchTerminal: {
                    sessionActionsDetent = .large
                    isSessionListPresented = true
                },
                onOpenFileBrowser: {
                    sessionActionsDetent = .large
                    openFileBrowser()
                },
                onCloseTerminal: {
                    deferSessionAction(.closeTerminal)
                },
                onSelectTerminal: { selectedID in
                    terminalSessions.store.select(selectedID)
                    tabID = selectedID
                    isSessionListPresented = false
                    isSessionActionsPresented = false
                },
                onCreateTerminal: {
                    createAfterSessionListDismisses = true
                    isSessionListPresented = false
                    isSessionActionsPresented = false
                },
                onRenameTerminal: { id, alias in
                    Task {
                        if case let .failure(failure) = await terminalSessions.rename(id, to: alias),
                           let message = terminalSessions.consumeFailure(failure) {
                            toastCenter.show(message, style: .error)
                        }
                    }
                },
                onCloseSession: { id in
                    Task {
                        await terminalSessions.close(id)
                        if tabID == id {
                            if let recent = terminalSessions.store.recentTab(forHost: host.id) {
                                tabID = recent.id
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
            )
            .presentationDetents([.medium, .large], selection: $sessionActionsDetent)
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.connBg)
        }
    }

    private var activeTab: TerminalTab? {
        terminalSessions.store.tab(id: tabID)
    }

    private var terminalColorScheme: ColorScheme {
        switch settings.terminalConfiguration.theme.appearance {
        case .dark: .dark
        case .light: .light
        }
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
                    persistentAttachment: tab.persistentAttachment,
                    persistentInteraction: (
                        tab.persistentAttachment as? any PersistentTerminalInteractiveAttachment
                    )?.interaction,
                    tabID: tab.id,
                    terminalGeneration: tab.generation,
                    insertionMailbox: insertionMailbox,
                    configuration: configuration,
                    onShowSessionActions: {
                        isSessionActionsPresented = true
                    },
                    onChooseCommand: showCommandPicker,
                    onReconnect: { Task { await reconnect(tab.id) } },
                    onPersistentWorkspaceRenamed: { name in
                        terminalSessions.store.updatePersistentWorkspaceName(tab.id, to: name)
                    },
                    onPersistentWorkspaceChanged: { workspaceID, workspaceName in
                        terminalSessions.updatePersistentWorkspaceBinding(
                            tab.id,
                            workspaceID: workspaceID,
                            workspaceName: workspaceName
                        )
                    },
                    onPersistentWorkspaceClosed: {
                        closePersistentWorkspace(tab.id)
                    },
                    attachmentState: attachmentCoordinator.panelState,
                    onAttachmentAction: handleAttachmentAction,
                    onPersistentWorkingDirectoryChanged: { providerWorkingDirectory = $0 },
                    onTerminalWorkingDirectoryChanged: { source, generation, path in
                        updateWorkingDirectory(
                            source: source,
                            tabID: tab.id,
                            generation: generation,
                            path: path,
                            terminalSource: tab.source
                        )
                    }
                )
                .preferredColorScheme(terminalColorScheme)
                .overlay {
                    if case let .disconnected(message) = tab.status {
                        reconnectNotice(message)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else if case .reconnecting = tab.status {
                        TerminalReconnectingNotice()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            } else {
                ContentUnavailableView(
                    L("终端会话不存在"),
                    systemImage: "terminal",
                    description: Text(L("该终端会话可能已关闭。"))
                )
                .foregroundStyle(.connMuted)
            }
        }
    }

    private func closePersistentWorkspace(_ id: String) {
        Task {
            await terminalSessions.close(id)
            guard tabID == id, activeTab == nil else { return }
            leaveClosedTab()
        }
    }

    private func leaveClosedTab() {
        if let recent = terminalSessions.store.recentTab(forHost: host.id) {
            tabID = recent.id
        } else {
            dismiss()
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
                Task { await reconnect(tabID) }
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

    private func reconnect(_ id: String) async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        if case let .failure(failure) = await terminalSessions.reconnect(id),
           let message = terminalSessions.consumeFailure(failure) {
            toastCenter.show(message, style: .error)
        }
    }

    private func verifyExistingTab() {
        guard terminalSessions.store.tab(id: tabID) == nil else {
            terminalSessions.store.select(tabID)
            return
        }
        toastCenter.show(L("终端会话不存在"), style: .error)
    }

    private func deferSessionAction(_ action: DeferredTerminalSessionAction) {
        deferredSessionAction = action
        isSessionActionsPresented = false
    }

    private func performDeferredSessionAction() {
        guard let action = deferredSessionAction else { return }
        deferredSessionAction = nil
        switch action {
        case .closeTerminal:
            dismiss()
        }
    }

    private func synchronizeWorkingDirectory(for tab: TerminalTab?) {
        guard let tab else { return }
        var resolver = terminalWorkingDirectoryResolvers[tab.id] ?? .init()
        resolver.synchronize(generation: tab.generation)
        terminalWorkingDirectoryResolvers[tab.id] = resolver
    }

    private func updateWorkingDirectory(
        source: TerminalWorkingDirectorySource,
        tabID: String,
        generation: UInt64,
        path: String?,
        terminalSource: TerminalSessionSource
    ) {
        guard let tab = terminalSessions.store.tab(id: tabID), tab.generation == generation else {
            return
        }
        var resolver = terminalWorkingDirectoryResolvers[tabID] ?? .init()
        resolver.update(source: source, generation: generation, path: path)
        terminalWorkingDirectoryResolvers[tabID] = resolver

        guard case .docker = terminalSource else {
            terminalFileBrowserViewModels[tabID]?.setInitialPathIfNeeded(resolver.effectivePath)
            return
        }
    }

    private func openFileBrowser() {
        guard let tab = activeTab else { return }
        guard dependencies.subscription.gate.allowed(.fileManagement) else {
            paywallContext = .fileManagement
            return
        }

        let tabID = tab.id
        let generation = tab.generation
        Task { @MainActor in
            guard let tab = terminalSessions.store.tab(id: tabID), tab.generation == generation else {
                return
            }
            await refreshProviderWorkingDirectory(for: tab)
            guard let tab = terminalSessions.store.tab(id: tabID), tab.generation == generation else {
                return
            }

            synchronizeWorkingDirectory(for: tab)
            let viewModel: FileBrowserViewModel
            if let existing = terminalFileBrowserViewModels[tab.id] {
                viewModel = existing
            } else {
                viewModel = FileBrowserViewModel(host: host, dependencies: dependencies)
                if case .docker = tab.source {
                    viewModel.setInitialPathIfNeeded(nil)
                } else {
                    viewModel.setInitialPathIfNeeded(
                        terminalWorkingDirectoryResolvers[tab.id]?.effectivePath
                    )
                }
                terminalFileBrowserViewModels[tab.id] = viewModel
            }
            viewModel.resetTransientPresentationState()
            sessionActionsDetent = .large
            terminalFileBrowserRoute = TerminalFileBrowserRoute(
                tabID: tab.id,
                viewModel: viewModel
            )
        }
    }

    private func refreshProviderWorkingDirectory(for tab: TerminalTab) async {
        guard case .persistent = tab.source,
              let attachment = tab.persistentAttachment
                as? any PersistentTerminalInteractiveAttachment,
              let state = try? await attachment.interaction.resolveState()
        else {
            return
        }

        updateWorkingDirectory(
            source: .provider,
            tabID: tab.id,
            generation: tab.generation,
            path: state.workingDirectory,
            terminalSource: tab.source
        )
    }

    private func presentDeferredNewTerminal() {
        guard createAfterSessionListDismisses else { return }
        createAfterSessionListDismisses = false
        isNewTerminalPresented = true
    }

    private func switchToPendingCompletion() {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        toastCenter.show(completion.notice, style: .success)
        terminalSessions.store.select(completion.tabID)
        tabID = completion.tabID
    }

    private func showCommandPicker() {
        guard snippetRepository != nil, snippetGroupRepository != nil else { return }
        isCommandPickerPresented = true
    }

    /// Inserts text only; the user still decides whether to execute it.
    private func insertCommand(_ command: String) {
        isCommandPickerPresented = false
        guard let context = insertionMailbox.currentContext else { return }
        insertionMailbox.enqueue(command, expectedContext: context)
    }

    private func handleAttachmentAction(_ action: TerminalAttachmentAction) {
        switch action {
        case .photos:
            captureAttachmentContext()
            isPhotoPickerPresented = true
        case .files:
            captureAttachmentContext()
            isFileImporterPresented = true
        case .clipboard:
            attachmentCoordinator.uploadClipboard(
                providerWorkingDirectory: providerWorkingDirectory,
                insertionContext: insertionMailbox.currentContext,
                insertionMailbox: insertionMailbox
            )
        case .retry:
            attachmentCoordinator.retry()
        case .insertPaths:
            attachmentCoordinator.insertCompletedPaths()
        case .cancel:
            attachmentCoordinator.cancel()
        }
    }

    private func captureAttachmentContext() {
        pendingAttachmentContext = insertionMailbox.currentContext
        pendingAttachmentWorkingDirectory = providerWorkingDirectory
    }

    private func presentAttachmentResult(_ phase: TerminalAttachmentPanelState.Phase) {
        switch phase {
        case let .completed(count, _):
            toastCenter.show(
                String(format: ConnUI.L("已上传 %d 个附件"), count),
                style: .success
            )
        case let .notice(message):
            toastCenter.show(message, style: .info)
        case let .failed(message):
            toastCenter.show(message, style: .error)
        case .idle, .preparing, .uploading:
            break
        }
    }
}

private enum DeferredTerminalSessionAction {
    case closeTerminal
}

private struct TerminalFileBrowserRoute: Hashable, Identifiable {
    let tabID: String
    let viewModel: FileBrowserViewModel

    var id: String { tabID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabID == rhs.tabID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(tabID)
    }
}

private struct TerminalSessionActionsSheet: View {
    let host: Host
    let tab: TerminalTab
    let dependencies: AppDependencies
    @Binding var isSessionListPresented: Bool
    @Binding var terminalFileBrowserRoute: TerminalFileBrowserRoute?
    let store: TerminalSessionStore
    let selectedTabID: String?
    let onSwitchTerminal: () -> Void
    let onOpenFileBrowser: () -> Void
    let onCloseTerminal: () -> Void
    let onSelectTerminal: (String) -> Void
    let onCreateTerminal: () -> Void
    let onRenameTerminal: (String, String) -> Void
    let onCloseSession: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                Text(host.displayAddress)
                    .font(.connData(.subheadline))
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)

                currentTerminalCard

                actionRow(
                    title: L("切换终端"),
                    systemName: "rectangle.stack",
                    identifier: "terminal.session-actions.switch",
                    showsDisclosure: true,
                    action: onSwitchTerminal
                )
                actionRow(
                    title: L("文件管理"),
                    systemName: "folder",
                    identifier: "terminal.session-actions.files",
                    action: onOpenFileBrowser
                )
                actionRow(
                    title: L("关闭终端"),
                    systemName: "xmark.circle",
                    identifier: "terminal.session-actions.close",
                    action: onCloseTerminal
                )
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.top, ConnSpacing.xs)
            .padding(.bottom, ConnSpacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(L("会话操作"))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.connBg.ignoresSafeArea())
            .navigationDestination(isPresented: $isSessionListPresented) {
                TerminalSessionListSheet(
                    host: host,
                    store: store,
                    selectedTabID: selectedTabID,
                    onSelect: onSelectTerminal,
                    onCreate: onCreateTerminal,
                    onRename: onRenameTerminal,
                    onClose: onCloseSession
                )
            }
            .navigationDestination(item: $terminalFileBrowserRoute) { route in
                FileBrowserView(
                    host: host,
                    dependencies: dependencies,
                    viewModel: route.viewModel
                )
                .padding(.horizontal, ConnSpacing.page)
                .padding(.top, ConnSpacing.xs)
                .navigationTitle(L("文件"))
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("terminal.file-browser")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.session-actions")
    }

    private var currentTerminalCard: some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: sourceIcon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.connAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.displayName)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                    .lineLimit(1)
                Text(sourceDescription)
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            statusIndicator
        }
        .padding(.horizontal, ConnSpacing.sm)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(
            Color.connSurface,
            in: RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.session-actions.current")
    }

    private func actionRow(
        title: String,
        systemName: String,
        identifier: String,
        showsDisclosure: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.connAccent)
                    .frame(width: 24)
                Text(title)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                Spacer(minLength: 0)
                if showsDisclosure {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.connMuted)
                }
            }
            .padding(.horizontal, ConnSpacing.sm)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                destructive ? Color.connCritFill : Color.connSurface,
                in: RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                    .strokeBorder(
                        destructive ? Color.connCrit.opacity(0.35) : Color.connLine,
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var sourceIcon: String {
        switch tab.source {
        case .shell: "terminal"
        case .docker: "shippingbox"
        case .script: "command"
        case .persistent: "rectangle.connected.to.line.below"
        }
    }

    private var sourceDescription: String {
        switch tab.source {
        case .shell:
            L("普通终端")
        case let .docker(containerName):
            String(format: L("容器：%@"), containerName)
        case let .script(title):
            String(format: L("脚本：%@"), title)
        case let .persistent(providerID):
            String(format: L("持久终端：%@"), providerID)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch tab.status {
        case .connected:
            Circle()
                .fill(Color.connGood)
                .frame(width: 10, height: 10)
                .accessibilityLabel(L("已连接"))
        case .reconnecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L("正在重新连接…"))
        case .disconnected:
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.connWarn)
                .accessibilityLabel(L("终端连接已断开"))
        }
    }
}

private struct TerminalReconnectingNotice: View {
    var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            ProgressView()
                .tint(.connAccent)
            Text(L("正在重新连接…"))
                .font(.connFootnote)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, ConnSpacing.xs)
        .background(
            .black.opacity(0.82),
            in: RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.reconnecting")
        .allowsHitTesting(false)
    }
}
