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
    // 文件 / Docker / 日志 的 VM 提到详情级持有——切换分段时不重建，故不重新加载（改下拉刷新 / 重试）。
    @State private var fileVM: FileBrowserViewModel
    @State private var dockerVM: DockerViewModel
    @State private var logVM: LogCenterViewModel
    /// 导航栏终端入口的呈现态——终端走 `.fullScreenCover`，不再是 push。
    @State private var showTerminal = false

    init(host: Host, dependencies: AppDependencies, initialSegment: Segment = .overview) {
        self.host = host
        self.dependencies = dependencies
        _segment = State(initialValue: initialSegment)
        _monitorVM = State(initialValue: HostOverviewViewModel(host: host, dependencies: dependencies))
        _fileVM = State(initialValue: FileBrowserViewModel(host: host, dependencies: dependencies))
        _dockerVM = State(initialValue: DockerViewModel(host: host, dependencies: dependencies))
        _logVM = State(initialValue: LogCenterViewModel(host: host, dependencies: dependencies))
    }

    enum Segment: String, CaseIterable, Identifiable {
        case overview = "概览"
        case processes = "进程"
        case files = "文件"
        case docker = "Docker"
        case logs = "日志"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            segmentPicker
            content
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { terminalToolbarItem }
        .onAppear { monitorVM.appear() }
        .onDisappear { monitorVM.disappear() }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalScreen(host: host, dependencies: dependencies)
        }
    }

    /// 终端入口：导航栏右上角图标，弹出终端会话（无中间落地页）。
    @ToolbarContentBuilder
    private var terminalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showTerminal = true
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .semibold))
            }
            .accessibilityLabel(L("打开终端"))
        }
    }

    /// 导航栏标题：备注优先，否则主机名。
    private var displayTitle: String {
        if let note = host.note, !note.trimmingCharacters(in: .whitespaces).isEmpty { return note }
        return host.name
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
        case .processes: ProcessListView(viewModel: monitorVM)
        case .files: FileBrowserView(host: host, dependencies: dependencies, viewModel: fileVM)
        case .docker: DockerView(host: host, dependencies: dependencies, viewModel: dockerVM)
        case .logs: LogCenterView(host: host, dependencies: dependencies, viewModel: logVM)
        }
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
