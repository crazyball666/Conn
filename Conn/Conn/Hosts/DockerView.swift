import ConnKit
import ConnOps
import ConnUI
import SwiftUI

/// Docker 管理（Phase 8+）：容器（列表 / 详情 / 启停重启 / 日志 / 控制台 / 删除）
/// + 镜像（列表 / 删除 / 清理悬空）+ 卷 / 网络（列表 / 详情，均只读）。
/// 四项分段切换，写操作走行内菜单。
struct DockerView: View {
    let viewModel: DockerViewModel
    @Environment(SettingsStore.self) private var settings
    @State private var tab: Tab = .containers
    @State private var route: Route?
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies, viewModel: DockerViewModel) {
        self.host = host
        self.dependencies = dependencies
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .task { await viewModel.loadIfNeeded() }
            .task { await autoRefreshLoop() }
            .alert(L("删除容器"), isPresented: removalBinding, presenting: viewModel.containers.pendingRemoval) { _ in
                Button(L("删除容器"), role: .destructive) { Task { await viewModel.containers.confirmRemoval() } }
                Button(L("取消"), role: .cancel) { viewModel.containers.pendingRemoval = nil }
            } message: { container in
                Text(String(format: L("删除容器 %@？此操作不可撤销（docker rm -f）。"), container.name))
            }
            .alert(L("删除镜像"), isPresented: imageRemovalBinding, presenting: viewModel.images.pendingRemoval) { _ in
                Button(L("删除"), role: .destructive) { Task { await viewModel.images.confirmRemoval() } }
                Button(L("取消"), role: .cancel) { viewModel.images.pendingRemoval = nil }
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

    // 参数名故意不叫 route——它是本函数的局部值，而 volumeDetail/networkDetail
    // 分支要在闭包里给 @State private var route 赋新值，同名会被局部值遮蔽掉。
    @ViewBuilder
    private func destination(_ target: Route) -> some View {
        switch target {
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
                autoCommand: viewModel.containers.consoleCommand(for: container)
            )
        case let .volumeDetail(volume):
            // 磁盘占用（system df -v）要到 Task 7 才接入 DockerViewModel，本任务先传
            // nil，页面按设计显示「—」——它本就是「查不到就退化」的锦上添花字段。
            VolumeDetailView(volume: volume, model: viewModel.volumes, size: nil) { container in
                route = .detail(container)
            }
        case let .networkDetail(network):
            NetworkDetailView(network: network, model: viewModel.networks) { containerID in
                // AttachedContainer 只有 id/name/ipv4，不是完整 ContainerInfo，
                // 按 id 到容器列表里回查；找不到（容器已被删）时不跳转。
                if let container = viewModel.containers.items.first(where: { $0.id == containerID }) {
                    route = .detail(container)
                }
            }
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
                    case .volumes: volumeSection
                    case .networks: networkSection
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            }
        }
    }

    /// 按设置页的刷新间隔周期性静默刷新当前分段（仅在 Docker 段可见时运行）。
    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(settings.dockerRefreshInterval.rawValue))
            guard !Task.isCancelled, viewModel.hasLoaded else { continue }
            switch tab {
            case .containers: await viewModel.containers.refresh()
            case .images: await viewModel.images.load()
            case .volumes: await viewModel.volumes.load()
            case .networks: await viewModel.networks.load()
            }
        }
    }

    /// 下拉刷新当前分段（静默重拉，不切 loading；给刷新动画一个最短时长避免闪跳）。
    private func refresh() async {
        let clock = ContinuousClock()
        let start = clock.now
        switch tab {
        case .containers: await viewModel.containers.refresh()
        case .images: await viewModel.images.load()
        case .volumes: await viewModel.volumes.load()
        case .networks: await viewModel.networks.load()
        }
        let minimum = Duration.milliseconds(500)
        let elapsed = clock.now - start
        if elapsed < minimum { try? await Task.sleep(for: minimum - elapsed) }
    }

    // MARK: - 容器

    private var containerList: some View {
        VStack(spacing: ConnSpacing.sm) {
            if viewModel.containers.items.isEmpty {
                Text(L("该主机上没有容器")).font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(sortedContainers) { container in
                    ContainerCard(container: container) { route = .detail(container) }
                }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    /// 运行中优先：运行 → 其它活动（重启中/暂停）→ 已停止；组内保持 docker 原序。
    private var sortedContainers: [ContainerInfo] {
        let running = viewModel.containers.items.filter(\.isRunning)
        let otherActive = viewModel.containers.items.filter { $0.isActive && !$0.isRunning }
        let inactive = viewModel.containers.items.filter { !$0.isActive }
        return running + otherActive + inactive
    }

    // MARK: - 镜像

    private var imageSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            HStack {
                Text(String(format: L("共 %d 个镜像"), viewModel.images.items.count))
                    .font(.connData(.caption2)).foregroundStyle(.connDim)
                Spacer()
                Menu {
                    Button { Task { await viewModel.images.prune() } } label: {
                        Label(L("清理悬空镜像"), systemImage: "trash")
                    }
                    Button { Task { await viewModel.images.load() } } label: {
                        Label(L("刷新"), systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.connAccent)
                }
            }
            if let error = viewModel.images.error {
                ConnBanner(error, systemImage: "exclamationmark.triangle")
            } else if !viewModel.images.loaded {
                ProgressView(L("读取镜像…")).font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
            } else if viewModel.images.items.isEmpty {
                Text(L("没有镜像")).font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(viewModel.images.items) { image in imageRow(image) }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await viewModel.images.loadIfNeeded() }
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
            if viewModel.images.busyImageID == image.id {
                ProgressView()
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
        .contextMenu {
            Button(role: .destructive) { viewModel.images.requestRemoval(image) } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
    }

    // MARK: - 卷

    private var volumeSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(count: String(format: L("共 %d 个卷"), viewModel.volumes.items.count)) {
                Task { await viewModel.volumes.load() }
            }
            if let error = viewModel.volumes.error {
                ConnBanner(error, systemImage: "exclamationmark.triangle")
            } else if !viewModel.volumes.loaded {
                ProgressView(L("读取卷…")).font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
            } else if viewModel.volumes.items.isEmpty {
                Text(L("没有卷")).font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(viewModel.volumes.items) { volume in volumeRow(volume) }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await viewModel.volumes.loadIfNeeded() }
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        let unused = viewModel.volumes.unusedNames.contains(volume.name)
        return DockerDetail.resourceRow(
            icon: "externaldrive.fill", accented: true,
            title: (volume.name, "\(volume.driver) · \(volume.scope)"),
            badge: unused ? (L("未使用"), .warn) : nil
        ) { route = .volumeDetail(volume) }
    }

    // MARK: - 网络

    private var networkSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(count: String(format: L("共 %d 个网络"), viewModel.networks.items.count)) {
                Task { await viewModel.networks.load() }
            }
            if let error = viewModel.networks.error {
                ConnBanner(error, systemImage: "exclamationmark.triangle")
            } else if !viewModel.networks.loaded {
                ProgressView(L("读取网络…")).font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
            } else if viewModel.networks.items.isEmpty {
                Text(L("没有网络")).font(.connSubheadline).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(viewModel.networks.items) { network in networkRow(network) }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await viewModel.networks.loadIfNeeded() }
    }

    private func networkRow(_ network: NetworkInfo) -> some View {
        // 预置网络（bridge/host/none）优先展示「预置」而非「未使用」——
        // 后者暗示可删，而预置网络永远删不掉，混着打会误导用户。
        let badge: (text: String, semantic: StatusPill.Semantic)? = if network.isPredefined {
            (L("预置"), .info)
        } else if viewModel.networks.unusedNames.contains(network.name) {
            (L("未使用"), .warn)
        } else {
            nil
        }
        return DockerDetail.resourceRow(
            icon: "point.3.connected.trianglepath.dotted", accented: !network.isPredefined,
            title: (network.name, "\(network.driver) · \(network.scope)"), badge: badge
        ) { route = .networkDetail(network) }
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

    private var removalBinding: Binding<Bool> {
        Binding(get: { viewModel.containers.pendingRemoval != nil }, set: { if !$0 { viewModel.containers.pendingRemoval = nil } })
    }

    private var imageRemovalBinding: Binding<Bool> {
        Binding(get: { viewModel.images.pendingRemoval != nil }, set: { if !$0 { viewModel.images.pendingRemoval = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}

// MARK: - 分段与路由

// 拆到同文件的 extension 里而非塞进主体：四项分段后 Route 带自定义 Hashable，
// 与其余视图逻辑放一起会把 DockerView 主体推过 SwiftLint 的 300 行阈值。
extension DockerView {
    enum Tab: String, CaseIterable, Identifiable {
        case containers = "容器"
        case images = "镜像"
        case volumes = "卷"
        case networks = "网络"
        var id: String { rawValue }
    }

    enum Route: Hashable, Identifiable {
        case detail(ContainerInfo), logs(ContainerInfo), console(ContainerInfo)
        case volumeDetail(VolumeInfo), networkDetail(NetworkInfo)

        var id: String {
            switch self {
            case let .detail(container): "detail-\(container.id)"
            case let .logs(container): "logs-\(container.id)"
            case let .console(container): "console-\(container.id)"
            case let .volumeDetail(volume): "volume-\(volume.name)"
            case let .networkDetail(network): "network-\(network.id)"
            }
        }

        // VolumeInfo / NetworkInfo（ConnOps 域层）只 Equatable，没有 Hashable，
        // 编译器无法合成——按上面已算好的 id 手写哈希与相等，不必为此改动域层。
        static func == (lhs: Route, rhs: Route) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
}
