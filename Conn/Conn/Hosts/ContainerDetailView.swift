import ConnKit
import ConnOps
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 容器详情：inspect 信息 + 行内操作（启停重启 / 控制台 / 日志 / 删除）。
struct ContainerDetailView: View {
    let host: Host
    let dependencies: AppDependencies
    let container: ContainerInfo
    let viewModel: DockerViewModel

    @State private var detail: ContainerDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var route: Route?
    @State private var terminalLauncher: TerminalLaunchPresentation
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter

    init(
        host: Host,
        dependencies: AppDependencies,
        container: ContainerInfo,
        viewModel: DockerViewModel
    ) {
        self.host = host
        self.dependencies = dependencies
        self.container = container
        self.viewModel = viewModel
        _terminalLauncher = State(initialValue: TerminalLaunchPresentation(dependencies: dependencies))
    }

    /// 本页自己的下一跳（日志/挂载卷详情/网络详情）——挂载与网络行的跳转
    /// 落在这里而不是回调给 `DockerView`，理由见文件顶部导航栈说明。
    enum Route: Hashable, Identifiable {
        case logs
        case volumeDetail(VolumeInfo), networkDetail(NetworkInfo)

        var id: String {
            switch self {
            case .logs: "logs"
            case let .volumeDetail(volume): "volume-\(volume.name)"
            case let .networkDetail(network): "network-\(network.id)"
            }
        }

        // VolumeInfo / NetworkInfo（ConnOps 域层）只 Equatable，没有 Hashable，
        // 编译器无法合成——按上面已算好的 id 手写哈希与相等（与 `DockerView.Route` 同款）。
        static func == (lhs: Route, rhs: Route) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                DockerDetail.operationActivity(
                    viewModel.operations.activeOperationDescription
                )
                actionBar
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
                    if let errorMessage {
                        DockerDetail.errorRecovery(errorMessage) {
                            Task { await loadDetail() }
                        }
                    }
                    if let detail {
                        summarySection(detail)
                        listSection(L("端口"), detail.ports, icon: "network")
                        mountsSection(detail)
                        networksSection(detail)
                        listSection(L("环境变量"), detail.env, icon: "leaf")
                        commandSection(detail)
                    }
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
        .onChange(of: viewModel.operations.activeOperationDescription) { previous, current in
            if previous != nil, current == nil {
                Task { await loadDetail() }
            }
        }
        // 挂载/网络行要按名字反查 `viewModel.volumes/networks.items`——这两个模型只在
        // 各自分段出现过一次才会有数据。用户可能没点过「卷」「网络」分段就直接从
        // 容器列表点进详情，届时两个列表仍是空的，挂载/网络行会因为查无匹配而
        // 悄悄退化成不可点。主动 loadIfNeeded 一次（已加载则是空操作）避免这种依赖
        // 访问顺序的隐性退化。
        .task { await viewModel.volumes.loadIfNeeded() }
        .task { await viewModel.networks.loadIfNeeded() }
        .navigationDestination(item: $route, destination: routeDestination)
        .fullScreenCover(item: $terminalLauncher.route) { route in
            TerminalScreen(
                host: route.host,
                tabID: route.tabID,
                dependencies: dependencies,
                settings: settings
            )
        }
        .overlay { terminalLaunchProgress }
        .onDisappear { terminalLauncher.cancel() }
        .onChange(of: terminalLauncher.errorMessage) { _, message in
            toastCenter.show(message, style: .error)
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
                DockerDetail.actionButton(
                    L("停止"),
                    systemImage: "stop.circle",
                    disabled: !viewModel.canWrite
                ) { perform(.stop) }
                DockerDetail.actionButton(
                    L("重启"),
                    systemImage: "arrow.clockwise.circle",
                    disabled: !viewModel.canWrite
                ) { perform(.restart) }
                if isRunning {
                    DockerDetail.actionButton(
                        L("控制台"),
                        systemImage: "terminal"
                    ) { launchConsole() }
                }
            } else {
                DockerDetail.actionButton(
                    L("启动"),
                    systemImage: "play.circle",
                    disabled: !viewModel.canWrite
                ) { perform(.start) }
            }
            DockerDetail.actionButton(
                L("日志"),
                systemImage: "doc.text.magnifyingglass"
            ) { route = .logs }
            DockerDetail.actionButton(
                L("删除"),
                systemImage: "trash",
                tint: .connCrit,
                disabled: !viewModel.canWrite
            ) {
                viewModel.containers.requestRemoval(container)
            }
        }
    }

    @ViewBuilder
    private var terminalLaunchProgress: some View {
        if terminalLauncher.isLaunching {
            ProgressView(L("正在打开控制台…"))
                .padding(ConnSpacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ConnRadius.control))
        }
    }

    private func launchConsole() {
        guard let command = viewModel.containers.consoleCommand(for: container) else {
            toastCenter.show(L("Docker 运行环境尚未探测完成"), style: .warning)
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

    // MARK: - 概要

    private func summarySection(_ detail: ContainerDetail) -> some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
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
        DockerDetail.section(L("命令")) {
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
            DockerDetail.section(title) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        listRow(item, icon: icon, chevron: false)
                    }
                }
            }
        }
    }

    /// 挂载：逐项对上 `mountSources`——命中卷列表里的真实卷名才可点，绑定挂载
    /// （来源是宿主机路径）与匿名卷（来源是 Docker 自动生成的 64 位哈希名）都不可点。
    @ViewBuilder
    private func mountsSection(_ detail: ContainerDetail) -> some View {
        if !detail.mounts.isEmpty {
            DockerDetail.section(L("挂载")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(zip(detail.mounts, detail.mountSources).enumerated()), id: \.offset) { index, pair in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        mountRow(text: pair.0, source: pair.1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mountRow(text: String, source: String) -> some View {
        if isNamedVolumeSource(source), let volume = viewModel.volumes.items.first(where: { $0.name == source }) {
            Button { route = .volumeDetail(volume) } label: { listRow(text, icon: "externaldrive", chevron: true) }
                .buttonStyle(.plain)
        } else {
            listRow(text, icon: "externaldrive", chevron: false)
        }
    }

    /// 匿名卷得名是 Docker 自动生成的 64 位十六进制串——点进去也只会看到同一串哈希
    /// 当标题，没有辨识度，不给可点；绑定挂载（来源是宿主机路径）本来就不是卷。
    private func isNamedVolumeSource(_ source: String) -> Bool {
        !source.hasPrefix("/") && !(source.count == 64 && source.allSatisfy(\.isHexDigit))
    }

    /// 网络：展示串是 `"name"` 或 `"name · ip"`，按分隔符还原出纯网络名去反查列表。
    @ViewBuilder
    private func networksSection(_ detail: ContainerDetail) -> some View {
        if !detail.networks.isEmpty {
            DockerDetail.section(L("网络")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(detail.networks.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        networkRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkRow(_ text: String) -> some View {
        let name = text.components(separatedBy: " · ").first ?? text
        if let network = viewModel.networks.items.first(where: { $0.name == name }) {
            Button { route = .networkDetail(network) } label: {
                listRow(text, icon: "point.3.connected.trianglepath.dotted", chevron: true)
            }
            .buttonStyle(.plain)
        } else {
            listRow(text, icon: "point.3.connected.trianglepath.dotted", chevron: false)
        }
    }

    /// 端口 / 挂载 / 网络 / 环境四段共用的行版式，`chevron` 只在真能跳转时打开。
    private func listRow(_ text: String, icon: String, chevron: Bool) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.connMuted).frame(width: 16)
            Text(text).font(.connData(.caption2)).foregroundStyle(.connInk)
                .textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.connMuted)
            }
        }
        .padding(.vertical, ConnSpacing.xs)
        // 挂载 / 网络行是可点的（跳卷、网络详情）。Button 的命中区默认只覆盖实际
        // 绘制的内容，Spacer 与留白不算——不补这句，点行的空白处没有反应。
        .contentShape(Rectangle())
    }

    // MARK: - 导航目的地

    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        switch route {
        case .logs:
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
            VolumeDetailView(
                volume: volume, viewModel: viewModel, size: viewModel.diskUsage?.volumeSize(volume.name),
                host: host, dependencies: dependencies
            )
        case let .networkDetail(network):
            NetworkDetailView(network: network, viewModel: viewModel, host: host, dependencies: dependencies)
        }
    }

}

private extension ContainerDetailView {
    func loadDetail() async {
        loading = detail == nil
        do {
            detail = try await viewModel.containers.detail(for: container)
            errorMessage = nil
        } catch {
            errorMessage = error.friendlyDiagnosis
        }
        loading = false
    }

    func perform(_ action: ContainerAction) {
        Task {
            await viewModel.containers.perform(action, on: container)
        }
    }

    var messageBinding: Binding<Bool> {
        Binding(
            get: { viewModel.actionMessage != nil },
            set: { if !$0 { viewModel.actionMessage = nil } }
        )
    }
}
