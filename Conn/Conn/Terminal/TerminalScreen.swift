import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI

/// 一个已存在或即将创建的全局终端会话的全屏呈现。
///
/// 返回只关闭这个界面；只有「退出」才会关闭对应 PTY。SSH 连接由全局连接池继续复用。
struct TerminalScreen: View {
    let host: Host
    private let terminalSessions: TerminalSessionCoordinator
    private let snippetRepository: (any SnippetRepository)?
    private let snippetGroupRepository: (any SnippetGroupRepository)?
    private let launchPolicy: TerminalLaunchPolicy
    private let source: TerminalSessionSource
    private let initialCommand: String?
    private let replayInitialCommandOnReconnect: Bool

    @State private var tabID: String?
    @State private var isLaunching = false
    @State private var isReconnecting = false
    @State private var isCommandPickerPresented = false
    @State private var isSessionListPresented = false
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        dependencies: AppDependencies,
        terminalSessions: TerminalSessionCoordinator? = nil,
        launchPolicy: TerminalLaunchPolicy = .reuseRecentOrCreate,
        source: TerminalSessionSource = .shell,
        initialCommand: String? = nil,
        replayInitialCommandOnReconnect: Bool = false
    ) {
        self.host = host
        self.terminalSessions = terminalSessions ?? dependencies.terminalSessions
        snippetRepository = dependencies.snippetRepository
        snippetGroupRepository = dependencies.snippetGroupRepository
        self.launchPolicy = launchPolicy
        self.source = source
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
                    Task { await createAdditionalSession() }
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
        guard tabID == nil, !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }
        let request = TerminalLaunchRequest(
            host: host,
            policy: launchPolicy,
            source: source,
            initialCommand: initialCommand,
            replayInitialCommandOnReconnect: replayInitialCommandOnReconnect
        )
        switch await terminalSessions.launch(request) {
        case let .success(tab):
            tabID = tab.id
        case let .failure(failure):
            show(failure)
            dismiss()
        }
    }

    private func createAdditionalSession() async {
        guard !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }
        let request = TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        switch await terminalSessions.launch(request) {
        case let .success(tab):
            tabID = tab.id
        case let .failure(failure):
            show(failure)
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
