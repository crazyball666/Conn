import ConnKit
import ConnUI
import SwiftUI

/// 主机表单的呈现请求：新增（editingHostID == nil）或编辑一台已有主机。
struct HostFormRequest: Identifiable {
    let id = UUID()
    let draft: HostDraft
    let editingHostID: String?
}

/// 终端跳转目标——独立类型，避免与 `selectedHost`（同为 `Host`）的 navigationDestination 撞类型。
private struct TerminalRoute: Hashable {
    let host: Host
}

/// 分组重命名 / 删除的呈现请求。
private struct GroupEditRequest: Identifiable {
    let id: String
    let name: String
}

/// 「服务器」页：原「仪表盘 S1」+「主机 S2」合并为一屏。
///
/// PRD「观测先于操作」：健康视图为主——状态 + CPU/内存/磁盘 指标卡；
/// 同页直接搜索 / 分组筛选 / 添加 / 编辑 / 删除，无需在两个 Tab 间跳转。
struct ServersView: View {
    @State private var viewModel: ServersViewModel
    @State private var selectedHost: Host?
    @State private var terminalRoute: TerminalRoute?
    @State private var formRequest: HostFormRequest?
    @State private var pendingDelete: Host?
    @State private var isNewGroupPresented = false
    @State private var renameTarget: GroupEditRequest?
    @State private var groupDeleteRequest: GroupEditRequest?
    @State private var groupNameInput = ""
    @Environment(SettingsStore.self) private var settings
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: ServersViewModel(
            hostStore: dependencies.hostRepository,
            groupStore: dependencies.hostGroupRepository,
            monitor: dependencies.monitor
        ))
    }

    var body: some View {
        hostsContent
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("服务器"))
        .searchable(text: $viewModel.searchText, prompt: L("搜索主机名或地址"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        startAdding()
                    } label: {
                        Label(L("新增服务器"), systemImage: "server.rack")
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
        .refreshable { await viewModel.refresh() }
        .onAppear { viewModel.appear(interval: settings.refreshInterval.duration) }
        .onDisappear { viewModel.disappear() }
        .sheet(item: $formRequest) { request in
            HostFormView(
                dependencies: dependencies,
                initialDraft: request.draft,
                editingHostID: request.editingHostID
            ) {
                viewModel.load()
            }
        }
        .alert(
            L("删除主机"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { host in
            Button(L("删除"), role: .destructive) {
                viewModel.delete(host)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { host in
            Text(String(format: L("「%@」将被永久删除，不影响服务器本身。"), host.name))
        }
        .navigationDestination(item: $selectedHost) { host in
            HostDetailView(host: host, dependencies: dependencies)
        }
        .navigationDestination(item: $terminalRoute) { route in
            TerminalScreen(host: route.host, dependencies: dependencies)
        }
        .alert(L("新增分组"), isPresented: $isNewGroupPresented) {
            TextField(L("分组名称"), text: $groupNameInput)
            Button(L("取消"), role: .cancel) {}
            Button(L("保存")) { viewModel.addGroup(groupNameInput) }
                .disabled(groupNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            L("重命名分组"),
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField(L("分组名称"), text: $groupNameInput)
            Button(L("取消"), role: .cancel) { renameTarget = nil }
            Button(L("保存")) {
                if let target = renameTarget {
                    viewModel.renameGroup(id: target.id, to: groupNameInput)
                }
                renameTarget = nil
            }
            .disabled(groupNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            L("删除分组"),
            isPresented: Binding(
                get: { groupDeleteRequest != nil },
                set: { if !$0 { groupDeleteRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                if let request = groupDeleteRequest { viewModel.deleteGroup(id: request.id) }
                groupDeleteRequest = nil
            }
            Button(L("取消"), role: .cancel) { groupDeleteRequest = nil }
        } message: {
            Text(L("删除分组不会删除其中的服务器。"))
        }
        .connToast(message: Binding(
            get: { viewModel.errorMessage },
            set: { if $0 == nil { viewModel.clearError() } }
        ))
    }

    // MARK: - 区块

    /// 无主机 → 空态垂直居中填满可视区；有主机 → 列表滚动。
    @ViewBuilder
    private var hostsContent: some View {
        if viewModel.hosts.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 一个分组都没有时整行不渲染。
                    if !viewModel.groups.isEmpty {
                        groupFilter
                    }
                    cards
                }
            }
            .scrollBounceBehavior(.basedOnSize)
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
                        if let host = viewModel.host(forID: card.id) { terminalRoute = TerminalRoute(host: host) }
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

    private var emptyState: some View {
        EmptyState(
            systemName: "server.rack",
            title: L("还没有主机"),
            message: L("添加你的第一台服务器，开始监控与管理"),
            primary: .init(L("添加我的服务器")) { startAdding() }
        )
    }

    // MARK: - 动作

    private func startAdding() {
        formRequest = HostFormRequest(draft: HostDraft(), editingHostID: nil)
    }

    private func startEditing(_ host: Host) {
        formRequest = HostFormRequest(draft: HostDraft(from: host), editingHostID: host.id)
    }
}
