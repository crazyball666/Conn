import ConnKit
import ConnOps
import ConnUI
import SwiftUI

/// 网络详情：inspect 信息 + 接入的容器。
///
/// 接入容器由 `docker network inspect` 直接给出，**不需要额外命令**——
/// 这是三类资源里唯一免费的反向关联。
///
/// 导航栈说明同 `VolumeDetailView`：本页自己持有 `openedContainer` 与自己的
/// `navigationDestination(item:)`，不回调给 `DockerView` 改它的 `route`——
/// 两级导航复用同一个状态时 `navigationDestination(item:)` 不会正确压栈（已实测）。
struct NetworkDetailView: View {
    let network: NetworkInfo
    let viewModel: DockerViewModel
    let host: Host
    let dependencies: AppDependencies

    @State private var detail: NetworkDetail?
    @State private var loading = true
    @State private var openedContainer: ContainerInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                if network.isPredefined {
                    HStack(spacing: ConnSpacing.xs) {
                        StatusPill(L("预置"), semantic: .info)
                        Text(L("Docker 预置，不可删除")).font(.connFootnote).foregroundStyle(.connMuted)
                    }
                }
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
                    summary
                    attachedSection
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(network.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.networks.canRemove(network) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { viewModel.networks.requestRemoval(network) } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                    .disabled(!viewModel.canWrite)
                }
            }
        }
        .task {
            let loadedDetail = await viewModel.networks.detail(for: network)
            detail = loadedDetail
            loading = false
            #if DEBUG
                if ProcessInfo.processInfo.environment["CONN_SMOKE_NETWORK_CONTAINER_ROUTE"] != nil,
                   let attached = loadedDetail?.attachedContainers.first {
                    open(attached)
                }
            #endif
        }
        .navigationDestination(item: $openedContainer) { container in
            ContainerDetailView(host: host, dependencies: dependencies, container: container, viewModel: viewModel)
        }
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
                (L("网络 ID"), String(network.id.prefix(12))),
                (L("驱动"), network.driver),
                (L("作用域"), network.scope),
                (L("子网"), detail?.subnet ?? "—"),
                (L("网关"), detail?.gateway ?? "—"),
                (L("内部网络"), (detail?.isInternal ?? false) ? L("是") : L("否"))
            ])
        }
    }

    private func open(_ attached: NetworkDetail.AttachedContainer) {
        if let container = viewModel.containers.items.first(where: {
            attached.matches(containerID: $0.id)
        }) {
            openedContainer = container
        }
    }

    @ViewBuilder
    private var attachedSection: some View {
        DockerDetail.section(L("接入容器")) {
            let containers = detail?.attachedContainers ?? []
            if containers.isEmpty {
                // 预置网络（bridge/host/none）不打「未使用」胶囊——本页顶部已经显示
                // 「预置，不可删除」，两个胶囊同屏出现会自相矛盾（详见 unusedNotice 注释）。
                DockerDetail.unusedNotice(L("没有容器接入此网络"), showsUnusedBadge: !network.isPredefined)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.offset) { index, attached in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: attached.name, subtitle: attached.ipv4
                        ) {
                            // network inspect 与 docker ps 输出的容器 ID 长度不同：前者通常为
                            // 完整 ID，后者通常为 12 位短 ID；按公共前缀回查。
                            open(attached)
                        }
                    }
                }
            }
        }
    }
}

// 走真实的 DemoOps 演示夹具（`isolated` 网络，Task 4 新增）。simctl 点不进详情页，
// 这份 Preview 是本页唯一能在开发期肉眼确认渲染效果的地方。
#if DEBUG
#Preview {
    let host = Host(name: "web-01", address: "10.20.0.11", username: "root")
    NavigationStack {
        NetworkDetailView(
            network: NetworkInfo(id: "f6e5d4c3b2a1", name: "isolated", driver: "bridge", scope: "local"),
            viewModel: DockerViewModel(host: host, dependencies: .demo()),
            host: host, dependencies: .demo()
        )
    }
}
#endif
