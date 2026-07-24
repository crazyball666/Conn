import ConnKit
import ConnUI
import SwiftUI

/// 仪表盘（原型 S1）。
///
/// PRD 核心设计原则二「观测先于操作」：打开 App 第一眼看到的是服务器健康状态，
/// 而不是连接列表。故障主机自动置顶。
struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var selectedHost: Host?
    private let dependencies: AppDependencies
    /// 空态「添加服务器」跳到「主机」标签（表单在那儿）。由根视图注入切 Tab 闭包。
    private let onAddHost: () -> Void

    init(dependencies: AppDependencies, onAddHost: @escaping () -> Void = {}) {
        self.dependencies = dependencies
        self.onAddHost = onAddHost
        _viewModel = State(initialValue: DashboardViewModel(
            hostStore: dependencies.hostRepository,
            monitor: dependencies.monitor
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: L("驾驶舱"), subtitle: viewModel.lastScanText)

                if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    summaryPills
                    cards
                    quickActions
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await viewModel.refresh() }
        .onAppear { viewModel.appear() }
        .onDisappear { viewModel.disappear() }
        .navigationDestination(item: $selectedHost) { host in
            HostDetailView(host: host, dependencies: dependencies)
        }
    }

    // MARK: - 区块

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

    private var cards: some View {
        LazyVStack(spacing: ConnSpacing.stackGap) {
            ForEach(viewModel.cards) { card in
                HealthCard(card) {
                    selectedHost = viewModel.host(forID: card.id)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        // 故障置顶导致卡片重排时,平滑滑动而非瞬跳；新卡片淡入。
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: viewModel.cards)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("快捷动作"))
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
                .padding(.top, ConnSpacing.lg)

            LazyVGrid(
                columns: Array(repeating: GridItem(spacing: ConnSpacing.xs), count: 2),
                spacing: ConnSpacing.xs
            ) {
                ActionTile(L("全部巡检"), systemName: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
                ActionTile(L("批量执行"), systemName: "square.stack.3d.up") {}
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.bottom, ConnSpacing.lg)
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "server.rack",
            title: L("还没有主机"),
            message: L("添加你的第一台服务器，开始监控与管理"),
            primary: .init(L("添加我的服务器")) { onAddHost() }
        )
        .padding(.top, ConnSpacing.xxl)
    }
}
