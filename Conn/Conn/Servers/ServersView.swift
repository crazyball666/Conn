import ConnEntitlement
import ConnKit
import ConnMonitor
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 主机表单的呈现请求：新增（editingHostID == nil）或编辑一台已有主机。
struct HostFormRequest: Identifiable {
    let id = UUID()
    let draft: HostDraft
    let editingHostID: String?
}

/// 终端弹层目标——独立类型，避免与 `selectedHost`（同为 `Host`）的 navigationDestination 撞类型。
/// `.fullScreenCover(item:)` 要求 `Identifiable`，直接借 `host.id`。
private struct TerminalRoute: Hashable, Identifiable {
    let host: Host
    let tabID: String
    var id: String { tabID }
}

/// 服务器列表中的主机指纹变更确认请求。
private struct HostKeyUpdateRequest: Identifiable, Equatable {
    let hostID: String
    let endpoint: SSHEndpoint
    let expected: String
    let actual: String

    var id: String {
        "\(hostID)|\(endpoint.identifier)|\(expected)|\(actual)"
    }

    var error: SSHError {
        .hostKeyMismatch(endpoint: endpoint, expected: expected, actual: actual)
    }
}

/// 「服务器」页：原「仪表盘 S1」+「主机 S2」合并为一屏。
///
/// PRD「观测先于操作」：健康视图为主——状态 + CPU/内存/磁盘 指标卡；
/// 同页直接搜索 / 分组筛选 / 添加 / 编辑 / 删除，无需在两个 Tab 间跳转。
struct ServersView: View {
    @State private var viewModel: ServersViewModel
    @State private var selectedHost: Host?
    @State private var terminalRoute: TerminalRoute?
    @State private var newTerminalHost: Host?
    @State private var pendingTerminalCompletion: NewTerminalFlowCompletion?
    @State private var formRequest: HostFormRequest?
    @State private var pendingDelete: Host?
    @State private var isNewGroupPresented = false
    @State private var renameTarget: GroupEditRequest?
    @State private var groupDeleteRequest: GroupEditRequest?
    @State private var groupNameInput = ""
    @State private var paywallContext: PaywallContext?
    @State private var pendingHostKeyUpdate: HostKeyUpdateRequest?
    @State private var dismissedHostKeyRequestIDs: Set<String> = []
    /// 用户确认后若重连立即观察到第三个指纹，不在同一次操作中再次弹窗；
    /// 用户可通过下拉刷新或重新进入页面主动重新确认。
    @State private var suppressedHostKeyEndpointIDs: Set<String> = []
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: ServersViewModel(
            hostStore: dependencies.hostRepository,
            groupStore: dependencies.hostGroupRepository,
            monitor: dependencies.monitor,
            credentialStore: dependencies.credentialStore,
            hostKeyStore: dependencies.hostKeyStore
        ))
    }

    var body: some View {
        hostsContent
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("主机"))
        .searchable(text: $viewModel.searchText, prompt: L("搜索主机名或地址"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        startAdding()
                    } label: {
                        Label(L("新增主机"), systemImage: "server.rack")
                    }
                    Button {
                        groupNameInput = ""
                        isNewGroupPresented = true
                    } label: {
                        Label(L("新增分组"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新增"))
            }
        }
        .onAppear {
            suppressedHostKeyEndpointIDs.removeAll()
            viewModel.appear(interval: settings.refreshInterval.duration)
            presentNextHostKeyMismatch()
        }
        .onDisappear { viewModel.disappear() }
        .sheet(item: $formRequest) { request in
            HostFormView(
                dependencies: dependencies,
                initialDraft: request.draft,
                editingHostID: request.editingHostID
            ) { result in
                await dependencies.terminalSessions.hostDidSave(
                    result.host,
                    replacing: result.previousHost,
                    connectionIdentityChanged: result.connectionIdentityChanged
                )
                viewModel.load()
            }
        }
        .sheet(item: $paywallContext) { context in
            PaywallView(dependencies: dependencies, context: context)
        }
        .alert(
            L("删除主机"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { host in
            Button(L("删除"), role: .destructive) {
                Task {
                    await dependencies.terminalSessions.hostDidDelete(host)
                    viewModel.delete(host)
                    pendingDelete = nil
                }
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { host in
            Text(String(format: L("“%@”将从本地列表中永久删除，但不会影响远程主机。"), host.name))
        }
        .alert(
            L("确认更新主机指纹"),
            isPresented: Binding(
                get: { pendingHostKeyUpdate != nil },
                set: { if !$0 { pendingHostKeyUpdate = nil } }
            ),
            presenting: pendingHostKeyUpdate
        ) { request in
            Button(L("更新指纹并重连")) {
                suppressedHostKeyEndpointIDs.insert(request.endpoint.identifier)
                pendingHostKeyUpdate = nil
                guard let host = viewModel.host(forID: request.hostID) else { return }
                Task {
                    await viewModel.updateHostKeyAndReconnect(
                        host: host,
                        endpoint: request.endpoint,
                        expected: request.expected,
                        actual: request.actual
                    )
                }
            }
            Button(L("取消"), role: .cancel) {
                dismissedHostKeyRequestIDs.insert(request.id)
                pendingHostKeyUpdate = nil
                Task { @MainActor in
                    await Task.yield()
                    presentNextHostKeyMismatch()
                }
            }
        } message: { request in
            Text(request.error.diagnosis)
        }
        .navigationDestination(item: $selectedHost) { host in
            HostDetailView(host: host, dependencies: dependencies)
        }
        .fullScreenCover(item: $terminalRoute) { route in
            TerminalScreen(
                host: route.host,
                tabID: route.tabID,
                dependencies: dependencies,
                settings: settings
            )
        }
        .sheet(item: $newTerminalHost, onDismiss: openPendingTerminal) { host in
            NewTerminalSheet(
                fixedHost: host,
                hostRepository: dependencies.hostRepository,
                terminalSessions: dependencies.terminalSessions,
                onCompleted: { completion in
                    pendingTerminalCompletion = completion
                    newTerminalHost = nil
                }
            )
            .presentationDetents([.medium, .large])
        }
        .groupManagementAlerts(
            isNewGroupPresented: $isNewGroupPresented,
            renameTarget: $renameTarget,
            deleteRequest: $groupDeleteRequest,
            nameInput: $groupNameInput,
            actions: GroupAlertActions(
                deleteMessage: L("删除分组不会删除其中的主机。"),
                onAdd: { viewModel.addGroup($0) },
                onRename: { viewModel.renameGroup(id: $0, to: $1) },
                onDelete: { viewModel.deleteGroup(id: $0) }
            )
        )
        .onChange(of: viewModel.errorMessage) { _, message in
            toastCenter.show(message, style: .error)
        }
        .onChange(of: viewModel.monitor.hostKeyMismatches) { _, _ in
            presentNextHostKeyMismatch()
        }
    }

    // MARK: - 区块

    /// 始终保留同一个可回弹滚动容器，短列表与空列表也能下拉刷新。
    private var hostsContent: some View {
        ScrollView {
            if viewModel.hosts.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // 一个分组都没有时整行不渲染。
                    if !viewModel.groups.isEmpty {
                        groupFilter
                    }
                    cards
                }
            }
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await viewModel.refresh()
            suppressedHostKeyEndpointIDs.removeAll()
            dismissedHostKeyRequestIDs.removeAll()
            presentNextHostKeyMismatch()
        }
    }

    private var groupFilter: some View {
        GroupFilterBar(
            allTitle: L("全部"),
            groups: viewModel.groups.map { GroupFilterBar.Item(id: $0.id, title: $0.name) },
            selection: $viewModel.selectedGroupID,
            onRename: { item in
                renameTarget = GroupEditRequest(id: item.id, name: item.title)
                groupNameInput = item.title
            },
            onDelete: { item in
                groupDeleteRequest = GroupEditRequest(id: item.id, name: item.title)
            }
        )
        .padding(.bottom, ConnSpacing.sm)
    }

    private var cards: some View {
        LazyVStack(spacing: ConnSpacing.stackGap) {
            ForEach(viewModel.cards) { card in
                HealthCard(card) {
                    selectedHost = viewModel.host(forID: card.id)
                }
                .contextMenu {
                    Button {
                        if let host = viewModel.host(forID: card.id) { openTerminal(host) }
                    } label: {
                        Label(L("终端"), systemImage: "terminal")
                    }
                    Button {
                        if let host = viewModel.host(forID: card.id) { startEditing(host) }
                    } label: {
                        Label(L("编辑"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = viewModel.host(forID: card.id)
                    } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.bottom, ConnSpacing.lg)
        // 增删主机 / 切换分组筛选导致列表变化时平滑滑动而非瞬跳；新卡片淡入。
        // （健康状态已退出排序，不再有「故障置顶」引发的重排。）
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: viewModel.cards)
    }

    private func openTerminal(_ host: Host) {
        if let recent = dependencies.terminalSessions.store.recentTab(forHost: host.id) {
            terminalRoute = TerminalRoute(host: host, tabID: recent.id)
        } else {
            newTerminalHost = host
        }
    }

    private func openPendingTerminal() {
        guard let completion = pendingTerminalCompletion else { return }
        pendingTerminalCompletion = nil
        toastCenter.show(completion.notice, style: .success)
        terminalRoute = TerminalRoute(host: completion.host, tabID: completion.tabID)
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "server.rack",
            title: L("暂无主机"),
            message: L("添加第一台主机以开始监控和管理"),
            primary: .init(L("添加主机")) { startAdding() }
        )
    }

    // MARK: - 动作

    private func startAdding() {
        guard dependencies.subscription.gate.canAddHost(currentCount: viewModel.totalCount) else {
            paywallContext = .thirdHost
            return
        }
        formRequest = HostFormRequest(draft: HostDraft(), editingHostID: nil)
    }

    private func startEditing(_ host: Host) {
        formRequest = HostFormRequest(draft: HostDraft(from: host), editingHostID: host.id)
    }

    /// 按当前卡片顺序逐个展示 mismatch；同一组 old/new 指纹在取消后不重复弹出，
    /// 直到监控状态变化或页面再次遇到新的 mismatch。
    @MainActor
    private func presentNextHostKeyMismatch() {
        let mismatches = viewModel.monitor.hostKeyMismatches
        if mismatches.isEmpty {
            pendingHostKeyUpdate = nil
            dismissedHostKeyRequestIDs.removeAll()
            return
        }
        let nextRequest = viewModel.cards.compactMap { card -> HostKeyUpdateRequest? in
            guard
                let error = mismatches[card.id],
                case let .hostKeyMismatch(endpoint, expected, actual) = error
            else { return nil }
            guard !suppressedHostKeyEndpointIDs.contains(endpoint.identifier) else { return nil }
            return HostKeyUpdateRequest(
                hostID: card.id, endpoint: endpoint, expected: expected, actual: actual
            )
        }.first { !dismissedHostKeyRequestIDs.contains($0.id) }

        // 如果弹窗打开期间当前指纹又变化了，更新为最新的请求；确认旧请求时，
        // ViewModel 也会再次校验三元组，双层保护避免过期 actual 被覆盖。
        if let pendingHostKeyUpdate {
            if nextRequest?.id != pendingHostKeyUpdate.id {
                self.pendingHostKeyUpdate = nextRequest
            }
            return
        }
        guard let nextRequest else { return }
        pendingHostKeyUpdate = nextRequest
    }
}
