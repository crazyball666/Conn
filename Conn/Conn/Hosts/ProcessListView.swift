import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 进程段：全量进程 + 可排序表头（CPU / 内存，升降序）+ 长按操作栏（结束进程）
/// + 点击进详情。结束进程的二次确认与结果提示集中在父级 `HostDetailView`。
struct ProcessListView: View {
    let viewModel: HostOverviewViewModel

    enum SortKey { case cpu, mem }
    private enum LoadState {
        case loading
        case failed(String)
        case ready
    }

    @State private var sortKey: SortKey = .cpu
    @State private var ascending = false
    @State private var searchText = ""
    @State private var killTarget: RemoteProcess?
    @State private var resultMessage: String?

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView(L("采集中…"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xxl)
            case let .failed(message):
                VStack(spacing: ConnSpacing.sm) {
                    ConnBanner(message, systemImage: "exclamationmark.triangle")
                    Button(L("重试")) {
                        Task { await viewModel.retryProcesses() }
                    }
                    .font(.connBody).foregroundStyle(.connAccent)
                }
                .padding(.vertical, ConnSpacing.md)
            case .ready:
                processList
            }
        }
        .modifier(KillProcessAlert(viewModel: viewModel, target: $killTarget, result: $resultMessage))
        // 进程段从加载到失败期间仍须保持 `ps` 采集开启；否则首次结果永远不会到达，
        // 失败后的后台轮询也无法自行恢复。
        .onAppear { viewModel.setProcessSegmentActive(true) }
        .onDisappear { viewModel.setProcessSegmentActive(false) }
    }

    private var processList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                searchField
                eyebrow
                if displayedProcesses.isEmpty {
                    emptyState
                } else {
                    columnHeader
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedProcesses.enumerated()), id: \.element.id) { index, process in
                            if index > 0 { rowDivider }
                            row(process)
                        }
                    }
                    .connSurface(cornerRadius: ConnRadius.card)
                }
            }
            .padding(.bottom, ConnSpacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }

    private var loadState: LoadState {
        if let error = viewModel.errorText, viewModel.latest == nil {
            return .failed(error)
        }
        if viewModel.processesLoading || viewModel.latest == nil {
            return .loading
        }
        return .ready
    }

    /// 过滤（名称 / PID / 用户 / 命令行）+ 按当前排序键与方向排序后的进程。
    private var displayedProcesses: [RemoteProcess] {
        let metric: (RemoteProcess) -> Double = sortKey == .cpu ? { $0.cpu } : { $0.mem }
        let sorted = viewModel.processes.sorted { ascending ? metric($0) < metric($1) : metric($0) > metric($1) }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sorted }
        return sorted.filter { process in
            process.command.lowercased().contains(query)
                || String(process.pid).contains(query)
                || (process.user?.lowercased().contains(query) ?? false)
                || (process.fullCommand?.lowercased().contains(query) ?? false)
        }
    }

    // MARK: - 头部

    private var searchField: some View {
        ConnSearchField(L("搜索进程 / PID / 用户"), text: $searchText)
    }

    private var eyebrow: some View {
        HStack {
            Text(L("进程")).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            Spacer()
            Text(String(format: L("共 %d 个"), displayedProcesses.count))
                .font(.connData(.caption2)).foregroundStyle(.connDim)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: ConnSpacing.sm) {
            Text(L("进程")).font(.connData(.caption2)).foregroundStyle(.connMuted)
            Spacer(minLength: ConnSpacing.xs)
            sortButton("CPU", key: .cpu)
            sortButton(L("内存"), key: .mem)
        }
        .padding(.horizontal, ConnSpacing.cardPadding + 2)
    }

    private func sortButton(_ label: String, key: SortKey) -> some View {
        Button {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = false }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                Image(systemName: sortIcon(for: key)).font(.system(size: 8, weight: .bold))
            }
            .font(.connData(.caption2))
            .foregroundStyle(sortKey == key ? Color.connAccent : .connMuted)
            .frame(width: 52, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    private func sortIcon(for key: SortKey) -> String {
        guard sortKey == key else { return "chevron.up.chevron.down" }
        return ascending ? "chevron.up" : "chevron.down"
    }

    // MARK: - 行

    private func row(_ process: RemoteProcess) -> some View {
        NavigationLink {
            ProcessDetailView(process: process, viewModel: viewModel)
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(process.command).font(.connData(.footnote)).foregroundStyle(.connInk).lineLimit(1)
                    Text(metaLine(process)).font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)
                usageCell(process.cpu)
                usageCell(process.mem)
            }
            .padding(.horizontal, ConnSpacing.cardPadding)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                killTarget = process
            } label: {
                Label(L("结束进程"), systemImage: "xmark.octagon")
            }
        }
    }

    /// 副标题：PID · 属主（属主缺失则仅 PID）。
    private func metaLine(_ process: RemoteProcess) -> String {
        var parts = ["PID \(process.pid)"]
        if let user = process.user, !user.isEmpty { parts.append(user) }
        return parts.joined(separator: " · ")
    }

    private func usageCell(_ value: Double) -> some View {
        Text(String(format: "%.0f%%", value))
            .font(.connData(.caption2)).connTabularNumbers()
            .foregroundStyle(value > ConnThreshold.warn ? .connWarn : .connInk)
            .frame(width: 52, alignment: .trailing)
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.leading, ConnSpacing.cardPadding)
    }

    private var emptyState: some View {
        Text(emptyMessage)
            .font(.connFootnote).foregroundStyle(.connMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, ConnSpacing.xl)
    }

    private var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return L("无匹配的进程") }
        return L("暂无进程数据")
    }
}
