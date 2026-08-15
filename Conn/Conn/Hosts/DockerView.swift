import ConnKit
import ConnOps
import ConnTerminal
import ConnUI
import SwiftUI

/// Docker 管理（Phase 8+）：容器（列表 / 详情 / 启停重启 / 日志 / 控制台 / 删除）
/// + 镜像（列表 / 删除 / 清理悬空）+ 卷 / 网络（列表 / 详情，均只读）。
/// 五类资源通过导航标题菜单切换，写操作走各列表右上角的更多菜单。
struct DockerView: View {
    let viewModel: DockerViewModel
    @Environment(SettingsStore.self) private var settings
    @State var tab: Tab
    @State private var route: Route?
    @State var operationSheet: OperationSheet?
    /// 控制台单独拆出来走 `.fullScreenCover`——`route` 剩下的几个目的地
    /// （容器/卷/网络/镜像详情）仍是 push，两种呈现方式不能共用同一个 optional。
    @State private var consoleContainer: ContainerInfo?
    @State private var terminalLauncher: TerminalLaunchPresentation
    /// 每类资源各自保存搜索词；切换资源再返回时恢复原过滤条件。
    @State private var searches: [Tab: String] = [:]
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies, viewModel: DockerViewModel) {
        self.host = host
        self.dependencies = dependencies
        self.viewModel = viewModel
        _tab = State(initialValue: Self.initialTab())
        _terminalLauncher = State(initialValue: TerminalLaunchPresentation(dependencies: dependencies))
    }

    var body: some View {
        content
            .task { await loadForSmokeRoute() }
            .task { await autoRefreshLoop() }
            .sheet(item: operationSheetBinding, content: operationSheetView)
            .alert(L("Docker 操作"), isPresented: messageBinding) {
                Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
            } message: {
                Text(viewModel.actionMessage ?? "")
            }
            .navigationDestination(item: $route, destination: destination)
            .fullScreenCover(item: pullPresentationBinding) { _ in
                DockerPullProgressView(operations: viewModel.operations)
            }
            .onChange(of: consoleContainer?.id) { _, _ in
                guard let container = consoleContainer else { return }
                consoleContainer = nil
                launchConsole(container)
            }
            .fullScreenCover(item: $terminalLauncher.route) { route in
                TerminalScreen(host: route.host, tabID: route.tabID, dependencies: dependencies)
            }
            .onChange(of: terminalLauncher.errorMessage) { _, message in
                if let message { viewModel.actionMessage = message }
            }
            .overlay { terminalLaunchProgress }
            .onDisappear { terminalLauncher.cancel() }
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: searchBinding,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: searchPrompt
            )
            .toolbar { resourceNavigationToolbar }
    }

    @ViewBuilder
    private var terminalLaunchProgress: some View {
        if terminalLauncher.isLaunching {
            ProgressView(L("正在打开控制台…"))
                .padding(ConnSpacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ConnRadius.control))
        }
    }

    private func launchConsole(_ container: ContainerInfo) {
        guard let command = viewModel.containers.consoleCommand(for: container) else {
            viewModel.actionMessage = L("Docker 运行环境尚未探测完成")
            return
        }
        terminalLauncher.launch(TerminalLaunchRequest(
            host: host,
            policy: .createNew,
            source: .docker(containerName: container.name),
            initialCommand: command,
            replayInitialCommandOnReconnect: true
        ))
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
            if let runtime = viewModel.runtime {
                LogStreamView(
                    host: host, dependencies: dependencies,
                    source: LogSource(
                        id: "container-\(container.id)", title: container.name,
                        subtitle: container.image,
                        kind: .container(
                            id: container.id,
                            name: container.name,
                            runtime: runtime
                        )
                    ),
                    sudo: viewModel.usesSudo
                )
            } else {
                Text(L("Docker 运行环境尚未探测完成"))
            }
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
        case let .composeDetail(project):
            DockerComposeProjectDetailView(
                initialProject: project,
                viewModel: viewModel,
                host: host,
                dependencies: dependencies
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
            ConnRetryState(message, retryTitle: L("重试")) {
                Task { await viewModel.load() }
            }
        case .ready:
            VStack(spacing: ConnSpacing.sm) {
                DockerDetail.operationActivity(
                    viewModel.operations.activeOperationDescription
                )
                ScrollView {
                    switch tab {
                    case .containers: containerList
                    case .images: imageSection
                    case .volumes: volumeSection
                    case .networks: networkSection
                    case .compose:
                        DockerComposeListView(
                            model: viewModel.compose,
                            search: searchBinding,
                            open: { route = .composeDetail($0) }
                        )
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
            case .compose: await viewModel.compose.load()
            }
        }
    }

    private func loadForSmokeRoute() async {
        await viewModel.loadIfNeeded()
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["CONN_SMOKE_COMPOSE_DETAIL_ROUTE"] != nil {
                await viewModel.compose.load()
                if let project = viewModel.compose.items.first(where: { $0.name == "conn-web" }) {
                    route = .composeDetail(project)
                }
                return
            }
            if environment["CONN_SMOKE_COMPOSE_FORM"] != nil {
                await viewModel.compose.load()
                operationSheet = .addComposeProject
                return
            }
            guard environment["CONN_SMOKE_NETWORK_DETAIL_ROUTE"] != nil
                    || environment["CONN_SMOKE_NETWORK_CONTAINER_ROUTE"] != nil
            else { return }
            await viewModel.networks.load()
            if let network = viewModel.networks.items.first(where: { $0.name == "isolated" }) {
                route = .networkDetail(network)
            }
        #endif
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
        case .compose: await viewModel.compose.load()
        }
        let minimum = Duration.milliseconds(500)
        let elapsed = clock.now - start
        if elapsed < minimum { try? await Task.sleep(for: minimum - elapsed) }
    }

    @ToolbarContentBuilder
    private var resourceNavigationToolbar: some ToolbarContent {
        resourceTitleMenu
        resourceOperationMenu
    }

    /// 当前资源成为导航标题，点击标题菜单切换五类资源；不再在内容区堆第二排分段控件。
    @ToolbarContentBuilder
    private var resourceTitleMenu: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(Tab.allCases) { target in
                    Button { tab = target } label: {
                        Label(L(target.rawValue), systemImage: target == tab ? "checkmark" : target.systemImage)
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 3) {
                        Text(L(tab.rawValue))
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.connInk)
                    Text("\(L("Docker")) · \(hostTitle)")
                        .font(.system(size: 10))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("\(L("Docker"))，\(L(tab.rawValue))")
        }
    }

    /// 进入 Docker 后，右上角只承载当前资源操作；主机终端留在上一层工作台。
    @ToolbarContentBuilder
    private var resourceOperationMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                resourceOperationButtons
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .regular))
            }
            .disabled(!resourceOperationsEnabled)
            .accessibilityLabel(L("更多操作"))
        }
    }

    @ViewBuilder
    private var resourceOperationButtons: some View {
        switch tab {
        case .containers:
            Button { operationSheet = .runContainer } label: {
                Label(L("创建容器"), systemImage: "plus")
            }
        case .images:
            Button { operationSheet = .pullImage } label: {
                Label(L("拉取镜像"), systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) { Task { await viewModel.images.prune() } } label: {
                Label(L("清理悬空镜像"), systemImage: "trash")
            }
            Button(role: .destructive) {
                viewModel.operations.requestDestructiveAction(
                    .systemPrune(DockerSystemPruneOptions())
                )
            } label: {
                Label(L("清理 Docker 资源"), systemImage: "trash.slash")
            }
        case .volumes:
            Button { operationSheet = .createVolume } label: {
                Label(L("创建卷"), systemImage: "plus")
            }
        case .networks:
            Button { operationSheet = .createNetwork } label: {
                Label(L("创建网络"), systemImage: "plus")
            }
        case .compose:
            Button { operationSheet = .addComposeProject } label: {
                Label(L("手动添加项目"), systemImage: "plus")
            }
        }
    }

    private var resourceOperationsEnabled: Bool {
        viewModel.canWrite && (tab != .compose || viewModel.compose.dialect != nil)
    }

    private var hostTitle: String {
        if let note = host.note, !note.trimmingCharacters(in: .whitespaces).isEmpty { return note }
        return host.name
    }

}

// MARK: - 资源列表

extension DockerView {

    // MARK: - 容器

    private var containerList: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(
                count: String(format: L("共 %d 个容器"), filteredContainers.count)
            )
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
            DockerDetail.listHeader(
                count: String(format: L("共 %d 个镜像"), filteredImages.count)
            )
            DockerDetail.listBody(
                items: filteredImages,
                state: imagesListState,
                retry: { Task { await refreshImages() } },
                row: imageRow
            )
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
            // Button 的命中区默认只覆盖**实际绘制出来的内容**，Spacer 与留白不算，
            // 用户点行的空白处会没有反应。整块卡片都该是命中区。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { viewModel.images.requestRemoval(image) } label: {
                Label(L("删除"), systemImage: "trash")
            }
            .disabled(!viewModel.canWrite)
        }
    }

    // MARK: - 卷

    private var volumeSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(
                count: String(format: L("共 %d 个卷"), filteredVolumes.count)
            )
            DockerDetail.listBody(
                items: filteredVolumes,
                state: volumesListState,
                retry: { Task { await viewModel.volumes.load() } },
                row: volumeRow
            )
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
        .contextMenu {
            if viewModel.volumes.canRemove(volume) {
                Button(role: .destructive) { viewModel.volumes.requestRemoval(volume) } label: {
                    Label(L("删除"), systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(
                count: String(format: L("共 %d 个网络"), filteredNetworks.count)
            )
            DockerDetail.listBody(
                items: filteredNetworks,
                state: networksListState,
                retry: { Task { await viewModel.networks.load() } },
                row: networkRow
            )
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
        .contextMenu {
            if viewModel.networks.canRemove(network) {
                Button(role: .destructive) { viewModel.networks.requestRemoval(network) } label: {
                    Label(L("删除"), systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 不可用引导

    private func unavailableView(_ availability: DockerAvailability) -> some View {
        let text: String = switch availability {
        case .notInstalled:
            if viewModel.platformKind == .macOS {
                L("未检测到 Docker CLI。请确认这台 Mac 已安装 Docker Desktop。")
            } else {
                L("未检测到 Docker CLI。请确认该主机已安装 Docker。")
            }
        case .permissionDenied:
            if viewModel.platformKind == .linux {
                L("当前用户无权访问 Docker。\n将用户加入 docker 组：\nsudo usermod -aG docker $USER\n然后重新登录后重试。")
            } else {
                L("当前用户无权访问 Docker。请检查 Docker Desktop 或 Docker socket 的访问权限。")
            }
        case .daemonNotRunning:
            if viewModel.platformKind == .macOS {
                L("Docker Desktop 未运行。请在这台 Mac 上启动 Docker Desktop 后重试。")
            } else if viewModel.platformKind == .linux {
                L("Docker 守护进程未运行。\n请在服务器上启动：\nsudo systemctl start docker")
            } else {
                L("Docker 服务未运行。请在目标主机上启动 Docker 后重试。")
            }
        case .unsupportedPlatform:
            L("当前平台尚不支持 Docker 管理。")
        case .available:
            ""
        }
        return VStack(spacing: ConnSpacing.sm) {
            Image(systemName: "shippingbox").font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            ConnRetryState(text, retryTitle: L("重试")) {
                Task { await viewModel.load() }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl).padding(.horizontal, ConnSpacing.page)
    }

}

// MARK: - 分段与路由

// 拆到同文件的 extension 里而非塞进主体：五项分段后 Route 带自定义 Hashable，
// 与其余视图逻辑放一起会把 DockerView 主体推过 SwiftLint 的 300 行阈值。
extension DockerView {
    enum Tab: String, CaseIterable, Identifiable {
        case containers = "容器"
        case images = "镜像"
        case volumes = "卷"
        case networks = "网络"
        case compose = "Compose"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .containers: "shippingbox"
            case .images: "shippingbox.fill"
            case .volumes: "externaldrive.fill"
            case .networks: "point.3.connected.trianglepath.dotted"
            case .compose: "square.stack.3d.up.fill"
            }
        }
    }

    enum Route: Hashable, Identifiable {
        case detail(ContainerInfo), logs(ContainerInfo)
        case volumeDetail(VolumeInfo), networkDetail(NetworkInfo), imageDetail(ImageInfo)
        case composeDetail(DockerComposeProject)

        var id: String {
            switch self {
            case let .detail(container): "detail-\(container.id)"
            case let .logs(container): "logs-\(container.id)"
            case let .volumeDetail(volume): "volume-\(volume.name)"
            case let .networkDetail(network): "network-\(network.id)"
            case let .imageDetail(image): "image-\(image.id)"
            case let .composeDetail(project): "compose-\(project.name)"
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
    private var search: String { searches[tab] ?? "" }

    private var searchPrompt: String {
        switch tab {
        case .containers: L("搜索容器")
        case .images: L("搜索镜像")
        case .volumes: L("搜索卷")
        case .networks: L("搜索网络")
        case .compose: L("搜索 Compose 项目")
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searches[tab] ?? "" },
            set: { searches[tab] = $0 }
        )
    }

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
