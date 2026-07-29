import ConnOps
import ConnUI
import SwiftUI

/// 卷详情：inspect 信息 + 哪些容器在引用它。
struct VolumeDetailView: View {
    let volume: VolumeInfo
    let model: DockerVolumesModel
    /// 磁盘占用查不到时显示「—」——这条信息由 `docker system df -v` 单独异步取，
    /// 它失败不该让本页看起来坏了。
    let size: String?
    /// 点容器行时的跳转回调，由 `DockerView` 注入路由。
    let onOpenContainer: (ContainerInfo) -> Void

    @State private var detail: VolumeDetail?
    @State private var users: [ContainerInfo] = []
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
        .task { await load() }
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
                DockerDetail.unusedNotice(L("没有容器引用此卷"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(users.enumerated()), id: \.offset) { index, container in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: container.name, subtitle: container.image
                        ) { onOpenContainer(container) }
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
        async let detailTask = model.detail(for: volume)
        async let usersTask = model.containersUsing(volume)
        detail = await detailTask
        users = await usersTask
        loading = false
    }
}
