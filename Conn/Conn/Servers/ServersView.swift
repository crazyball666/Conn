import ConnKit
import ConnUI
import SwiftUI

/// 主机表单的呈现请求：新增（editingHostID == nil）或编辑一台已有主机。
struct HostFormRequest: Identifiable {
    let id = UUID()
    let draft: HostDraft
    let editingHostID: String?
}

/// 「服务器」页：原「仪表盘 S1」+「主机 S2」合并为一屏。
///
/// PRD「观测先于操作」：健康视图为主——状态 + CPU/内存/磁盘 指标卡、故障置顶；
/// 同页直接搜索 / 标签筛选 / 添加 / 编辑 / 删除，无需在两个 Tab 间跳转。
struct ServersView: View {
    @State private var viewModel: ServersViewModel
    @State private var selectedHost: Host?
    @State private var formRequest: HostFormRequest?
    @State private var pendingDelete: Host?
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: ServersViewModel(
            hostStore: dependencies.hostRepository,
            monitor: dependencies.monitor
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if viewModel.hosts.isEmpty {
                    emptyState
                } else {
                    summaryPills
                    searchBar
                    if !viewModel.allTags.isEmpty {
                        tagFilter
                    }
                    if viewModel.isAtFreeLimit {
                        limitBanner
                    }
                    cards
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.connBg.ignoresSafeArea())
        .refreshable { await viewModel.refresh() }
        .onAppear { viewModel.appear() }
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
        .confirmationDialog(
            L("删除主机"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { host in
            Button(L("删除"), role: .destructive) {
                viewModel.delete(host)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { host in
            Text(String(format: L("「%@」将从列表中移除，可随时重新添加（不影响服务器本身）。"), host.name))
        }
        .navigationDestination(item: $selectedHost) { host in
            HostDetailView(host: host, dependencies: dependencies)
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("服务器"))
                    .font(.system(.title2, weight: .bold))
                    .connDisplayTracking()
                    .foregroundStyle(.connInk)
                if !viewModel.hosts.isEmpty {
                    Text(viewModel.lastScanText)
                        .font(.connSubheadline)
                        .foregroundStyle(.connMuted)
                }
            }
            Spacer()
            IconChipButton("plus", tint: .accent, accessibilityLabel: L("添加主机")) {
                startAdding()
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var summaryPills: some View {
        HStack(spacing: ConnSpacing.xs) {
            StatusPill(String(format: L("%d 台主机"), viewModel.totalCount), semantic: .accent, showsSymbol: false)
            if viewModel.abnormalCount > 0 {
                StatusPill(String(format: L("%d 台异常"), viewModel.abnormalCount), semantic: .crit)
            } else {
                StatusPill(L("全部正常"), semantic: .good)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var searchBar: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.connMuted)
            TextField(L("搜索主机名或地址"), text: $viewModel.searchText)
                .font(.connSubheadline)
                .foregroundStyle(.connInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, 10)
        .background(Color.connSurface, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        )
        .padding(.horizontal, ConnSpacing.page)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xs) {
                filterChip(title: L("全部"), isSelected: viewModel.selectedTag == nil) {
                    viewModel.selectedTag = nil
                }
                ForEach(viewModel.allTags, id: \.self) { tag in
                    filterChip(title: tag, isSelected: viewModel.selectedTag == tag) {
                        viewModel.selectedTag = viewModel.selectedTag == tag ? nil : tag
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
        }
        .padding(.bottom, ConnSpacing.sm)
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(isSelected ? .connAccent : .connMuted)
                .padding(.horizontal, ConnSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.connAccentFill : Color.connSurface,
                    in: .capsule
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.connAccent.opacity(0.5) : Color.connLine,
                        lineWidth: 1
                    )
                )
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
    }

    private var limitBanner: some View {
        ConnBanner(
            String(format: L("免费版已用 %d/%d 台主机，升级专业版解锁无限主机"),
                   viewModel.hosts.count, viewModel.freeHostLimit),
            systemImage: "info.circle"
        )
        .padding(.horizontal, ConnSpacing.page)
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
        // 故障置顶导致卡片重排时平滑滑动而非瞬跳；新卡片淡入。
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: viewModel.cards)
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "server.rack",
            title: L("还没有主机"),
            message: L("添加你的第一台服务器，开始监控与管理"),
            primary: .init(L("添加我的服务器")) { startAdding() }
        )
        .padding(.top, ConnSpacing.xxl)
    }

    // MARK: - 动作

    private func startAdding() {
        formRequest = HostFormRequest(draft: HostDraft(), editingHostID: nil)
    }

    private func startEditing(_ host: Host) {
        formRequest = HostFormRequest(draft: HostDraft(from: host), editingHostID: host.id)
    }
}
