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
    private(set) var commits: [GitCommit] = []
    private(set) var isBusy = false
    private(set) var isCommitsLoading = false
    var actionMessage: String?
    var commitMessage = ""

    let host: Host
    let repoRoot: String
    private let connectionManager: ConnectionManager

    init(host: Host, repoRoot: String, dependencies: AppDependencies) {
        self.host = host
        self.repoRoot = repoRoot
        self.connectionManager = dependencies.connectionManager
    }

    private func gitService() async throws -> GitService {
        let session = try await connectionManager.session(for: host)
        return GitService(session: session)
    }

    func load() async {
        loadState = .loading
        do {
            let service = try await gitService()
            async let s = service.status(at: repoRoot)
            async let b = service.branches(at: repoRoot)
            async let c = (try? await service.log(at: repoRoot)) ?? []
            let (repoStatus, repoBranches, repoCommits) = await (try s, try b, c)
            self.status = repoStatus
            self.branches = repoBranches
            self.commits = repoCommits
            self.loadState = .ready
        } catch {
            self.loadState = .failed(error.friendlyDiagnosis)
        }
    }

    func refresh() async {
        do {
            let service = try await gitService()
            async let s = service.status(at: repoRoot)
            async let b = service.branches(at: repoRoot)
            async let c = (try? await service.log(at: repoRoot)) ?? []
            let (repoStatus, repoBranches, repoCommits) = await (try s, try b, c)
            self.status = repoStatus
            self.branches = repoBranches
            self.commits = repoCommits
        } catch {
            actionMessage = String(format: L("刷新失败：%@"), error.friendlyDiagnosis)
        }
    }

    func loadCommits() async {
        guard !isCommitsLoading else { return }
        isCommitsLoading = true
        defer { isCommitsLoading = false }
        do {
            let service = try await gitService()
            self.commits = try await service.log(at: repoRoot)
        } catch {
            actionMessage = String(format: L("获取提交记录失败：%@"), error.friendlyDiagnosis)
        }
    }

    func checkout(branch: GitBranch) async {
        guard !branch.isCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.checkout(branch: branch.name, at: repoRoot)
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
            let service = try await gitService()
            try await service.stage(files: [file.path], at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("暂存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func unstage(file: GitFileChange) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.unstage(files: [file.path], at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("取消暂存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func discard(file: GitFileChange) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.discard(file: file, at: repoRoot)
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
            let service = try await gitService()
            try await service.commit(message: clean, at: repoRoot)
            commitMessage = ""
            await refresh()
            actionMessage = L("提交成功")
        } catch {
            actionMessage = String(format: L("提交失败：%@"), error.friendlyDiagnosis)
        }
    }
}

enum GitWorkspaceTab: String, CaseIterable, Identifiable {
    case changes
    case history

    var id: String { rawValue }
}

/// Git 移动端工作区主 Sheet
struct GitWorkspaceSheet: View {
    @State private var viewModel: GitWorkspaceViewModel
    @State private var selectedTab: GitWorkspaceTab = .changes
    @State private var inspectingDiffFile: GitFileChange?
    @State private var inspectingCommit: GitCommit?
    @State private var pendingDiscardFile: GitFileChange?
    let currentPath: String?
    private let dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connToastCenter) private var toastCenter

    init(host: Host, repoRoot: String, currentPath: String? = nil, dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.currentPath = currentPath
        _viewModel = State(initialValue: GitWorkspaceViewModel(
            host: host,
            repoRoot: repoRoot,
            dependencies: dependencies
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.repoRoot.isEmpty {
                    notAGitRepoView
                } else {
                    switch viewModel.loadState {
                    case .loading:
                        ProgressView(L("读取 Git 仓库…"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case let .failed(msg):
                        if msg.contains("not a git repository") || msg.contains("Not a git repository") {
                            notAGitRepoView
                        } else {
                            ConnRetryState(msg, retryTitle: L("重试")) {
                                Task { await viewModel.load() }
                            }
                        }
                    case .ready:
                        content
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if !viewModel.repoRoot.isEmpty {
                        Picker("", selection: $selectedTab) {
                            Text(L("变更")).tag(GitWorkspaceTab.changes)
                            Text(L("历史")).tag(GitWorkspaceTab.history)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Text(L("Git 工作区"))
                            .font(.connHeadline)
                            .foregroundStyle(.connInk)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
            .task {
                if !viewModel.repoRoot.isEmpty {
                    await viewModel.load()
                }
            }
            .sheet(item: $inspectingDiffFile) { file in
                GitDiffSheetView(
                    host: viewModel.host,
                    repoRoot: viewModel.repoRoot,
                    file: file,
                    dependencies: dependencies
                )
            }
            .sheet(item: $inspectingCommit) { commit in
                GitCommitDetailSheetView(
                    host: viewModel.host,
                    repoRoot: viewModel.repoRoot,
                    commit: commit,
                    dependencies: dependencies
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

    private var notAGitRepoView: some View {
        VStack(spacing: ConnSpacing.lg) {
            Image(systemName: "arrow.triangle.branch.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.connWarn)

            VStack(spacing: ConnSpacing.xs) {
                Text(L("当前目录不是 Git 仓库"))
                    .font(.connHeadline)
                    .foregroundStyle(.connInk)

                Text(L("请在终端中执行 cd <项目目录> 切换至包含 .git 的目录后重试。"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ConnSpacing.page)
            }

            if let path = currentPath, !path.isEmpty {
                VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                    Text(L("当前探测路径"))
                        .font(.connCaption)
                        .foregroundStyle(.connDim)

                    HStack {
                        Text(path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.connInk)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = path
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            toastCenter.show(L("已复制路径"), style: .success)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundStyle(.connAccent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("复制当前路径"))
                    }
                    .padding(ConnSpacing.sm)
                    .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.control)
                            .strokeBorder(Color.connLine, lineWidth: 0.5)
                    )
                }
                .padding(.horizontal, ConnSpacing.page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.connBg)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            headerBar

            switch selectedTab {
            case .changes:
                changesContent
            case .history:
                historyContent
            }
        }
        .background(Color.connBg)
    }

    private var changesContent: some View {
        VStack(spacing: 0) {
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
    }

    private var historyContent: some View {
        ScrollView {
            LazyVStack(spacing: ConnSpacing.sm) {
                if viewModel.commits.isEmpty && viewModel.isCommitsLoading {
                    ProgressView(L("读取提交记录…"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ConnSpacing.xxl)
                } else if viewModel.commits.isEmpty {
                    VStack(spacing: ConnSpacing.sm) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 38))
                            .foregroundStyle(.connMuted)
                        Text(L("暂无提交记录"))
                            .font(.connSubheadline)
                            .foregroundStyle(.connMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ConnSpacing.xxl)
                } else {
                    ForEach(viewModel.commits) { commit in
                        Button {
                            inspectingCommit = commit
                        } label: {
                            commitRow(commit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.sm)
        }
        .task {
            if viewModel.commits.isEmpty {
                await viewModel.loadCommits()
            }
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(commit.shortHash)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.connAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.connAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text(commit.relativeDate)
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
            Text(commit.message)
                .font(.connBody)
                .fontWeight(.medium)
                .foregroundStyle(.connInk)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: "person.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.connDim)
                Text(commit.author)
                    .font(.connFootnote)
                    .foregroundStyle(.connDim)
                Spacer()
                Text(commit.date.prefix(10))
                    .font(.connData(.caption2))
                    .foregroundStyle(.connDim)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.card)
                .strokeBorder(Color.connLine, lineWidth: 0.5)
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = commit.hash
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label(L("复制完整 Commit Hash"), systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = commit.message
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label(L("复制提交信息"), systemImage: "text.quote")
            }
        }
    }

    private var headerBar: some View {
        HStack {
            if let status = viewModel.status {
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
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 12, weight: .semibold))
                        Text(status.branch)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.connDim)
                        if status.aheadCount > 0 || status.behindCount > 0 {
                            Text("↑\(status.aheadCount) ↓\(status.behindCount)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.connDim)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.connLine.opacity(0.4), in: Capsule())
                    .foregroundStyle(.connInk)
                }
                .buttonStyle(.plain)

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
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
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
            .padding(.vertical, 7)
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
            .tint(.connCrit)
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
        case .modified: return .connWarn
        case .added, .untracked: return .connGood
        case .deleted: return .connCrit
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
