import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import Observation
import SwiftUI

/// Git 工作区 ViewModel
@Observable
@MainActor
final class GitWorkspaceViewModel {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var status: GitRepoStatus?
    private(set) var branches: [GitBranch] = []
    private(set) var isBusy = false
    var actionMessage: String?
    var commitMessage = ""

    let host: Host
    let repoRoot: String
    private let connectionManager: ConnectionManager
    let gitService: GitService

    init(host: Host, repoRoot: String, dependencies: AppDependencies) {
        self.host = host
        self.repoRoot = repoRoot
        self.connectionManager = dependencies.connectionManager
        // 惰性构建 gitService，每次从 connectionManager 获取可用 session
        let sessionProvider = GitSessionProxy(host: host, connectionManager: connectionManager)
        self.gitService = GitService(session: sessionProvider)
    }

    func load() async {
        loadState = .loading
        do {
            async let s = gitService.status(at: repoRoot)
            async let b = gitService.branches(at: repoRoot)
            let (repoStatus, repoBranches) = try await (s, b)
            self.status = repoStatus
            self.branches = repoBranches
            self.loadState = .ready
        } catch {
            self.loadState = .failed(error.friendlyDiagnosis)
        }
    }

    func refresh() async {
        do {
            async let s = gitService.status(at: repoRoot)
            async let b = gitService.branches(at: repoRoot)
            let (repoStatus, repoBranches) = try await (s, b)
            self.status = repoStatus
            self.branches = repoBranches
        } catch {
            actionMessage = String(format: L("刷新失败：%@"), error.friendlyDiagnosis)
        }
    }

    func checkout(branch: GitBranch) async {
        guard !branch.isCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await gitService.checkout(branch: branch.name, at: repoRoot)
            await refresh()
            actionMessage = String(format: L("已切换至分支 %@"), branch.name)
        } catch {
            actionMessage = String(format: L("切换分支失败：%@"), error.friendlyDiagnosis)
        }
    }

    func stage(file: GitFileChange) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await gitService.stage(files: [file.path], at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("暂存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func unstage(file: GitFileChange) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await gitService.unstage(files: [file.path], at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("取消暂存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func discard(file: GitFileChange) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await gitService.discard(file: file, at: repoRoot)
            await refresh()
            actionMessage = String(format: L("已放弃对 %@ 的更改"), file.path)
        } catch {
            actionMessage = String(format: L("放弃更改失败：%@"), error.friendlyDiagnosis)
        }
    }

    func commit() async {
        let clean = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await gitService.commit(message: clean, at: repoRoot)
            commitMessage = ""
            await refresh()
            actionMessage = L("提交成功")
        } catch {
            actionMessage = String(format: L("提交失败：%@"), error.friendlyDiagnosis)
        }
    }
}

/// 代理当前 SSHSession，保证自动复用或重新获取连接
private final class GitSessionProxy: SSHSession, @unchecked Sendable {
    let host: Host
    let connectionManager: ConnectionManager

    init(host: Host, connectionManager: ConnectionManager) {
        self.host = host
        self.connectionManager = connectionManager
    }

    var isConnected: Bool { true }

    func exec(_ command: String, timeout: Duration) async throws -> SSHCommandResult {
        let session = try await connectionManager.session(for: host)
        return try await session.exec(command, timeout: timeout)
    }

    func sftp() async throws -> any RemoteFileSystem {
        let session = try await connectionManager.session(for: host)
        return try await session.sftp()
    }

    func openShellChannel(environment: [String: String], terminalType: String) async throws -> any ShellChannel {
        let session = try await connectionManager.session(for: host)
        return try await session.openShellChannel(environment: environment, terminalType: terminalType)
    }

    func close() async {}
}

/// Git 移动端工作区主 Sheet
struct GitWorkspaceSheet: View {
    @State private var viewModel: GitWorkspaceViewModel
    @State private var inspectingDiffFile: GitFileChange?
    @State private var pendingDiscardFile: GitFileChange?
    @Environment(\.dismiss) private var dismiss

    init(host: Host, repoRoot: String, dependencies: AppDependencies) {
        _viewModel = State(initialValue: GitWorkspaceViewModel(
            host: host,
            repoRoot: repoRoot,
            dependencies: dependencies
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.loadState {
                case .loading:
                    ProgressView(L("读取 Git 仓库…"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(msg):
                    ConnRetryState(msg, retryTitle: L("重试")) {
                        Task { await viewModel.load() }
                    }
                case .ready:
                    content
                }
            }
            .navigationTitle(L("Git 工作区"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    branchPickerMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
            .task { await viewModel.load() }
            .sheet(item: $inspectingDiffFile) { file in
                GitDiffSheetView(
                    host: viewModel.host,
                    repoRoot: viewModel.repoRoot,
                    file: file,
                    gitService: viewModel.gitService
                )
            }
            .alert(L("放弃修改"), isPresented: discardAlertBinding, presenting: pendingDiscardFile) { file in
                Button(L("确认放弃"), role: .destructive) {
                    Task { await viewModel.discard(file: file) }
                }
                Button(L("取消"), role: .cancel) { pendingDiscardFile = nil }
            } message: { file in
                Text(String(format: L("将丢弃对 %@ 的未提交修改，此操作不可撤销。"), file.path))
            }
            .alert(L("提示"), isPresented: messageBinding) {
                Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
            } message: {
                Text(viewModel.actionMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(spacing: ConnSpacing.md) {
                    if let status = viewModel.status, status.isClean {
                        VStack(spacing: ConnSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.connGood)
                            Text(L("工作区干净，无任何未提交修改"))
                                .font(.connSubheadline)
                                .foregroundStyle(.connMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ConnSpacing.xxl)
                    } else if let status = viewModel.status {
                        changesList(status: status)
                    }
                }
                .padding(.horizontal, ConnSpacing.page)
                .padding(.vertical, ConnSpacing.sm)
            }

            if let status = viewModel.status, !status.isClean {
                commitBar
            }
        }
        .background(Color.connBg)
    }

    private var headerBar: some View {
        HStack {
            if let status = viewModel.status {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .semibold))
                    Text(status.branch)
                        .font(.system(size: 13, weight: .bold))
                    if status.aheadCount > 0 || status.behindCount > 0 {
                        Text("↑\(status.aheadCount) ↓\(status.behindCount)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.connDim)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.connLine.opacity(0.4), in: Capsule())

                Spacer()

                Text(String(format: L("%d 个文件变更"), status.changes.count))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundStyle(.connAccent)
                }
                .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.vertical, ConnSpacing.xs)
    }

    private var branchPickerMenu: some View {
        Menu {
            ForEach(viewModel.branches) { b in
                Button {
                    Task { await viewModel.checkout(branch: b) }
                } label: {
                    HStack {
                        Text(b.name)
                        if b.isCurrent {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(viewModel.status?.branch ?? L("分支"))
                    .lineLimit(1)
            }
            .font(.connFootnote)
            .foregroundStyle(.connAccent)
        }
    }

    @ViewBuilder
    private func changesList(status: GitRepoStatus) -> some View {
        let staged = status.stagedChanges
        let unstaged = status.changes.filter { !$0.isStaged }

        if !staged.isEmpty {
            sectionHeader(title: L("已暂存变更"), count: staged.count)
            fileGroupCard(staged)
        }

        if !unstaged.isEmpty {
            sectionHeader(title: L("工作区变更"), count: unstaged.count)
            fileGroupCard(unstaged)
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.connDim)
        }
        .padding(.top, ConnSpacing.xs)
    }

    private func fileGroupCard(_ files: [GitFileChange]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                if index > 0 {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                        .padding(.leading, 44)
                }
                fileRow(file)
            }
        }
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func fileRow(_ file: GitFileChange) -> some View {
        Button {
            inspectingDiffFile = file
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                // 状态标志 Badge
                statusBadge(file.primaryStatus)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                    if let old = file.oldPath {
                        Text(String(format: L("原路径：%@"), old))
                            .font(.connData(.caption2))
                            .foregroundStyle(.connDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: ConnSpacing.xs)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.connDim)
            }
            .padding(.horizontal, ConnSpacing.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if file.isStaged {
                Button {
                    Task { await viewModel.unstage(file: file) }
                } label: {
                    Label(L("取消暂存"), systemImage: "minus.circle")
                }
            } else {
                Button {
                    Task { await viewModel.stage(file: file) }
                } label: {
                    Label(L("暂存修改"), systemImage: "plus.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                pendingDiscardFile = file
            } label: {
                Label(L("放弃修改"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if file.isStaged {
                Button {
                    Task { await viewModel.unstage(file: file) }
                } label: {
                    Label(L("取消暂存"), systemImage: "minus")
                }
                .tint(.connMuted)
            } else {
                Button {
                    Task { await viewModel.stage(file: file) }
                } label: {
                    Label(L("暂存"), systemImage: "plus")
                }
                .tint(.connGood)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDiscardFile = file
            } label: {
                Label(L("放弃"), systemImage: "arrow.uturn.backward")
            }
            .tint(.connDanger)
        }
    }

    private func statusBadge(_ status: GitFileStatus) -> some View {
        Text(status.displayLabel)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(badgeColor(status))
            .frame(width: 22, height: 22)
            .background(badgeColor(status).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func badgeColor(_ status: GitFileStatus) -> Color {
        switch status {
        case .modified: return .connWarning
        case .added, .untracked: return .connGood
        case .deleted: return .connDanger
        case .renamed, .copied: return .connInfo
        case .ignored, .unmerged: return .connDim
        }
    }

    private var commitBar: some View {
        VStack(spacing: ConnSpacing.xs) {
            Divider()
            HStack(spacing: ConnSpacing.sm) {
                TextField(L("提交信息…"), text: $viewModel.commitMessage)
                    .textFieldStyle(.plain)
                    .font(.connSubheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.connLine.opacity(0.3), in: RoundedRectangle(cornerRadius: ConnRadius.control))

                Button {
                    Task { await viewModel.commit() }
                } label: {
                    if viewModel.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("提交"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.connAccent, in: RoundedRectangle(cornerRadius: ConnRadius.control))
                    }
                }
                .disabled(viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isBusy)
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.xs)
        }
        .background(Color.connSurface)
    }

    private var discardAlertBinding: Binding<Bool> {
        Binding(get: { pendingDiscardFile != nil }, set: { if !$0 { pendingDiscardFile = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
