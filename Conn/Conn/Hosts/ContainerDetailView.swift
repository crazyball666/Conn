import ConnKit
import ConnOps
import ConnUI
import SwiftUI

/// 容器详情：inspect 信息 + 行内操作（启停重启 / 控制台 / 日志 / 删除）。
struct ContainerDetailView: View {
    let host: Host
    let dependencies: AppDependencies
    let container: ContainerInfo
    let viewModel: DockerViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var detail: ContainerDetail?
    @State private var loading = true
    @State private var route: Route?
    @State private var showRemoveConfirm = false

    enum Route: Hashable, Identifiable {
        case logs, console
        var id: String { self == .logs ? "logs" : "console" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                actionBar
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else if let detail {
                    summarySection(detail)
                    listSection(L("端口"), detail.ports, icon: "network")
                    listSection(L("挂载"), detail.mounts, icon: "externaldrive")
                    listSection(L("网络"), detail.networks, icon: "point.3.connected.trianglepath.dotted")
                    listSection(L("环境变量"), detail.env, icon: "leaf")
                    commandSection(detail)
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetail() }
        .navigationDestination(item: $route, destination: routeDestination)
        .alert(L("删除容器"), isPresented: $showRemoveConfirm) {
            Button(L("删除容器"), role: .destructive) {
                Task { await viewModel.perform(.remove, on: container); dismiss() }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(String(format: L("删除容器 %@？此操作不可撤销（docker rm -f）。"), container.name))
        }
        .alert(L("Docker 操作"), isPresented: messageBinding) {
            Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    private var isRunning: Bool {
        detail.map { $0.statusText == "running" } ?? container.isRunning
    }

    /// 活动态（运行 / 重启中 / 暂停）——都可停止、重启。
    private var isActive: Bool {
        if let status = detail?.statusText {
            return status == "running" || status == "restarting" || status == "paused"
        }
        return container.isActive
    }

    // MARK: - 操作栏（启停 / 重启 / 控制台 / 日志 / 删除 同排）

    private var actionBar: some View {
        HStack(spacing: ConnSpacing.sm) {
            if isActive {
                actionButton(L("停止"), "stop.circle") { perform(.stop) }
                actionButton(L("重启"), "arrow.clockwise.circle") { perform(.restart) }
                if isRunning {
                    actionButton(L("控制台"), "terminal") { route = .console }
                }
            } else {
                actionButton(L("启动"), "play.circle") { perform(.start) }
            }
            actionButton(L("日志"), "doc.text.magnifyingglass") { route = .logs }
            actionButton(L("删除"), "trash", tint: .connCrit) { showRemoveConfirm = true }
        }
    }

    private func actionButton(
        _ label: String, _ icon: String, tint: Color = .connAccent, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.connData(.caption2)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, ConnSpacing.sm)
            .connSurface(cornerRadius: ConnRadius.card)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.busyContainerID == container.id)
    }

    // MARK: - 概要

    private func summarySection(_ detail: ContainerDetail) -> some View {
        section(L("概要")) {
            infoRows([
                (L("状态"), detail.statusText),
                (L("镜像"), detail.image),
                (L("容器 ID"), detail.id),
                (L("创建"), detail.created),
                (L("启动于"), detail.startedAt),
                (L("重启策略"), detail.restartPolicy),
                (L("重启次数"), String(detail.restartCount))
            ] + (detail.health.map { [(L("健康"), $0)] } ?? []))
        }
    }

    private func commandSection(_ detail: ContainerDetail) -> some View {
        section(L("命令")) {
            Text(detail.command.isEmpty ? "—" : detail.command)
                .font(.connData(.footnote)).foregroundStyle(.connInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 列表区块（端口 / 挂载 / 网络 / 环境）

    @ViewBuilder
    private func listSection(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            section(title) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        HStack(spacing: ConnSpacing.sm) {
                            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.connMuted).frame(width: 16)
                            Text(item).font(.connData(.caption2)).foregroundStyle(.connInk)
                                .textSelection(.enabled).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, ConnSpacing.xs)
                    }
                }
            }
        }
    }

    // MARK: - 导航目的地

    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        switch route {
        case .logs:
            LogStreamView(
                host: host, dependencies: dependencies,
                source: LogSource(
                    id: "container-\(container.id)", title: container.name,
                    subtitle: container.image, kind: .container(id: container.id, name: container.name)
                ),
                sudo: viewModel.usesSudo
            )
        case .console:
            TerminalScreen(
                host: host, connectionManager: dependencies.connectionManager,
                autoCommand: viewModel.consoleCommand(for: container)
            )
        }
    }

    // MARK: - 逻辑

    private func loadDetail() async {
        loading = detail == nil
        detail = await viewModel.detail(for: container)
        loading = false
    }

    private func perform(_ action: ContainerAction) {
        Task {
            await viewModel.perform(action, on: container)
            await loadDetail()
        }
    }

    // MARK: - 通用块

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(title).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                content()
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    private func infoRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                HStack(spacing: ConnSpacing.sm) {
                    Text(row.0).font(.connSubheadline).foregroundStyle(.connMuted)
                    Spacer()
                    Text(row.1).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
                        .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.vertical, ConnSpacing.sm)
            }
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
