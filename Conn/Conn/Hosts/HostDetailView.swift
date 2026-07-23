import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 主机详情（原型 S3）。概览段（Phase 7）实时监控；终端 Phase 4；
/// Docker/日志 Phase 8；文件 Phase 6。
///
/// 监控调度器在详情级持有并在 appear/disappear 起停——这样切到终端/Docker 段时
/// 顶部状态胶囊仍显示实时健康，而不是随段落停摆。
struct HostDetailView: View {
    let host: Host
    let dependencies: AppDependencies
    @State private var segment: Segment
    @State private var monitorVM: HostOverviewViewModel

    init(host: Host, dependencies: AppDependencies, initialSegment: Segment = .overview) {
        self.host = host
        self.dependencies = dependencies
        _segment = State(initialValue: initialSegment)
        _monitorVM = State(initialValue: HostOverviewViewModel(host: host, dependencies: dependencies))
    }

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
        .onAppear { monitorVM.appear() }
        .onDisappear { monitorVM.disappear() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.connTitle).foregroundStyle(.connInk)
                Text(host.displayAddress).font(.connData()).foregroundStyle(.connMuted)
            }
            Spacer()
            StatusPill(resolvedStatus.text, semantic: resolvedStatus.semantic)
        }
    }

    private var segmentPicker: some View {
        Picker(L("段"), selection: $segment) {
            ForEach(Segment.allCases) { seg in
                Text(L(seg.rawValue)).tag(seg)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .overview: HostOverviewView(viewModel: monitorVM)
        case .terminal: terminalSegment
        case .files: FileBrowserView(host: host, dependencies: dependencies)
        case .docker: DockerView(host: host, dependencies: dependencies)
        case .logs: LogCenterView(host: host, dependencies: dependencies)
        }
    }

    private var terminalSegment: some View {
        VStack(spacing: ConnSpacing.sm) {
            NavigationLink {
                TerminalScreen(host: host, dependencies: dependencies)
            } label: {
                Label(L("打开终端会话"), systemImage: "terminal")
                    .font(.connBody)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ConnSpacing.sm)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(colors: [.connAccent, .connAccentDeep], startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: ConnRadius.control, style: .continuous)
                    )
            }
            Text(L("在独立页面打开交互式 shell（PTY）"))
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
        }
        .padding(.vertical, ConnSpacing.md)
    }

    private func placeholder(_ message: String, icon: String) -> some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            Text(message).font(.connSubheadline).foregroundStyle(.connMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ConnSpacing.xxl)
    }

    /// 实时严重度优先；无采集但有错误 → 离线；否则回落持久化状态。
    private var resolvedStatus: (text: String, semantic: StatusPill.Semantic) {
        if let severity = monitorVM.latest?.severity {
            switch severity {
            case .ok: return (L("正常"), .good)
            case .warn: return (L("警告"), .warn)
            case .crit: return (L("故障"), .crit)
            case .unknown: break
            }
        }
        if monitorVM.errorText != nil {
            return (L("离线"), .crit)
        }
        switch host.status {
        case .ok: return (L("正常"), .good)
        case .warn: return (L("警告"), .warn)
        case .crit: return (L("故障"), .crit)
        case .offline: return (L("离线"), .crit)
        case .unknown: return (L("未知"), .off)
        }
    }
}
