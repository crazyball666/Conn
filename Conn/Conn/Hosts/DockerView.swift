import ConnKit
import ConnOps
import ConnUI
import SwiftUI

/// Docker 管理（Phase 8+）：容器（列表 / 详情 / 启停重启 / 日志 / 控制台 / 删除）
/// + 镜像（列表 / 删除 / 清理悬空）。分段切换，操作走行内菜单。
struct DockerView: View {
    let viewModel: DockerViewModel
    @State private var tab: Tab = .containers
    @State private var route: Route?
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies, viewModel: DockerViewModel) {
        self.host = host
        self.dependencies = dependencies
        self.viewModel = viewModel
    }

    enum Tab: String, CaseIterable, Identifiable { case containers = "容器", images = "镜像"; var id: String { rawValue } }

    enum Route: Hashable, Identifiable {
        case detail(ContainerInfo), logs(ContainerInfo), console(ContainerInfo)
        var id: String {
            switch self {
            case let .detail(container): "detail-\(container.id)"
            case let .logs(container): "logs-\(container.id)"
            case let .console(container): "console-\(container.id)"
            }
        }
    }

    var body: some View {
        content
            .task { await viewModel.loadIfNeeded() }
            .alert(L("删除容器"), isPresented: removalBinding, presenting: viewModel.pendingRemoval) { _ in
                Button(L("删除容器"), role: .destructive) { Task { await viewModel.confirmRemoval() } }
                Button(L("取消"), role: .cancel) { viewModel.pendingRemoval = nil }
            } message: { container in
                Text(String(format: L("删除容器 %@？此操作不可撤销（docker rm -f）。"), container.name))
            }
            .alert(L("删除镜像"), isPresented: imageRemovalBinding, presenting: viewModel.pendingImageRemoval) { _ in
                Button(L("删除"), role: .destructive) { Task { await viewModel.confirmImageRemoval() } }
                Button(L("取消"), role: .cancel) { viewModel.pendingImageRemoval = nil }
            } message: { image in
                Text(String(format: L("删除镜像 %@？"), image.displayName))
            }
            .alert(L("Docker 操作"), isPresented: messageBinding) {
                Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
            } message: {
                Text(viewModel.actionMessage ?? "")
            }
            .navigationDestination(item: $route, destination: destination)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case let .detail(container):
            ContainerDetailView(host: host, dependencies: dependencies, container: container, viewModel: viewModel)
        case let .logs(container):
            LogStreamView(
                host: host, dependencies: dependencies,
                source: LogSource(
                    id: "container-\(container.id)", title: container.name,
                    subtitle: container.image, kind: .container(id: container.id, name: container.name)
                ),
                sudo: viewModel.usesSudo
            )
        case let .console(container):
            TerminalScreen(
                host: host, connectionManager: dependencies.connectionManager,
                autoCommand: viewModel.consoleCommand(for: container)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(L("读取容器…")).font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xxl)
        case let .unavailable(availability):
            unavailableView(availability)
        case let .failed(message):
            VStack(spacing: ConnSpacing.sm) {
                ConnBanner(message, systemImage: "exclamationmark.triangle")
                Button(L("重试")) { Task { await viewModel.load() } }.font(.connBody).foregroundStyle(.connAccent)
            }
            .padding(.vertical, ConnSpacing.md)
        case .ready:
            VStack(spacing: ConnSpacing.sm) {
                Picker(L("段"), selection: $tab) {
                    ForEach(Tab.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                ScrollView {
                    switch tab {
                    case .containers: containerList
                    case .images: imageSection
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            }
        }
    }

    /// 下拉刷新当前分段（静默重拉，不切 loading；给刷新动画一个最短时长避免闪跳）。
    private func refresh() async {
        let clock = ContinuousClock()
        let start = clock.now
        switch tab {
        case .containers: await viewModel.refreshContainers()
        case .images: await viewModel.loadImages()
        }
        let minimum = Duration.milliseconds(500)
        let elapsed = clock.now - start
        if elapsed < minimum { try? await Task.sleep(for: minimum - elapsed) }
    }

    // MARK: - 容器

    private var containerList: some View {
        VStack(spacing: ConnSpacing.sm) {
            if viewModel.containers.isEmpty {
                Text(L("该主机上没有容器")).font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(viewModel.containers) { container in
                    containerRow(container)
                }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    private func containerRow(_ container: ContainerInfo) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Button { route = .detail(container) } label: {
                HStack(spacing: ConnSpacing.sm) {
                    ConnStatusDot(status(for: container.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name).font(.connHeadline).foregroundStyle(.connInk).lineLimit(1)
                        Text(container.image).font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                        Text(container.isRunning ? runningStats(container) : container.status)
                            .font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                    }
                    Spacer(minLength: ConnSpacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if viewModel.busyContainerID == container.id {
                ProgressView()
            } else {
                containerMenu(container)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func containerMenu(_ container: ContainerInfo) -> some View {
        Menu {
            if container.isRunning {
                Button { act(.stop, container) } label: { Label(L("停止"), systemImage: "stop.circle") }
                Button { act(.restart, container) } label: { Label(L("重启"), systemImage: "arrow.clockwise.circle") }
                Button { route = .console(container) } label: { Label(L("控制台"), systemImage: "terminal") }
            } else {
                Button { act(.start, container) } label: { Label(L("启动"), systemImage: "play.circle") }
            }
            Button { route = .logs(container) } label: { Label(L("查看日志"), systemImage: "doc.text.magnifyingglass") }
            Button { route = .detail(container) } label: { Label(L("详情"), systemImage: "info.circle") }
            Divider()
            Button(role: .destructive) { viewModel.requestRemoval(container) } label: {
                Label(L("删除"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(.connAccent)
        }
        .connHitTarget()
    }

    // MARK: - 镜像

    private var imageSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            HStack {
                Text(String(format: L("共 %d 个镜像"), viewModel.images.count))
                    .font(.connData(.caption2)).foregroundStyle(.connDim)
                Spacer()
                Menu {
                    Button { Task { await viewModel.pruneImages() } } label: {
                        Label(L("清理悬空镜像"), systemImage: "trash")
                    }
                    Button { Task { await viewModel.loadImages() } } label: {
                        Label(L("刷新"), systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.connAccent)
                }
            }
            if let error = viewModel.imagesError {
                ConnBanner(error, systemImage: "exclamationmark.triangle")
            } else if !viewModel.imagesLoaded {
                ProgressView(L("读取镜像…")).font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
            } else if viewModel.images.isEmpty {
                Text(L("没有镜像")).font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(viewModel.images) { image in imageRow(image) }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await viewModel.loadImagesIfNeeded() }
    }

    private func imageRow(_ image: ImageInfo) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: "shippingbox.fill").font(.system(size: 18))
                .foregroundStyle(image.isDangling ? .connMuted : .connAccent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayName).font(.connData(.footnote)).foregroundStyle(.connInk).lineLimit(1)
                Text("\(image.size) · \(image.created) · \(image.imageID)")
                    .font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
            }
            Spacer(minLength: ConnSpacing.xs)
            if viewModel.busyImageID == image.id {
                ProgressView()
            } else {
                Menu {
                    Button(role: .destructive) { viewModel.requestImageRemoval(image) } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(.connAccent)
                }
                .connHitTarget()
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    // MARK: - 不可用引导

    private func unavailableView(_ availability: DockerAvailability) -> some View {
        let text: String = switch availability {
        case .notInstalled:
            L("未检测到 Docker CLI。请确认该服务器已安装 Docker。")
        case .permissionDenied:
            L("当前用户无权访问 Docker。\n将用户加入 docker 组：\nsudo usermod -aG docker $USER\n然后重新登录后重试。")
        case .daemonNotRunning:
            L("Docker 守护进程未运行。\n请在服务器上启动：\nsudo systemctl start docker")
        case .available:
            ""
        }
        return VStack(spacing: ConnSpacing.sm) {
            Image(systemName: "shippingbox").font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            Text(text).font(.connSubheadline).foregroundStyle(.connMuted).multilineTextAlignment(.center)
            Button(L("重试")) { Task { await viewModel.load() } }.font(.connBody).foregroundStyle(.connAccent)
        }
        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl).padding(.horizontal, ConnSpacing.page)
    }

    // MARK: - 辅助

    private func act(_ action: ContainerAction, _ container: ContainerInfo) {
        Task { await viewModel.perform(action, on: container) }
    }

    private func runningStats(_ container: ContainerInfo) -> String {
        let cpu = container.cpuPercent.map { String(format: "CPU %.1f%%", $0) } ?? "CPU —"
        let mem = container.memPercent.map { String(format: L("内存 %.1f%%"), $0) } ?? L("内存 —")
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

    private var removalBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingRemoval != nil }, set: { if !$0 { viewModel.pendingRemoval = nil } })
    }

    private var imageRemovalBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingImageRemoval != nil }, set: { if !$0 { viewModel.pendingImageRemoval = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
