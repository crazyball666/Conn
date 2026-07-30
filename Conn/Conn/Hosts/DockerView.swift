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
    @State private var tab: Tab
    @State private var route: Route?
    /// 四个分段共用一个搜索词——切分段时清空（见下方 `.onChange`），
    /// 否则上一分段的过滤条件会悄悄套在新分段上。
    @State private var search = ""
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies, viewModel: DockerViewModel) {
        self.host = host
        self.dependencies = dependencies
        self.viewModel = viewModel
        _tab = State(initialValue: Self.initialTab())
    }

    /// 四段截图验收要逐段看（容器/镜像/卷/网络），但 `simctl` 没有点击能力，
    /// 点不到分段选择器——`CONN_SMOKE_DOCKER_TAB` 让冒烟脚本直接从目标分段起步，
    /// 与 `HostDetailView` 的 `CONN_SMOKE_SEGMENT` 同一套路数。仅 DEBUG 编译。
    private static func initialTab() -> Tab {
        #if DEBUG
            switch ProcessInfo.processInfo.environment["CONN_SMOKE_DOCKER_TAB"] {
            case "images": .images
            case "volumes": .volumes
            case "networks": .networks
            default: .containers
            }
        #else
            .containers
        #endif
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

    // 这一层只管「从 DockerView 直接推一层」——卷/网络/镜像详情页各自往下再推容器详情
    // 用的是它们自己的本地 route 状态（见三个详情页文件顶部的说明），不会回头改这里的
    // `route`。同一个 `route` 被两级导航复用会让 `navigationDestination(item:)`
    // 压不对栈（已用模拟器实测：返回键甚至不显示中间那一屏的标题），
    // 所以这里绝不能再接回调闭包。
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
            // 磁盘占用来自 `viewModel.diskUsage`（Task 7 接入）；查不到时为 nil，
            // 页面按设计显示「—」——它本就是「查不到就退化」的锦上添花字段。
            VolumeDetailView(
                volume: volume, viewModel: viewModel, size: viewModel.diskUsage?.volumeSize(volume.name),
                host: host, dependencies: dependencies
            )
        case let .networkDetail(network):
            NetworkDetailView(network: network, viewModel: viewModel, host: host, dependencies: dependencies)
        case let .imageDetail(image):
            ImageDetailView(
                image: image, viewModel: viewModel,
                users: ImageUsage.containersUsing(image, in: viewModel.containers.items),
                diskSize: viewModel.diskUsage?.imageSize(image.imageID),
                host: host, dependencies: dependencies
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
                // 切分段时清空搜索词，避免上一分段的过滤条件悄悄套在新分段上
                .onChange(of: tab) { _, _ in search = "" }
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
            case .images: await refreshImages()
            case .volumes: await viewModel.volumes.load()
            case .networks: await viewModel.networks.load()
            }
        }
    }

    /// 镜像列表重拉后，「未使用」判定要跟着用最新的容器列表重算一遍，
    /// 否则展示的还是上一次判定。
    ///
    /// 这里两条命令一起发（镜像 + 容器），而不是只重拉镜像：只拉镜像时，
    /// 用户停在镜像分段、服务器上新起了一个用镜像 X 的容器，下拉刷新后 X
    /// 仍会带着「未使用」徽标——而且自动刷新循环每轮都会重复这个错误结论，
    /// 永不自愈。设计文档本来就认下了「多跑一次 docker ps -a 也值」这笔账，
    /// 这里用它换正确性。
    private func refreshImages() async {
        async let imagesLoad: Void = viewModel.images.load()
        async let containersRefresh: Void = viewModel.containers.refresh()
        _ = await (imagesLoad, containersRefresh)
        viewModel.images.refreshUsage(containers: viewModel.containers.items)
    }

    /// 下拉刷新当前分段（静默重拉，不切 loading；给刷新动画一个最短时长避免闪跳）。
    private func refresh() async {
        let clock = ContinuousClock()
        let start = clock.now
        switch tab {
        case .containers: await viewModel.containers.refresh()
        case .images: await refreshImages()
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
            ConnSearchField(L("搜索容器"), text: $search)
            if sortedContainers.isEmpty {
                // 搜索词非空但无匹配时不能说「没有容器」——主机上可能明明有 20 个，
                // 只是用户搜错了一个字母，那是对服务器状态的事实性错误陈述。
                Text(search.isEmpty ? L("该主机上没有容器") : L("没有匹配的容器"))
                    .font(.connSubheadline).foregroundStyle(.connMuted)
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
    /// 排序作用于**过滤后**的列表——搜索词非空时只在匹配到的容器里排。
    private var sortedContainers: [ContainerInfo] {
        let source = filteredContainers
        let running = source.filter(\.isRunning)
        let otherActive = source.filter { $0.isActive && !$0.isRunning }
        let inactive = source.filter { !$0.isActive }
        return running + otherActive + inactive
    }

    // MARK: - 镜像

    private var imageSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            HStack {
                Text(String(format: L("共 %d 个镜像"), filteredImages.count))
                    .font(.connData(.caption2)).foregroundStyle(.connDim)
                Spacer()
                Menu {
                    Button { Task { await viewModel.images.prune() } } label: {
                        Label(L("清理悬空镜像"), systemImage: "trash")
                    }
                    Button { Task { await refreshImages() } } label: {
                        Label(L("刷新"), systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.connAccent)
                }
            }
            ConnSearchField(L("搜索镜像"), text: $search)
            DockerDetail.listBody(items: filteredImages, state: imagesListState) { image in imageRow(image) }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await viewModel.loadImagesWithUsage() }
        // 与列表加载并行、不互相等待——失败时保持 nil，摘要区显示「—」，不弹错误。
        .task { await viewModel.loadDiskUsage() }
    }

    private func imageRow(_ image: ImageInfo) -> some View {
        let unused = viewModel.images.unusedIDs.contains(image.id)
        return Button { route = .imageDetail(image) } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "shippingbox.fill").font(.system(size: 18))
                    .foregroundStyle(image.isDangling ? .connMuted : .connAccent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.displayName).font(.connData(.footnote)).foregroundStyle(.connInk).lineLimit(1)
                    Text("\(image.size) · \(image.created) · \(image.imageID)")
                        .font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)
                if unused {
                    StatusPill(L("未使用"), semantic: .warn)
                }
                if viewModel.images.busyImageID == image.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.connMuted)
                }
            }
            .padding(ConnSpacing.cardPadding)
            .connSurface(cornerRadius: ConnRadius.card)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { viewModel.images.requestRemoval(image) } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
    }

    // MARK: - 卷

    private var volumeSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(count: String(format: L("共 %d 个卷"), filteredVolumes.count)) {
                Task { await viewModel.volumes.load() }
            }
            ConnSearchField(L("搜索卷"), text: $search)
            DockerDetail.listBody(items: filteredVolumes, state: volumesListState) { volume in volumeRow(volume) }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await viewModel.volumes.loadIfNeeded() }
        // 与列表加载并行、不互相等待——失败时保持 nil，详情页大小栏显示「—」，不弹错误。
        .task { await viewModel.loadDiskUsage() }
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
            DockerDetail.listHeader(count: String(format: L("共 %d 个网络"), filteredNetworks.count)) {
                Task { await viewModel.networks.load() }
            }
            ConnSearchField(L("搜索网络"), text: $search)
            DockerDetail.listBody(items: filteredNetworks, state: networksListState) { network in networkRow(network) }
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
        case volumeDetail(VolumeInfo), networkDetail(NetworkInfo), imageDetail(ImageInfo)

        var id: String {
            switch self {
            case let .detail(container): "detail-\(container.id)"
            case let .logs(container): "logs-\(container.id)"
            case let .console(container): "console-\(container.id)"
            case let .volumeDetail(volume): "volume-\(volume.name)"
            case let .networkDetail(network): "network-\(network.id)"
            case let .imageDetail(image): "image-\(image.id)"
            }
        }

        // VolumeInfo / NetworkInfo（ConnOps 域层）只 Equatable，没有 Hashable，
        // 编译器无法合成——按上面已算好的 id 手写哈希与相等，不必为此改动域层。
        static func == (lhs: Route, rhs: Route) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
}

// MARK: - 搜索过滤

// 同样拆到同文件 extension：四条过滤规则本身不长，但塞进主体会跟 Tab/Route 一样
// 把 DockerView 顶过 type_body_length 阈值。过滤是纯本地字符串匹配，不触发任何命令。
extension DockerView {
    private var filteredContainers: [ContainerInfo] {
        guard !search.isEmpty else { return viewModel.containers.items }
        return viewModel.containers.items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.image.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredImages: [ImageInfo] {
        guard !search.isEmpty else { return viewModel.images.items }
        return viewModel.images.items.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    private var filteredVolumes: [VolumeInfo] {
        guard !search.isEmpty else { return viewModel.volumes.items }
        return viewModel.volumes.items.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var filteredNetworks: [NetworkInfo] {
        guard !search.isEmpty else { return viewModel.networks.items }
        return viewModel.networks.items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.driver.localizedCaseInsensitiveContains(search)
        }
    }

    // `DockerDetail.listBody` 的状态入参也挪到这里——同样是为了不把主体顶过
    // type_body_length，顺带让三个分段的调用点从多行拆装收成一行。
    //
    // `emptyText` 按搜索词是否为空二选一：搜索无匹配时不能沿用「没有镜像/卷/网络」
    // 这类断言主机上完全没有该类资源的文案——那是对服务器状态的事实性错误陈述。
    private var imagesListState: DockerDetail.ListState {
        .init(
            error: viewModel.images.error, loaded: viewModel.images.loaded, loadingText: L("读取镜像…"),
            emptyText: search.isEmpty ? L("没有镜像") : L("没有匹配的镜像")
        )
    }

    private var volumesListState: DockerDetail.ListState {
        .init(
            error: viewModel.volumes.error, loaded: viewModel.volumes.loaded, loadingText: L("读取卷…"),
            emptyText: search.isEmpty ? L("没有卷") : L("没有匹配的卷")
        )
    }

    private var networksListState: DockerDetail.ListState {
        .init(
            error: viewModel.networks.error, loaded: viewModel.networks.loaded,
            loadingText: L("读取网络…"), emptyText: search.isEmpty ? L("没有网络") : L("没有匹配的网络")
        )
    }
}
