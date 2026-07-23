import ConnKit
import ConnOps
import ConnUI
import SwiftUI

/// Docker 容器管理（Phase 8）：列表 + 启停/重启/删除 + 容器日志入口。
struct DockerView: View {
    @State private var viewModel: DockerViewModel
    @State private var logTarget: ContainerInfo?
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        self.dependencies = dependencies
        _viewModel = State(initialValue: DockerViewModel(host: host, dependencies: dependencies))
    }

    var body: some View {
        content
            .task { await viewModel.load() }
            .confirmationDialog(
                removalPrompt, isPresented: removalBinding, titleVisibility: .visible
            ) {
                Button("删除容器", role: .destructive) { Task { await viewModel.confirmRemoval() } }
                Button("取消", role: .cancel) { viewModel.pendingRemoval = nil }
            }
            .alert("容器操作", isPresented: messageBinding) {
                Button("好", role: .cancel) { viewModel.actionMessage = nil }
            } message: {
                Text(viewModel.actionMessage ?? "")
            }
            .navigationDestination(item: $logTarget) { container in
                LogStreamView(
                    host: host, dependencies: dependencies,
                    source: LogSource(
                        id: "container-\(container.id)", title: container.name,
                        subtitle: container.image, kind: .container(id: container.id, name: container.name)
                    ),
                    sudo: viewModel.usesSudo
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView("读取容器…").font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xxl)
        case let .unavailable(availability):
            unavailableView(availability)
        case let .failed(message):
            VStack(spacing: ConnSpacing.sm) {
                ConnBanner(message, systemImage: "exclamationmark.triangle")
                Button("重试") { Task { await viewModel.load() } }
                    .font(.connBody).foregroundStyle(.connAccent)
            }
            .padding(.vertical, ConnSpacing.md)
        case .ready:
            containerList
        }
    }

    private var containerList: some View {
        VStack(spacing: ConnSpacing.sm) {
            if viewModel.containers.isEmpty {
                Text("该主机上没有容器").font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(viewModel.containers) { container in
                    row(container)
                }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    private func row(_ container: ContainerInfo) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            ConnStatusDot(status(for: container.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.connHeadline).foregroundStyle(.connInk).lineLimit(1)
                Text(container.image).font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                Text(container.isRunning ? runningStats(container) : container.status)
                    .font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
            }
            Spacer(minLength: ConnSpacing.xs)
            if viewModel.busyContainerID == container.id {
                ProgressView()
            } else {
                menu(for: container)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func menu(for container: ContainerInfo) -> some View {
        Menu {
            if container.isRunning {
                Button { act(.stop, container) } label: { Label("停止", systemImage: "stop.circle") }
                Button { act(.restart, container) } label: { Label("重启", systemImage: "arrow.clockwise.circle") }
            } else {
                Button { act(.start, container) } label: { Label("启动", systemImage: "play.circle") }
            }
            Button { logTarget = container } label: { Label("查看日志", systemImage: "doc.text.magnifyingglass") }
            Divider()
            Button(role: .destructive) { viewModel.requestRemoval(container) } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(.connAccent)
        }
        .connHitTarget()
    }

    private func unavailableView(_ availability: DockerAvailability) -> some View {
        let text: String = switch availability {
        case .notInstalled:
            "未检测到 Docker CLI。请确认该服务器已安装 Docker。"
        case .permissionDenied:
            "当前用户无权访问 Docker。\n将用户加入 docker 组：\nsudo usermod -aG docker $USER\n然后重新登录后重试。"
        case .available:
            ""
        }
        return VStack(spacing: ConnSpacing.sm) {
            Image(systemName: "shippingbox").font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            Text(text).font(.connSubheadline).foregroundStyle(.connMuted).multilineTextAlignment(.center)
            Button("重试") { Task { await viewModel.load() } }.font(.connBody).foregroundStyle(.connAccent)
        }
        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl).padding(.horizontal, ConnSpacing.page)
    }

    // MARK: - 辅助

    private func act(_ action: ContainerAction, _ container: ContainerInfo) {
        Task { await viewModel.perform(action, on: container) }
    }

    private func runningStats(_ container: ContainerInfo) -> String {
        let cpu = container.cpuPercent.map { String(format: "CPU %.1f%%", $0) } ?? "CPU —"
        let mem = container.memPercent.map { String(format: "内存 %.1f%%", $0) } ?? "内存 —"
        return "\(container.status) · \(cpu) · \(mem)"
    }

    private func status(for state: ContainerInfo.State) -> ConnHealthStatus {
        switch state {
        case .running: .ok
        case .paused, .restarting: .warn
        case .dead: .crit
        case .exited, .created, .removing, .unknown: .unknown
        }
    }

    private var removalPrompt: String {
        viewModel.pendingRemoval.map { "删除容器 \($0.name)？此操作不可撤销（docker rm -f）。" } ?? ""
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingRemoval != nil }, set: { if !$0 { viewModel.pendingRemoval = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
