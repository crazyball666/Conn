import ConnKit
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// Presents an already-created local tab. Backend selection and initial launch are
/// intentionally owned by the source page before this screen is shown.
struct TerminalScreen: View {
    let host: Host
    let dependencies: AppDependencies
    private let terminalSessions: TerminalSessionCoordinator
    private let snippetRepository: (any SnippetRepository)?
    private let snippetGroupRepository: (any SnippetGroupRepository)?

    @State private var tabID: String
    @State private var isReconnecting = false
    @State private var isCommandPickerPresented = false
    @State private var isSessionListPresented = false
    @State private var isNewTerminalPresented = false
    @State private var createAfterSessionListDismisses = false
    @State private var pendingCompletion: NewTerminalFlowCompletion?
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        tabID: String,
        dependencies: AppDependencies,
        terminalSessions: TerminalSessionCoordinator? = nil
    ) {
        self.host = host
        self.dependencies = dependencies
        self.terminalSessions = terminalSessions ?? dependencies.terminalSessions
        snippetRepository = dependencies.snippetRepository
        snippetGroupRepository = dependencies.snippetGroupRepository
        _tabID = State(initialValue: tabID)
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
        .onAppear { verifyExistingTab() }
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
            isPresented: $isSessionListPresented,
            onDismiss: presentDeferredNewTerminal
        ) {
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
                    createAfterSessionListDismisses = true
                    isSessionListPresented = false
                },
                onRename: { id, alias in
                    terminalSessions.store.updateAlias(id, to: alias)
                },
                onClose: { id in
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
    }

    private var activeTab: TerminalTab? {
        terminalSessions.store.tab(id: tabID)
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
            } else {
                ContentUnavailableView(
                    L("终端会话不存在"),
                    systemImage: "terminal",
                    description: Text(L("该终端可能已经关闭。"))
                )
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
                let closingID = tabID
                Task {
                    await terminalSessions.close(closingID)
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
            toastCenter.show(message)
        }
    }

    private func verifyExistingTab() {
        guard terminalSessions.store.tab(id: tabID) == nil else {
            terminalSessions.store.select(tabID)
            return
        }
        toastCenter.show(L("终端会话不存在"))
    }

    private func presentDeferredNewTerminal() {
        guard createAfterSessionListDismisses else { return }
        createAfterSessionListDismisses = false
        isNewTerminalPresented = true
    }

    private func switchToPendingCompletion() {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
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
        guard let tab = activeTab else { return }
        Task { try? await tab.session.send(Array(command.utf8)) }
    }
}
