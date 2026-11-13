import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import Observation
import SwiftUI

enum GitSyncAction: Sendable {
    case fetch
    case pull
    case push
}

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
    private(set) var hasLoaded = false
    private(set) var status: GitRepoStatus?
    private(set) var branches: [GitBranch] = []
    private(set) var commits: [GitCommit] = []
    private(set) var remotes: [GitRemote] = []
    private(set) var stashCount = 0
    private(set) var isBusy = false
    private(set) var isSyncing = false
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

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        loadState = .loading
        defer { hasLoaded = true }
        do {
            let service = try await gitService()
            async let s = service.status(at: repoRoot)
            async let b = service.branches(at: repoRoot)
            async let c = (try? await service.log(at: repoRoot)) ?? []
            async let r = (try? await service.remotes(at: repoRoot)) ?? []
            async let st = (try? await service.stashCount(at: repoRoot)) ?? 0
            let (repoStatus, repoBranches, repoCommits, repoRemotes, repoStashes) =
                await (try s, try b, c, r, st)
            self.status = repoStatus
            self.branches = repoBranches
            self.commits = repoCommits
            self.remotes = repoRemotes
            self.stashCount = repoStashes
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
            async let r = (try? await service.remotes(at: repoRoot)) ?? []
            async let st = (try? await service.stashCount(at: repoRoot)) ?? 0
            let (repoStatus, repoBranches, repoCommits, repoRemotes, repoStashes) =
                await (try s, try b, c, r, st)
            self.status = repoStatus
            self.branches = repoBranches
            self.commits = repoCommits
            self.remotes = repoRemotes
            self.stashCount = repoStashes
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

    func sync(_ action: GitSyncAction) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let service = try await gitService()
            switch action {
            case .fetch:
                try await service.fetch(at: repoRoot)
            case .pull:
                try await service.pullFastForwardOnly(at: repoRoot)
            case .push:
                try await service.push(at: repoRoot)
            }
            await refresh()
        } catch {
            actionMessage = String(format: L("同步失败：%@"), error.friendlyDiagnosis)
        }
    }

    func stageAll() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.stageAll(at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("暂存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func unstageAll() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.unstageAll(at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("取消暂存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func createBranch(_ name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.createBranch(name: clean, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func deleteBranch(_ branch: GitBranch) async {
        guard !branch.isCurrent, !branch.isRemote, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.deleteBranch(name: branch.name, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func amendCommit() async {
        let clean = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.amendCommit(message: clean, at: repoRoot)
            commitMessage = ""
            await refresh()
        } catch {
            actionMessage = String(format: L("提交失败：%@"), error.friendlyDiagnosis)
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
    case overview
    case changes
    case history
    case branches

    var id: String { rawValue }
}

/// Git 移动端工作区主 Sheet
struct GitWorkspaceSheet: View {
    @State private var viewModel: GitWorkspaceViewModel
    @State private var selectedTab: GitWorkspaceTab = .overview
    @State private var inspectingDiffFile: GitFileChange?
    @State private var inspectingCommit: GitCommit?
    @State private var pendingDiscardFile: GitFileChange?
    @State private var isNewBranchPresented = false
    @State private var newBranchName = ""
    @State private var pendingDeleteBranch: GitBranch?
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
                        Text(L("概览")).tag(GitWorkspaceTab.overview)
                        Text(L("变更")).tag(GitWorkspaceTab.changes)
                        Text(L("历史")).tag(GitWorkspaceTab.history)
                        Text(L("分支")).tag(GitWorkspaceTab.branches)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text(L("Git 工作区"))
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                }
            }
        }
        .task {
            if !viewModel.repoRoot.isEmpty {
                await viewModel.loadIfNeeded()
            }
        }
        .alert(L("新建分支"), isPresented: $isNewBranchPresented) {
            TextField(L("分支名称"), text: $newBranchName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("创建")) {
                let name = newBranchName
                newBranchName = ""
                Task { await viewModel.createBranch(name) }
            }
            Button(L("取消"), role: .cancel) { newBranchName = "" }
        }
        .alert(
            L("删除分支"),
            isPresented: Binding(
                get: { pendingDeleteBranch != nil },
                set: { if !$0 { pendingDeleteBranch = nil } }
            ),
            presenting: pendingDeleteBranch
        ) { branch in
            Button(L("删除"), role: .destructive) {
                pendingDeleteBranch = nil
                Task { await viewModel.deleteBranch(branch) }
            }
            Button(L("取消"), role: .cancel) { pendingDeleteBranch = nil }
        } message: { branch in
            Text(String(format: L("将删除本地分支 %@。"), branch.name))
        }
        .navigationDestination(item: $inspectingDiffFile) { file in
            GitDiffSheetView(
                host: viewModel.host,
                repoRoot: viewModel.repoRoot,
                file: file,
                dependencies: dependencies
            )
        }
        .navigationDestination(item: $inspectingCommit) { commit in
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
            case .overview:
                overviewContent
            case .changes:
                changesContent
            case .history:
                historyContent
            case .branches:
                branchesContent
            }
        }
        .background(Color.connBg)
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(spacing: ConnSpacing.md) {
                overviewRepoCard
                syncButtons
                statsGrid
                latestCommitCard
                remotesCard
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.sm)
        }
        .background(Color.connBg)
        .refreshable { await viewModel.refresh() }
    }

    private var repoName: String {
        viewModel.repoRoot.split(separator: "/").last.map(String.init) ?? "Git"
    }

    private var overviewRepoCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.connAccent, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(repoName)
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                    Text(viewModel.repoRoot)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if let status = viewModel.status {
                HStack(spacing: ConnSpacing.xs) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(status.branch)
                        .fontWeight(.semibold)
                    if let upstream = status.upstream {
                        Image(systemName: "arrow.right")
                        Text(upstream)
                    }
                }
                .font(.connData(.caption))
                .foregroundStyle(.connInk)

                Label(syncStateLabel, systemImage: syncStateIcon)
                    .font(.connFootnote)
                    .foregroundStyle(syncStateColor)
            }
        }
        .padding(ConnSpacing.md)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var syncButtons: some View {
        HStack(spacing: ConnSpacing.sm) {
            syncButton(.fetch, title: L("获取"), systemImage: "arrow.triangle.2.circlepath", tint: .connInfo)
            syncButton(.pull, title: L("拉取"), systemImage: "arrow.down.circle", tint: .connWarn)
            syncButton(.push, title: L("推送"), systemImage: "arrow.up.circle", tint: .connAccent)
        }
    }

    private func syncButton(
        _ action: GitSyncAction,
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Button {
            Task { await viewModel.sync(action) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                Text(title)
                    .font(.connCaption)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, ConnSpacing.sm)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: ConnRadius.control))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSyncing || viewModel.isBusy)
        .opacity(viewModel.isSyncing || viewModel.isBusy ? 0.55 : 1)
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ConnSpacing.sm) {
            statTile(
                title: L("变更"),
                count: viewModel.status?.changes.count ?? 0,
                systemImage: "pencil",
                tint: .connWarn
            )
            statTile(
                title: L("已暂存"),
                count: viewModel.status?.stagedChanges.count ?? 0,
                systemImage: "tray.and.arrow.down.fill",
                tint: .connGood
            )
            statTile(
                title: L("分支"),
                count: viewModel.branches.filter { !$0.isRemote }.count,
                systemImage: "arrow.triangle.branch",
                tint: .connAccent
            )
            statTile(
                title: "Stashes",
                count: viewModel.stashCount,
                systemImage: "archivebox.fill",
                tint: .connInfo
            )
        }
    }

    private func statTile(title: String, count: Int, systemImage: String, tint: Color) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.connInk)
                Text(title)
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(ConnSpacing.sm)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    @ViewBuilder
    private var latestCommitCard: some View {
        if let commit = viewModel.commits.first {
            Button {
                inspectingCommit = commit
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("最新提交"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.connDim)
                    }
                    Text(commit.message)
                        .font(.connSubheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.connInk)
                        .lineLimit(2)
                    HStack(spacing: ConnSpacing.xs) {
                        Text(commit.author)
                        Text("·")
                        Text(commit.relativeDate)
                        Spacer()
                        Text(commit.shortHash)
                            .font(.connData(.caption2))
                    }
                    .font(.connFootnote)
                    .foregroundStyle(.connDim)
                }
                .padding(ConnSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .connSurface(cornerRadius: ConnRadius.card)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var remotesCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            Text(L("远端"))
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
            if viewModel.remotes.isEmpty {
                Text(L("暂无远端"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            } else {
                ForEach(viewModel.remotes) { remote in
                    HStack(spacing: ConnSpacing.sm) {
                        Image(systemName: "globe")
                            .foregroundStyle(.connAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.name)
                                .font(.connSubheadline)
                                .foregroundStyle(.connInk)
                            Text(remote.url)
                                .font(.connData(.caption2))
                                .foregroundStyle(.connMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(ConnSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var syncStateLabel: String {
        guard let status = viewModel.status else { return L("未知") }
        guard status.upstream != nil else { return L("无上游") }
        if status.aheadCount == 0, status.behindCount == 0 {
            return L("与远端一致")
        }
        if status.aheadCount > 0, status.behindCount > 0 {
            return L("已分叉")
        }
        if status.aheadCount > 0 {
            return String(format: L("领先 %d 个提交"), status.aheadCount)
        }
        return String(format: L("落后 %d 个提交"), status.behindCount)
    }

    private var syncStateIcon: String {
        guard let status = viewModel.status, status.upstream != nil else { return "questionmark.circle" }
        if status.aheadCount == 0, status.behindCount == 0 { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var syncStateColor: Color {
        guard let status = viewModel.status, status.upstream != nil else { return .connMuted }
        return status.aheadCount == 0 && status.behindCount == 0 ? .connGood : .connWarn
    }

    private var branchesContent: some View {
        let localBranches = viewModel.branches.filter { !$0.isRemote }
        let remoteBranches = viewModel.branches.filter(\.isRemote)
        return List {
            Section(L("本地分支")) {
                ForEach(localBranches) { branch in
                    Button {
                        Task { await viewModel.checkout(branch: branch) }
                    } label: {
                        HStack(spacing: ConnSpacing.sm) {
                            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(branch.isCurrent ? .connGood : .connDim)
                            Text(branch.name)
                                .font(.connData(.subheadline))
                                .foregroundStyle(.connInk)
                            Spacer()
                        }
                    }
                    .disabled(branch.isCurrent || viewModel.isBusy)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !branch.isCurrent {
                            Button(role: .destructive) {
                                pendingDeleteBranch = branch
                            } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !remoteBranches.isEmpty {
                Section(L("远程分支")) {
                    ForEach(remoteBranches) { branch in
                        HStack {
                            Image(systemName: "cloud")
                                .foregroundStyle(.connMuted)
                            Text(branch.name)
                                .font(.connData(.subheadline))
                                .foregroundStyle(.connMuted)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Button {
                newBranchName = ""
                isNewBranchPresented = true
            } label: {
                Label(L("新建分支"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isBusy)
            .padding(ConnSpacing.page)
            .background(.bar)
        }
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
                .font(.connSubheadline)
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
                    ForEach(viewModel.branches.filter { !$0.isRemote }) { b in
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

                Menu {
                    Button {
                        Task { await viewModel.stageAll() }
                    } label: {
                        Label(L("全部暂存"), systemImage: "plus.circle")
                    }
                    Button {
                        Task { await viewModel.unstageAll() }
                    } label: {
                        Label(L("全部取消暂存"), systemImage: "minus.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
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

                Menu {
                    Button {
                        Task { await viewModel.amendCommit() }
                    } label: {
                        Label(L("修改最近一次提交"), systemImage: "pencil.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.connAccent)
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
