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
        case processes = "进程"
        case files = "文件"
        case docker = "Docker"
        case logs = "日志"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                segmentPicker
                content
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.top, ConnSpacing.xs)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { terminalToolbarItem }
        .onAppear { monitorVM.appear() }
        .onDisappear { monitorVM.disappear() }
        // 结束进程的二次确认与结果提示集中在此——无论触发自进程列表的长按操作栏，
        // 还是进程详情页的按钮（详情为本页推入的子层），都由这一处对话框呈现。
        .confirmationDialog(killPrompt, isPresented: killDialogBinding, titleVisibility: .visible) {
            Button(L("结束进程"), role: .destructive) { Task { await monitorVM.confirmKill() } }
            Button(L("取消"), role: .cancel) { monitorVM.killTarget = nil }
        }
        .alert(L("进程操作"), isPresented: actionMessageBinding) {
            Button(L("好"), role: .cancel) { monitorVM.actionMessage = nil }
        } message: {
            Text(monitorVM.actionMessage ?? "")
        }
    }

    private var killPrompt: String {
        guard let target = monitorVM.killTarget else { return "" }
        return String(format: L("结束 %@（PID %d）？将发送 SIGTERM。"), target.command, target.pid)
    }

    private var killDialogBinding: Binding<Bool> {
        Binding(get: { monitorVM.killTarget != nil }, set: { if !$0 { monitorVM.killTarget = nil } })
    }

    private var actionMessageBinding: Binding<Bool> {
        Binding(get: { monitorVM.actionMessage != nil }, set: { if !$0 { monitorVM.actionMessage = nil } })
    }

    /// 终端入口：导航栏右上角图标，直接推入终端会话（无中间落地页）。
    @ToolbarContentBuilder
    private var terminalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                TerminalScreen(host: host, dependencies: dependencies)
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
        case .files: FileBrowserView(host: host, dependencies: dependencies)
        case .docker: DockerView(host: host, dependencies: dependencies)
        case .logs: LogCenterView(host: host, dependencies: dependencies)
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
