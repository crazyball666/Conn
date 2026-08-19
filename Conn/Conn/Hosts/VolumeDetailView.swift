import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

/// 卷详情：inspect 信息 + 哪些容器在引用它。
///
/// **导航栈说明**：点「引用容器」要推入 `ContainerDetailView`，本页自己持有
/// `openedContainer` + 自己的 `navigationDestination(item:)`——而不是回调给
/// `DockerView` 去改它那个更外层的 `route`。同一个 `route` 状态被两级导航复用时，
/// `navigationDestination(item:)` 不会正确压栈（实测：改值会连累整条链重建，
/// 返回键甚至不显示上一屏标题），每层各管自己的下一跳才是唯一稳的写法，
/// 与 `ContainerDetailView` 自己的日志/控制台跳转同一套路数。
struct VolumeDetailView: View {
    let volume: VolumeInfo
    let viewModel: DockerViewModel
    /// 磁盘占用查不到时显示「—」——这条信息由 `docker system df -v` 单独异步取，
    /// 它失败不该让本页看起来坏了。
    let size: String?
    let host: Host
    let dependencies: AppDependencies

    @State private var detail: VolumeDetail?
    @State private var users: [ContainerInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var usersLoaded = false
    @State private var openedContainer: ContainerInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                DockerDetail.operationActivity(
                    viewModel.operations.activeOperationDescription
                )
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
                    if let errorMessage {
                        DockerDetail.errorRecovery(errorMessage) {
                            Task { await load() }
                        }
                    }
                    if detail != nil {
                        summary
                    }
                    if usersLoaded {
                        usersSection
                    }
                    if let detail, !detail.labels.isEmpty {
                        DockerDetail.section(L("标签")) { keyValues(detail.labels) }
                    }
                    if let detail, !detail.options.isEmpty {
                        DockerDetail.section(L("选项")) { keyValues(detail.options) }
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(volume.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.volumes.canRemove(volume) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { viewModel.volumes.requestRemoval(volume) } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                    .disabled(!viewModel.canWrite)
                }
            }
        }
        .task { await load() }
        .navigationDestination(item: $openedContainer) { container in
            ContainerDetailView(host: host, dependencies: dependencies, container: container, viewModel: viewModel)
        }
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
                (L("驱动"), volume.driver),
                (L("作用域"), volume.scope),
                (L("大小"), size ?? "—"),
                (L("创建"), detail?.createdAt ?? "—"),
                (L("挂载点"), detail?.mountpoint ?? volume.mountpoint)
            ])
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        DockerDetail.section(L("引用容器")) {
            if users.isEmpty {
                DockerDetail.unusedNotice(L("暂无容器引用此卷"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(users.enumerated()), id: \.offset) { index, container in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: container.name, subtitle: container.image
                        ) { openedContainer = container }
                    }
                }
            }
        }
    }

    private func keyValues(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).font(.connData(.caption2)).foregroundStyle(.connInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        // 两条并行：详情与引用查询互不依赖
        loading = detail == nil && !usersLoaded
        do {
            async let detailTask = viewModel.volumes.detail(for: volume)
            async let usersTask = viewModel.volumes.containersUsing(volume)
            let result = try await (detailTask, usersTask)
            detail = result.0
            users = result.1
            usersLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.friendlyDiagnosis
        }
        loading = false
    }
}

// 演示依赖走真实的 DemoOps/MockSSHTransport——`load()` 会实际"跑"一遍
// `docker volume inspect` / `docker ps -a --filter volume=` 拿到 Task 4 里新增的
// 演示夹具（pgdata + 引用它的 pg-main），不是摆设。simctl 点不进详情页，
// 这份 Preview 是本页唯一能在开发期肉眼确认渲染效果的地方。
#if DEBUG
#Preview {
    let host = Host(name: "web-01", address: "10.20.0.11", username: "root")
    NavigationStack {
        VolumeDetailView(
            volume: VolumeInfo(
                name: "pgdata", driver: "local", scope: "local",
                mountpoint: "/var/lib/docker/volumes/pgdata/_data"
            ),
            viewModel: DockerViewModel(host: host, dependencies: .demo()),
            size: "1.2GB", host: host, dependencies: .demo()
        )
    }
}
#endif
