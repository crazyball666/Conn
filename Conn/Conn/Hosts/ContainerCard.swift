import ConnOps
import ConnUI
import SwiftUI

/// 容器卡（Docker 容器列表用）。头部：名称 / 镜像 / 状态各占一行。
/// 活动容器显示指标区：CPU、内存、网络、IO 四个等宽单元；已停止容器只显示头部，
/// 不渲染无意义的占位指标。整卡点击进详情。
struct ContainerCard: View {
    let container: ContainerInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                header
                if container.isActive {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                    metrics
                }
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card)
        }
        .buttonStyle(ConnPressStyle())
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: ConnSpacing.sm) {
            ConnStatusDot(healthStatus).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(container.name)
                    .font(.connSubheadline).fontWeight(.semibold).foregroundStyle(.connInk)
                    .lineLimit(1).truncationMode(.middle)
                Text(container.image)
                    .font(.connData(.caption2)).foregroundStyle(.connMuted)
                    .lineLimit(1).truncationMode(.middle)
                Text(container.status)
                    .font(.connData(.caption2)).foregroundStyle(.connDim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 指标区

    private var metrics: some View {
        HStack(alignment: .top, spacing: ConnSpacing.md) {
            percentCell(L("CPU"), value: container.cpuPercent)
            percentCell(L("内存"), value: container.memPercent)
            flowCell(L("网络"), container.netIO)
            flowCell("IO", container.blockIO)
        }
    }

    /// CPU / 内存：标签 + 大百分比 + 细进度条。
    ///
    /// 条的颜色走负载色标（低=绿、高=红），与主机卡的环、详情页的每核条统一。
    private func percentCell(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            Text(value.map { "\(Int($0))%" } ?? "—")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .connTabularNumbers().foregroundStyle(.connInk)
            ConnLoadBar(percent: value, minWidth: 3)
                .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 网络 / IO：标签 + ↓收 + ↑发（docker stats 的两段累计）。
    private func flowCell(_ label: String, _ value: String?) -> some View {
        let parts = split(value)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            flowRow("arrow.down", parts.0)
            flowRow("arrow.up", parts.1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flowRow(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.connMuted)
            Text(value).font(.connData(.footnote)).connTabularNumbers().foregroundStyle(.connInk)
        }
        .lineLimit(1).minimumScaleFactor(0.65)
    }

    // MARK: - 辅助

    private func split(_ text: String?) -> (String, String) {
        guard let text else { return ("—", "—") }
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first ?? "—", parts.count > 1 ? parts[1] : "—")
    }

    private var healthStatus: ConnHealthStatus {
        switch container.state {
        case .running: .ok
        case .paused, .restarting: .warn
        case .dead: .crit
        case .exited, .created, .removing, .unknown: .unknown
        }
    }
}
