import ConnOps
import ConnUI
import SwiftUI

/// 网络详情：inspect 信息 + 接入的容器。
///
/// 接入容器由 `docker network inspect` 直接给出，**不需要额外命令**——
/// 这是三类资源里唯一免费的反向关联。
struct NetworkDetailView: View {
    let network: NetworkInfo
    let model: DockerNetworksModel
    let onOpenContainer: (String) -> Void

    @State private var detail: NetworkDetail?
    @State private var loading = true

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
        .task {
            detail = await model.detail(for: network)
            loading = false
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

    @ViewBuilder
    private var attachedSection: some View {
        DockerDetail.section(L("接入容器")) {
            let containers = detail?.attachedContainers ?? []
            if containers.isEmpty {
                DockerDetail.unusedNotice(L("没有容器接入此网络"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.offset) { index, attached in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: attached.name, subtitle: attached.ipv4
                        ) { onOpenContainer(attached.id) }
                    }
                }
            }
        }
    }
}
