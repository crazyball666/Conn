import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

/// 镜像详情：inspect 信息 + 层历史 + 哪些容器在用它。
///
/// 导航栈说明同 `VolumeDetailView`：本页自己持有 `openedContainer` 与自己的
/// `navigationDestination(item:)`，不回调给 `DockerView` 改它的 `route`——
/// 两级导航复用同一个状态时 `navigationDestination(item:)` 不会正确压栈（已实测）。
struct ImageDetailView: View {
    let image: ImageInfo
    let viewModel: DockerViewModel
    /// 引用该镜像的容器。由调用方用容器列表算好传入——判定是纯函数，
    /// 不该让视图自己去取数。
    let users: [ContainerInfo]
    /// 来自 `docker system df -v`，查不到为 nil，显示时回退到 `ImageInfo.size`。
    let diskSize: String?
    let host: Host
    let dependencies: AppDependencies

    @State private var detail: ImageDetail?
    @State private var layers: [ImageLayer] = []
    @State private var loading = true
    @State private var errorMessage: String?
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
                        usersSection
                        layersSection
                        if let detail {
                            commandSection(detail)
                            listSection(L("环境变量"), detail.env)
                            listSection(L("标签"), detail.labels)
                        }
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(image.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { viewModel.images.requestRemoval(image) } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                .disabled(!viewModel.canWrite)
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
                (L("标签"), detail.map { $0.tags.isEmpty ? "—" : $0.tags.joined(separator: ", ") } ?? image.displayName),
                (L("镜像 ID"), detail?.id ?? image.imageID),
                (L("大小"), diskSize ?? image.size),
                // `detail == nil` 时（详情还没读回来，或 inspect 失败）两个字段都是 nil，
                // `joined` 会给空串——同一行其它字段都有 `?? image.xxx` 兜底，这行也补一个。
                (L("架构"), {
                    let parts = [detail?.os, detail?.architecture].compactMap { $0 }
                    return parts.isEmpty ? "—" : parts.joined(separator: "/")
                }()),
                (L("创建于"), detail?.created ?? image.created),
                (L("摘要"), detail?.digest ?? "—")
            ])
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        DockerDetail.section(L("引用容器")) {
            if users.isEmpty {
                DockerDetail.unusedNotice(L("没有容器使用此镜像"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(users.enumerated()), id: \.offset) { index, container in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: container.name, subtitle: container.status
                        ) { openedContainer = container }
                    }
                }
            }
        }
    }

    /// 层历史。指令可能很长，限 3 行——手机上完整指令没法读，
    /// 真要看全的用 textSelection 复制出去。
    @ViewBuilder
    private var layersSection: some View {
        if !layers.isEmpty {
            DockerDetail.section(L("层历史")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { index, layer in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(layer.size).font(.connData(.caption2))
                                    .connTabularNumbers().foregroundStyle(.connInk)
                                Spacer()
                                Text(layer.createdSince).font(.connData(.caption2))
                                    .foregroundStyle(.connMuted)
                            }
                            Text(layer.createdBy).font(.connData(.caption2))
                                .foregroundStyle(.connMuted).lineLimit(3)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, ConnSpacing.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commandSection(_ detail: ImageDetail) -> some View {
        if detail.entrypoint != nil || detail.command != nil {
            DockerDetail.section(L("入口与命令")) {
                DockerDetail.infoRows([
                    (L("入口"), detail.entrypoint ?? "—"),
                    (L("命令"), detail.command ?? "—")
                ])
            }
        }
    }

    @ViewBuilder
    private func listSection(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            DockerDetail.section(title) {
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item).font(.connData(.caption2)).foregroundStyle(.connInk)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func load() async {
        // 两条并行：详情与层历史互不依赖
        loading = detail == nil
        do {
            async let detailTask = viewModel.images.detail(for: image)
            async let layersTask = viewModel.images.history(for: image)
            let result = try await (detailTask, layersTask)
            detail = result.0
            layers = result.1
            errorMessage = nil
        } catch {
            errorMessage = error.friendlyDiagnosis
        }
        loading = false
    }
}

// 走真实的 DemoOps 演示夹具（nginx:1.25，Task 4 新增的多层历史）。simctl 点不进
// 详情页，这份 Preview 是本页唯一能在开发期肉眼确认渲染效果的地方。
// `users` 由调用方算好传入（纯函数，不是本页自己取数），这里直接给一个夹具容器。
#if DEBUG
#Preview {
    let host = Host(name: "web-01", address: "10.20.0.11", username: "root")
    NavigationStack {
        ImageDetailView(
            image: ImageInfo(
                imageID: "a1b2c3d4e5f6",
                repository: "nginx",
                tag: "1.25",
                size: "142MB",
                created: "9 days ago"
            ),
            viewModel: DockerViewModel(host: host, dependencies: .demo()),
            users: [
                ContainerInfo(
                    id: "a1b2c3d4e5f6", name: "web-nginx", image: "nginx:1.25",
                    state: .running, status: "Up 9 days", ports: "0.0.0.0:80->80/tcp"
                )
            ],
            diskSize: "142MB", host: host, dependencies: .demo()
        )
    }
}
#endif
