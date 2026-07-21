import ConnKit
import ConnUI
import SwiftUI

/// 主机详情（原型 S3）。本 Phase 只做导航框架与概览段；监控数据 Phase 7、
/// 终端 Phase 4、文件 Phase 6、Docker/日志 Phase 8 各自接入。
struct HostDetailView: View {
    let host: Host
    let dependencies: AppDependencies
    @State private var segment: Segment = .overview

    enum Segment: String, CaseIterable, Identifiable {
        case overview = "概览"
        case terminal = "终端"
        case files = "文件"
        case docker = "Docker"
        case logs = "日志"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                header
                segmentPicker
                content
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.top, ConnSpacing.xs)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.connTitle).foregroundStyle(.connInk)
                Text(host.displayAddress).font(.connData()).foregroundStyle(.connMuted)
            }
            Spacer()
            StatusPill(statusText, semantic: statusSemantic)
        }
    }

    private var segmentPicker: some View {
        Picker("段", selection: $segment) {
            ForEach(Segment.allCases) { seg in
                Text(seg.rawValue).tag(seg)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .overview: overview
        case .terminal: terminalSegment
        case .files: placeholder("文件管理将在 Phase 6 实现", icon: "folder")
        case .docker: placeholder("容器管理将在 Phase 8 实现", icon: "shippingbox")
        case .logs: placeholder("日志中心将在 Phase 8 实现", icon: "doc.text")
        }
    }

    private var terminalSegment: some View {
        VStack(spacing: ConnSpacing.sm) {
            NavigationLink {
                TerminalScreen(host: host, dependencies: dependencies)
            } label: {
                Label("打开终端会话", systemImage: "terminal")
                    .font(.connBody)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ConnSpacing.sm)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(colors: [.connAccent, .connAccentDeep], startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: ConnRadius.control, style: .continuous)
                    )
            }
            Text("在独立页面打开交互式 shell（PTY）")
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
        }
        .padding(.vertical, ConnSpacing.md)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            // 指标环占位——真实采样 Phase 7 接入
            HStack(spacing: ConnSpacing.xs) {
                MetricGauge(label: "CPU", value: nil, tint: .connAccent)
                MetricGauge(label: "内存", value: nil, tint: .connInfo)
                MetricGauge(label: "磁盘", value: nil, tint: .connDisk)
            }
            ConnBanner("实时监控数据将在 Phase 7 接入采集脚本后显示", systemImage: "info.circle")

            Text("快捷动作")
                .font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            LazyVGrid(columns: Array(repeating: GridItem(spacing: ConnSpacing.xs), count: 4), spacing: ConnSpacing.xs) {
                ActionTile("终端", systemName: "terminal") { segment = .terminal }
                ActionTile("日志", systemName: "doc.text") { segment = .logs }
                ActionTile("Docker", systemName: "shippingbox") { segment = .docker }
                ActionTile("文件", systemName: "folder") { segment = .files }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    private func placeholder(_ message: String, icon: String) -> some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            Text(message).font(.connSubheadline).foregroundStyle(.connMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ConnSpacing.xxl)
    }

    private var statusSemantic: StatusPill.Semantic {
        switch host.status {
        case .ok: .good
        case .warn: .warn
        case .crit, .offline: .crit
        case .unknown: .off
        }
    }

    private var statusText: String {
        switch host.status {
        case .ok: "正常"
        case .warn: "警告"
        case .crit: "故障"
        case .offline: "离线"
        case .unknown: "未知"
        }
    }
}
