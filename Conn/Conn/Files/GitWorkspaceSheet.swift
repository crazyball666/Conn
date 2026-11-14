import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import Observation
import SwiftUI

enum GitSyncAction: Sendable, Equatable {
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
    private(set) var tags: [GitTag] = []
    private(set) var fileStats: [String: GitFileDiffStat] = [:]
    private(set) var stashes: [GitStash] = []
    private(set) var interruptedOperation: GitInterruptedOperation?
    private(set) var stashCount = 0
    private(set) var isBusy = false
    private(set) var isSyncing = false
    private(set) var activeSyncAction: GitSyncAction?
    private(set) var isCommitsLoading = false
    private(set) var commitLimit = 50
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
            async let st = (try? await service.stashes(at: repoRoot)) ?? []
            async let t = (try? await service.tags(at: repoRoot)) ?? []
            async let op = service.interruptedOperation(at: repoRoot)
            async let fs = (try? await service.fileDiffStats(at: repoRoot)) ?? [:]
            let (repoStatus, repoBranches, repoCommits, repoRemotes, repoStashes, repoTags, operation, diffs) =
                await (try s, try b, c, r, st, t, op, fs)
            self.status = repoStatus
            self.branches = repoBranches
            self.commits = repoCommits
            self.remotes = repoRemotes
            self.stashes = repoStashes
            self.stashCount = repoStashes.count
            self.tags = repoTags
            self.fileStats = diffs
            self.interruptedOperation = operation
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
            async let st = (try? await service.stashes(at: repoRoot)) ?? []
            async let t = (try? await service.tags(at: repoRoot)) ?? []
            async let op = service.interruptedOperation(at: repoRoot)
            async let fs = (try? await service.fileDiffStats(at: repoRoot)) ?? [:]
            let (repoStatus, repoBranches, repoCommits, repoRemotes, repoStashes, repoTags, operation, diffs) =
                await (try s, try b, c, r, st, t, op, fs)
            self.status = repoStatus
            self.branches = repoBranches
            self.commits = repoCommits
            self.remotes = repoRemotes
            self.stashes = repoStashes
            self.stashCount = repoStashes.count
            self.tags = repoTags
            self.fileStats = diffs
            self.interruptedOperation = operation
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
            self.commits = try await service.log(at: repoRoot, limit: commitLimit)
        } catch {
            actionMessage = String(format: L("获取提交记录失败：%@"), error.friendlyDiagnosis)
        }
    }

    func loadMoreCommits() async {
        guard !isCommitsLoading else { return }
        isCommitsLoading = true
        defer { isCommitsLoading = false }
        do {
            commitLimit += 50
            let service = try await gitService()
            commits = try await service.log(at: repoRoot, limit: commitLimit)
        } catch {
            actionMessage = String(format: L("获取提交记录失败：%@"), error.friendlyDiagnosis)
        }
    }

    func abortInterruptedOperation() async {
        guard let interruptedOperation, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.abortInterruptedOperation(interruptedOperation, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func commitAndPush() async {
        let clean = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.commitAndPush(message: clean, at: repoRoot)
            commitMessage = ""
            await refresh()
        } catch {
            await refresh()
            actionMessage = String(format: L("提交失败：%@"), error.friendlyDiagnosis)
        }
    }

    func createStash(message: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.createStash(message: message, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func applyStash(_ stash: GitStash) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.applyStash(stash, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func popStash(_ stash: GitStash) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.popStash(stash, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func dropStash(_ stash: GitStash) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.dropStash(stash, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func createTag(name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.createTag(name: clean, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func deleteTag(_ tag: GitTag) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.deleteTag(name: tag.name, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func checkoutTag(_ tag: GitTag) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.checkoutTag(tag, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func sync(_ action: GitSyncAction) async {
        guard !isSyncing else { return }
        isSyncing = true
        activeSyncAction = action
        defer {
            isSyncing = false
            activeSyncAction = nil
        }
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

    func createBranch(_ name: String, from base: GitBranch? = nil) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.createBranch(name: clean, at: repoRoot, from: base?.name)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func deleteRemoteBranch(_ branch: GitBranch) async {
        guard branch.isRemote, !isBusy else { return }
        let parts = branch.name.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            actionMessage = L("无法识别远程分支")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.deleteRemoteBranch(remote: parts[0], branch: parts[1], at: repoRoot)
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

    func renameBranch(_ branch: GitBranch, to newName: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.renameBranch(branch.name, to: newName, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func checkoutRemoteBranch(_ branch: GitBranch) async {
        guard branch.isRemote, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.checkoutTrackingBranch(branch.name, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func merge(_ branch: GitBranch) async {
        guard !branch.isCurrent, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.merge(branch.name, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func rebase(onto branch: GitBranch) async {
        guard !branch.isCurrent, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let service = try await gitService()
            try await service.rebase(onto: branch.name, at: repoRoot)
            await refresh()
        } catch {
            actionMessage = String(format: L("操作失败：%@"), error.friendlyDiagnosis)
        }
    }

    func amendCommit(message: String? = nil) async {
        let clean = (message ?? commitMessage).trimmingCharacters(in: .whitespacesAndNewlines)
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
    @State private var newBranchBase: GitBranch?
    @State private var branchSearch = ""
    @State private var historySearch = ""
    @State private var pendingDeleteBranch: GitBranch?
    @State private var pendingDeleteRemoteBranch: GitBranch?
    @State private var renameBranchTarget: GitBranch?
    @State private var renameBranchName = ""
    @State private var pendingMergeBranch: GitBranch?
    @State private var pendingRebaseBranch: GitBranch?
    @State private var branchHistory: GitBranch?
    @State private var isStashesPresented = false
    @State private var isAmendCommit = false
    @State private var isNewTagPresented = false
    @State private var newTagName = ""
    @State private var pendingDeleteTag: GitTag?
    @State private var isAmendLatestPresented = false
    @State private var amendLatestMessage = ""
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
        gitAlerts(baseContent)
    }

    private var baseContent: some View {
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
        .navigationTitle(repoTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(repoTitle)
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                    if let branch = viewModel.status?.branch, !branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(branch)
                        }
                        .font(.connCaption)
                        .foregroundStyle(.connMuted)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy || viewModel.isSyncing)
                .accessibilityLabel(L("刷新"))
            }
        }
        .task {
            if !viewModel.repoRoot.isEmpty {
                await viewModel.loadIfNeeded()
            }
        }
    }

    private func gitAlerts<Content: View>(_ content: Content) -> some View {
        content
            .alert(L("新建分支"), isPresented: $isNewBranchPresented) {
                TextField(L("分支名称"), text: $newBranchName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L("创建")) {
                    let name = newBranchName
                    let base = newBranchBase
                    newBranchName = ""
                    newBranchBase = nil
                    Task { await viewModel.createBranch(name, from: base) }
                }
                Button(L("取消"), role: .cancel) {
                    newBranchName = ""
                    newBranchBase = nil
                }
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
            .alert(
                L("删除远程分支"),
                isPresented: Binding(
                    get: { pendingDeleteRemoteBranch != nil },
                    set: { if !$0 { pendingDeleteRemoteBranch = nil } }
                ),
                presenting: pendingDeleteRemoteBranch
            ) { branch in
                Button(L("删除"), role: .destructive) {
                    pendingDeleteRemoteBranch = nil
                    Task { await viewModel.deleteRemoteBranch(branch) }
                }
                Button(L("取消"), role: .cancel) { pendingDeleteRemoteBranch = nil }
            } message: { branch in
                Text(String(format: L("将从远端删除分支 %@。"), branch.name))
            }
            .alert(
                L("重命名分支"),
                isPresented: Binding(
                    get: { renameBranchTarget != nil },
                    set: { if !$0 { renameBranchTarget = nil } }
                )
            ) {
                TextField(L("分支名称"), text: $renameBranchName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L("确定")) {
                    guard let target = renameBranchTarget else { return }
                    let name = renameBranchName
                    renameBranchTarget = nil
                    Task { await viewModel.renameBranch(target, to: name) }
                }
                Button(L("取消"), role: .cancel) { renameBranchTarget = nil }
            }
            .alert(
                L("合并分支"),
                isPresented: Binding(
                    get: { pendingMergeBranch != nil },
                    set: { if !$0 { pendingMergeBranch = nil } }
                ),
                presenting: pendingMergeBranch
            ) { branch in
                Button(L("合并"), role: .destructive) {
                    pendingMergeBranch = nil
                    Task { await viewModel.merge(branch) }
                }
                Button(L("取消"), role: .cancel) { pendingMergeBranch = nil }
            } message: { branch in
                Text(String(format: L("将把 %@ 合并到当前分支 %@。"), branch.name, viewModel.status?.branch ?? ""))
            }
            .alert(
                L("基变分支"),
                isPresented: Binding(
                    get: { pendingRebaseBranch != nil },
                    set: { if !$0 { pendingRebaseBranch = nil } }
                ),
                presenting: pendingRebaseBranch
            ) { branch in
                Button(L("基变"), role: .destructive) {
                    pendingRebaseBranch = nil
                    Task { await viewModel.rebase(onto: branch) }
                }
                Button(L("取消"), role: .cancel) { pendingRebaseBranch = nil }
            } message: { branch in
                Text(String(format: L("将把当前分支 %@ 基变到 %@。"), viewModel.status?.branch ?? "", branch.name))
            }
            .alert(
                L("新建标签"),
                isPresented: $isNewTagPresented
            ) {
                TextField(L("标签名称"), text: $newTagName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L("创建")) {
                    let name = newTagName
                    newTagName = ""
                    Task { await viewModel.createTag(name: name) }
                }
                Button(L("取消"), role: .cancel) { newTagName = "" }
            }
            .alert(
                L("删除标签"),
                isPresented: Binding(
                    get: { pendingDeleteTag != nil },
                    set: { if !$0 { pendingDeleteTag = nil } }
                ),
                presenting: pendingDeleteTag
            ) { tag in
                Button(L("删除"), role: .destructive) {
                    pendingDeleteTag = nil
                    Task { await viewModel.deleteTag(tag) }
                }
                Button(L("取消"), role: .cancel) { pendingDeleteTag = nil }
            } message: { tag in
                Text(String(format: L("将删除标签 %@。"), tag.name))
            }
            .alert(
                L("修改最近一次提交"),
                isPresented: $isAmendLatestPresented
            ) {
                TextField(L("提交信息…"), text: $amendLatestMessage, axis: .vertical)
                    .lineLimit(1...4)
                Button(L("确定")) {
                    let message = amendLatestMessage
                    Task { await viewModel.amendCommit(message: message) }
                }
                Button(L("取消"), role: .cancel) {}
            }
            .navigationDestination(item: $branchHistory) { branch in
                GitBranchHistoryView(
                    host: viewModel.host,
                    repoRoot: viewModel.repoRoot,
                    branch: branch,
                    dependencies: dependencies
                )
            }
            .sheet(isPresented: $isStashesPresented) {
                GitStashSheet(viewModel: viewModel)
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
            gitTabBar

            if let operation = viewModel.interruptedOperation {
                interruptedBanner(operation)
            }

            if selectedTab == .changes {
                headerBar
            }

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

    private var repoTitle: String {
        viewModel.repoRoot.isEmpty ? L("Git 工作区") : repoName
    }

    private var gitTabBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(GitWorkspaceTab.allCases) { tab in
                Text(tabTitle(tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, ConnSpacing.page)
        .padding(.vertical, ConnSpacing.xs)
    }

    private func interruptedBanner(_ operation: GitInterruptedOperation) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.connWarn)
            Text(operation == .merge ? L("合并进行中") : L("基变进行中"))
                .font(.connFootnote)
                .foregroundStyle(.connInk)
            Spacer()
            Button(L("中止")) {
                Task { await viewModel.abortInterruptedOperation() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isBusy)
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.vertical, ConnSpacing.xs)
        .background(Color.connWarn.opacity(0.1))
    }

    private func tabTitle(_ tab: GitWorkspaceTab) -> String {
        switch tab {
        case .overview: L("概览")
        case .changes: L("变更")
        case .history: L("历史")
        case .branches: L("分支")
        }
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
    }

    private var repoName: String {
        viewModel.repoRoot.split(separator: "/").last.map(String.init) ?? "Git"
    }

    private var overviewRepoCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.connAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.connAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        HStack(spacing: 1) {
            syncButton(.fetch, title: L("获取"), systemImage: "arrow.triangle.2.circlepath", tint: .connInfo)
            syncButton(.pull, title: L("拉取"), systemImage: "arrow.down.circle", tint: .connWarn)
            syncButton(.push, title: L("推送"), systemImage: "arrow.up.circle", tint: .connAccent)
        }
        .background(Color.connLine.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 0.5)
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
                if viewModel.activeSyncAction == action {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                        .frame(height: 24)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(height: 24)
                }
                Text(title)
                    .font(.connCaption)
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ConnSpacing.sm)
            .background(Color.connSurface)
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
                tint: .connInfo,
                action: { isStashesPresented = true }
            )
        }
    }

    @ViewBuilder
    private func statTile(
        title: String,
        count: Int,
        systemImage: String,
        tint: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(spacing: ConnSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.connInk)
                Text(title)
                    .font(.connFootnote)
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .padding(ConnSpacing.sm)
        .connSurface(cornerRadius: ConnRadius.card)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
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
            .contextMenu {
                Button {
                    amendLatestMessage = commit.message
                    isAmendLatestPresented = true
                } label: {
                    Label(L("修改最近一次提交"), systemImage: "pencil.circle")
                }
            }
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
        let query = branchSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLocalBranches = viewModel.branches.filter { !$0.isRemote }
        let allRemoteBranches = viewModel.branches.filter(\.isRemote)
        let localBranches = allLocalBranches.filter { branchMatches($0, query: query) }
        let remoteBranches = allRemoteBranches.filter { branchMatches($0, query: query) }
        let allTags = viewModel.tags
        let tags = allTags.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }

        return VStack(spacing: 0) {
            List {
            Section {
                if localBranches.isEmpty {
                    Text(query.isEmpty ? L("暂无本地分支") : L("未找到匹配的本地分支"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                ForEach(localBranches) { branch in
                    branchMenu(branch)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(L("本地分支"))
                    Text("\(allLocalBranches.count)")
                        .font(.connData(.subheadline))
                        .foregroundStyle(.connMuted)
                    Spacer()
                    Button {
                        newBranchBase = nil
                        newBranchName = ""
                        isNewBranchPresented = true
                    } label: {
                        Label(L("新建分支"), systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.connFootnote.weight(.semibold))
                    .foregroundStyle(.connAccent)
                    .disabled(viewModel.isBusy)
                }
                .textCase(nil)
            }

            Section {
                if remoteBranches.isEmpty {
                    Text(query.isEmpty ? L("暂无远程分支，尝试抓取") : L("未找到匹配的远程分支"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                ForEach(remoteBranches) { branch in
                    branchMenu(branch)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(L("远程分支"))
                    Text("\(allRemoteBranches.count)")
                        .font(.connData(.subheadline))
                        .foregroundStyle(.connMuted)
                    Spacer()
                    Button {
                        Task { await viewModel.sync(.fetch) }
                    } label: {
                        Label(L("抓取"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.connFootnote.weight(.semibold))
                    .foregroundStyle(.connAccent)
                    .disabled(viewModel.isSyncing || viewModel.isBusy)
                }
                .textCase(nil)
            }

            Section {
                if tags.isEmpty {
                    Text(query.isEmpty ? L("暂无标签") : L("未找到匹配的标签"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                ForEach(tags) { tag in
                    tagMenu(tag)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(L("Git 标签"))
                    Text("\(allTags.count)")
                        .font(.connData(.subheadline))
                        .foregroundStyle(.connMuted)
                    Spacer()
                    Button {
                        newTagName = ""
                        isNewTagPresented = true
                    } label: {
                        Label(L("新建标签"), systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.connFootnote.weight(.semibold))
                    .foregroundStyle(.connAccent)
                    .disabled(viewModel.isBusy)
                }
                .textCase(nil)
            }
            }

            .listStyle(.insetGrouped)

            SystemSearchBar(
                text: $branchSearch,
                placeholder: L("筛选分支和标签")
            )
            .frame(height: 52)
            .padding(.horizontal, ConnSpacing.page)
            .background(.bar)
        }
    }

    private func branchMatches(_ branch: GitBranch, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return branch.name.localizedCaseInsensitiveContains(query)
            || (branch.latestCommit?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func branchMenu(_ branch: GitBranch) -> some View {
        Menu {
            branchMenuItems(branch)
        } label: {
            branchRow(branch)
        }
        .disabled(viewModel.isBusy)
    }

    @ViewBuilder
    private func branchMenuItems(_ branch: GitBranch) -> some View {
        let current = viewModel.status?.branch ?? ""

        if branch.isRemote {
            let localName = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
            let remoteName = branch.name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "origin"
            Button {
                Task { await viewModel.checkoutRemoteBranch(branch) }
            } label: {
                Label(String(format: L("检出为 %@"), localName), systemImage: "arrow.left.arrow.right")
            }
            if !current.isEmpty {
                Button {
                    pendingMergeBranch = branch
                } label: {
                    Label(String(format: L("合并到 %@"), current), systemImage: "arrow.triangle.merge")
                }
                Button {
                    pendingRebaseBranch = branch
                } label: {
                    Label(String(format: L("将 %@ 基变到此"), current), systemImage: "arrow.triangle.swap")
                }
            }
            Button {
                newBranchBase = branch
                newBranchName = ""
                isNewBranchPresented = true
            } label: {
                Label(L("从此处新建分支…"), systemImage: "arrow.triangle.branch")
            }
            Button {
                branchHistory = branch
            } label: {
                Label(L("查看最新提交"), systemImage: "clock.arrow.circlepath")
            }
            Button {
                UIPasteboard.general.string = branch.name
                toastCenter.show(L("已复制"), style: .success)
            } label: {
                Label(L("复制名称"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                pendingDeleteRemoteBranch = branch
            } label: {
                Label(String(format: L("从 %@ 删除…"), remoteName), systemImage: "trash")
            }
        } else {
            Button {
                Task { await viewModel.checkout(branch: branch) }
            } label: {
                Label(L("检出"), systemImage: "arrow.left.arrow.right")
            }
            .disabled(branch.isCurrent)

            if !branch.isCurrent {
                if !current.isEmpty {
                    Button {
                        pendingMergeBranch = branch
                    } label: {
                        Label(String(format: L("合并到 %@"), current), systemImage: "arrow.triangle.merge")
                    }
                    Button {
                        pendingRebaseBranch = branch
                    } label: {
                        Label(String(format: L("将 %@ 基变到此"), current), systemImage: "arrow.triangle.swap")
                    }
                }
                Divider()
            }

            Button {
                newBranchBase = branch
                newBranchName = ""
                isNewBranchPresented = true
            } label: {
                Label(L("从此处新建分支…"), systemImage: "arrow.triangle.branch")
            }
            Button {
                branchHistory = branch
            } label: {
                Label(L("查看最新提交"), systemImage: "clock.arrow.circlepath")
            }
            Button {
                renameBranchName = branch.name
                renameBranchTarget = branch
            } label: {
                Label(L("重命名…"), systemImage: "character.cursor.ibeam")
            }
            Button {
                UIPasteboard.general.string = branch.name
                toastCenter.show(L("已复制"), style: .success)
            } label: {
                Label(L("复制名称"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                pendingDeleteBranch = branch
            } label: {
                Label(L("删除…"), systemImage: "trash")
            }
            .disabled(branch.isCurrent)
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: branch.isCurrent
                ? "checkmark.circle.fill"
                : (branch.isRemote ? "cloud" : "arrow.triangle.branch"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(branch.isCurrent ? .connGood : (branch.isRemote ? .connInfo : .connAccent))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name)
                    .font(.connData(.subheadline))
                    .fontWeight(.semibold)
                    .foregroundStyle(.connInk)
                    .lineLimit(1)
                if let message = branch.latestCommit, !message.isEmpty {
                    Text(message)
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: ConnSpacing.xs)

            VStack(alignment: .trailing, spacing: 3) {
                if let date = branch.latestCommitDate {
                    Text(date, format: .relative(presentation: .named))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                if branch.behindCount > 0 {
                    Text("↓\(branch.behindCount)")
                        .font(.connData(.caption2).weight(.semibold))
                        .foregroundStyle(.connWarn)
                } else if branch.aheadCount > 0 {
                    Text("↑\(branch.aheadCount)")
                        .font(.connData(.caption2).weight(.semibold))
                        .foregroundStyle(.connGood)
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func tagMenu(_ tag: GitTag) -> some View {
        Menu {
            Button {
                branchHistory = GitBranch(
                    name: tag.name,
                    isCurrent: false,
                    isRemote: false,
                    latestCommit: nil
                )
            } label: {
                Label(L("查看提交历史"), systemImage: "clock.arrow.circlepath")
            }
            Button {
                Task { await viewModel.checkoutTag(tag) }
            } label: {
                Label(L("检出标签"), systemImage: "arrow.down.to.line")
            }
            Button {
                UIPasteboard.general.string = tag.name
                toastCenter.show(L("已复制"), style: .success)
            } label: {
                Label(L("复制名称"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                pendingDeleteTag = tag
            } label: {
                Label(L("删除标签"), systemImage: "trash")
            }
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "tag")
                    .foregroundStyle(.connWarn)
                    .frame(width: 24)
                Text(tag.name)
                    .font(.connData(.subheadline))
                    .foregroundStyle(.connInk)
                Spacer()
                if let commit = tag.commit {
                    Text(commit)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
            }
        }
        .disabled(viewModel.isBusy)
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
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let commits = viewModel.commits.filter { commitMatches($0, query: query) }

        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if commits.isEmpty && viewModel.isCommitsLoading {
                        ProgressView(L("读取提交记录…"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ConnSpacing.xxl)
                    } else if commits.isEmpty {
                        VStack(spacing: ConnSpacing.sm) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 38))
                                .foregroundStyle(.connMuted)
                            Text(query.isEmpty ? L("暂无提交记录") : L("未找到匹配的提交"))
                                .font(.connSubheadline)
                                .foregroundStyle(.connMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ConnSpacing.xxl)
                    } else {
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            Button {
                                inspectingCommit = commit
                            } label: {
                                historyRow(
                                    commit,
                                    isFirst: index == 0,
                                    isLast: index == commits.count - 1
                                )
                            }
                            .buttonStyle(.plain)

                            if index < commits.count - 1 {
                                Rectangle()
                                    .fill(Color.connLine.opacity(0.45))
                                    .frame(height: 0.5)
                                    .padding(.leading, 22)
                            }
                        }

                        if query.isEmpty, viewModel.commits.count >= viewModel.commitLimit {
                            Button {
                                Task { await viewModel.loadMoreCommits() }
                            } label: {
                                if viewModel.isCommitsLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(L("加载更多"))
                                        .font(.connFootnote)
                                        .foregroundStyle(.connAccent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ConnSpacing.sm)
                            .disabled(viewModel.isCommitsLoading)
                        }
                    }
                }
                .padding(.horizontal, ConnSpacing.page)
                .padding(.vertical, ConnSpacing.sm)
            }

            SystemSearchBar(
                text: $historySearch,
                placeholder: L("消息、作者、哈希")
            )
            .frame(height: 52)
            .padding(.horizontal, ConnSpacing.page)
            .background(.bar)
        }
        .task {
            if viewModel.commits.isEmpty {
                await viewModel.loadCommits()
            }
        }
    }

    private func commitMatches(_ commit: GitCommit, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return commit.message.localizedCaseInsensitiveContains(query)
            || commit.author.localizedCaseInsensitiveContains(query)
            || commit.hash.localizedCaseInsensitiveContains(query)
            || commit.shortHash.localizedCaseInsensitiveContains(query)
    }

    private func historyRow(_ commit: GitCommit, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: ConnSpacing.sm) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isFirst ? Color.connAccent : Color.connMuted.opacity(0.6))
                    .frame(width: 9, height: 9)
                    .padding(.top, 7)
                if !isLast {
                    Rectangle()
                        .fill(Color.connLine)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 7) {
                Text(commit.message)
                    .font(.connSubheadline.weight(.semibold))
                    .foregroundStyle(.connInk)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if !commit.refs.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(commit.refs, id: \.self) { ref in
                            refBadge(ref)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text(String(commit.author.prefix(1)).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.connAccent, in: Circle())
                    Text(commit.author)
                        .lineLimit(1)
                    Text("·")
                    Text(commit.relativeDate)
                    Spacer(minLength: ConnSpacing.xs)
                    Text(commit.shortHash)
                        .font(.connData(.caption2))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.connLine.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
            }
            .padding(.vertical, 10)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.connDim)
                .padding(.top, 14)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func refBadge(_ ref: String) -> some View {
        let isHead = ref.hasPrefix("HEAD -> ")
        let name = isHead ? String(ref.dropFirst("HEAD -> ".count)) : ref
        let isRemote = name.contains("/")
        Label {
            Text(name)
                .lineLimit(1)
        } icon: {
            Image(systemName: isHead ? "arrow.triangle.branch" : (isRemote ? "cloud" : "tag"))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isHead ? .connAccent : (isRemote ? .connInfo : .connWarn))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            (isHead ? Color.connAccent : (isRemote ? Color.connInfo : Color.connWarn)).opacity(0.12),
            in: Capsule()
        )
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
                Spacer()
                Text(String(format: L("%d 个文件变更"), status.changes.count))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
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
            sectionHeader(
                title: L("已暂存变更"),
                count: staged.count,
                actionTitle: L("全部取消暂存"),
                action: { Task { await viewModel.unstageAll() } }
            )
            fileGroupCard(staged)
        }

        if !unstaged.isEmpty {
            sectionHeader(
                title: L("工作区变更"),
                count: unstaged.count,
                actionTitle: L("全部暂存"),
                action: { Task { await viewModel.stageAll() } }
            )
            fileGroupCard(unstaged)
        }
    }

    private func sectionHeader(
        title: String,
        count: Int,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.connDim)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.connFootnote.weight(.semibold))
                        .foregroundStyle(.connAccent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy)
            }
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
                    Text((file.path as NSString).lastPathComponent)
                        .font(.connData(.subheadline).weight(.semibold))
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                    Text((file.path as NSString).deletingLastPathComponent)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)

                if let stat = viewModel.fileStats[file.path] {
                    HStack(spacing: 4) {
                        Text("+\(stat.additions)")
                            .foregroundStyle(.connGood)
                        Text("-\(stat.deletions)")
                            .foregroundStyle(.connCrit)
                    }
                    .font(.connData(.caption2).weight(.semibold))
                }

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
                TextField(L("提交信息…"), text: $viewModel.commitMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.connSubheadline)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.connLine.opacity(0.3), in: RoundedRectangle(cornerRadius: ConnRadius.control))

                Button {
                    Task {
                        if isAmendCommit {
                            await viewModel.amendCommit()
                        } else {
                            await viewModel.commit()
                        }
                        isAmendCommit = false
                    }
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
                .contextMenu {
                    Button {
                        Task { await viewModel.commitAndPush() }
                    } label: {
                        Label(L("提交并推送"), systemImage: "arrow.up.circle")
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.top, ConnSpacing.xs)

            HStack(spacing: ConnSpacing.xs) {
                Button {
                    isAmendCommit.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isAmendCommit ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isAmendCommit ? .connAccent : .connMuted)
                        Text(L("修补提交"))
                            .font(.connFootnote.weight(.medium))
                            .foregroundStyle(isAmendCommit ? .connAccent : .connMuted)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy)

                Spacer()

                Text(
                    isAmendCommit
                        ? L("替换最近一次提交")
                        : String(format: L("%d 个已暂存文件"), viewModel.status?.stagedChanges.count ?? 0)
                )
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
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
