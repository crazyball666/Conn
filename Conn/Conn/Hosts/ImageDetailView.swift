import ConnOps
import ConnUI
import SwiftUI

/// 镜像详情：inspect 信息 + 层历史 + 哪些容器在用它。
struct ImageDetailView: View {
    let image: ImageInfo
    let model: DockerImagesModel
    /// 引用该镜像的容器。由调用方用容器列表算好传入——判定是纯函数，
    /// 不该让视图自己去取数。
    let users: [ContainerInfo]
    /// 来自 `docker system df -v`，查不到为 nil，显示时回退到 `ImageInfo.size`。
    let diskSize: String?
    let onOpenContainer: (ContainerInfo) -> Void

    @State private var detail: ImageDetail?
    @State private var layers: [ImageLayer] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
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
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(image.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
                (L("标签"), detail.map { $0.tags.isEmpty ? "—" : $0.tags.joined(separator: ", ") } ?? image.displayName),
                (L("镜像 ID"), detail?.id ?? image.imageID),
                (L("大小"), diskSize ?? image.size),
                (L("架构"), [detail?.os, detail?.architecture].compactMap { $0 }.joined(separator: "/")),
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
                        ) { onOpenContainer(container) }
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
        async let detailTask = model.detail(for: image)
        async let layersTask = model.history(for: image)
        detail = await detailTask
        layers = await layersTask
        loading = false
    }
}
