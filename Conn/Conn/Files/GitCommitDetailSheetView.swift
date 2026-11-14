import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

private enum CommitAction: String, Identifiable {
    case checkout
    case cherryPick
    case revert
    case reset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .checkout: L("检出提交")
        case .cherryPick: L("拣选提交")
        case .revert: L("撤销提交")
        case .reset: L("重置分支")
        }
    }

    var confirmTitle: String {
        switch self {
        case .checkout: L("检出")
        case .cherryPick: L("拣选")
        case .revert: L("撤销")
        case .reset: L("重置")
        }
    }

    var message: String {
        switch self {
        case .checkout: L("将切换到该提交的 detached HEAD 状态。")
        case .cherryPick: L("将该提交的改动拣选到当前分支。")
        case .revert: L("创建一个反向提交来撤销该提交。")
        case .reset: L("将当前分支硬重置到该提交，工作区修改会丢失。")
        }
    }

    var successMessage: String {
        switch self {
        case .checkout: L("已检出提交")
        case .cherryPick: L("已拣选提交")
        case .revert: L("已撤销提交")
        case .reset: L("已重置分支")
        }
    }

    var isDestructive: Bool {
        self == .reset
    }
}

/// 查看特定 Commit 的改动详情与补丁 Diff
struct GitCommitDetailSheetView: View {
    let host: Host
    let repoRoot: String
    let commit: GitCommit
    let dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connToastCenter) private var toastCenter

    @State private var fileDiffs: [GitFileDiff] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expandedFiles: Set<String> = []
    @State private var isNewBranchPresented = false
    @State private var newBranchName = ""
    @State private var isNewTagPresented = false
    @State private var newTagName = ""
    @State private var pendingAction: CommitAction?

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("读取提交详情…"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ConnRetryState(errorMessage, retryTitle: L("重试")) {
                    Task { await loadCommitDiff() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: ConnSpacing.md) {
                        // 提交摘要卡片
                        commitHeaderCard

                        // 变更文件汇总
                        fileSummaryCard

                        // 每个文件的 Diff 折叠列表（通栏直角平铺，与工作区单文件 diff 样式完全统一）
                        LazyVStack(spacing: ConnSpacing.sm) {
                            ForEach(fileDiffs, id: \.filePath) { fileDiff in
                                fileDiffSection(fileDiff)
                            }
                        }
                    }
                    .padding(.vertical, ConnSpacing.sm)
                }
                .background(Color.connBg)
            }
        }
        .navigationTitle(commit.shortHash)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                commitMenu
            }
        }
        .alert(L("新建分支"), isPresented: $isNewBranchPresented) {
            TextField(L("分支名称"), text: $newBranchName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("创建")) {
                let name = newBranchName
                newBranchName = ""
                Task { await createBranch(name) }
            }
            Button(L("取消"), role: .cancel) { newBranchName = "" }
        }
        .alert(L("新建标签"), isPresented: $isNewTagPresented) {
            TextField(L("标签名称"), text: $newTagName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("创建")) {
                let name = newTagName
                newTagName = ""
                Task { await createTag(name) }
            }
            Button(L("取消"), role: .cancel) { newTagName = "" }
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) {
                Task { await perform(action) }
            }
            Button(L("取消"), role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
        .task { await loadCommitDiff() }
    }

    private var commitMenu: some View {
        Menu {
            Button {
                copy(commit.hash, message: L("已复制完整 Commit Hash"))
            } label: {
                Label(L("复制完整 Commit Hash"), systemImage: "number")
            }
            Button {
                copy(commit.message, message: L("已复制提交信息"))
            } label: {
                Label(L("复制提交信息"), systemImage: "text.quote")
            }
            Divider()
            Button {
                newBranchName = ""
                isNewBranchPresented = true
            } label: {
                Label(L("在此新建分支…"), systemImage: "arrow.triangle.branch")
            }
            Button {
                newTagName = ""
                isNewTagPresented = true
            } label: {
                Label(L("在此新建标签…"), systemImage: "tag")
            }
            Divider()
            Button {
                pendingAction = .checkout
            } label: {
                Label(L("检出"), systemImage: "arrow.left.arrow.right")
            }
            Button {
                pendingAction = .cherryPick
            } label: {
                Label(L("拣选"), systemImage: "arrow.triangle.branch")
            }
            Button {
                pendingAction = .revert
            } label: {
                Label(L("撤销提交"), systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                pendingAction = .reset
            } label: {
                Label(L("将分支重置到此处"), systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(isLoading)
    }

    private func copy(_ value: String, message: String) {
        UIPasteboard.general.string = value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        toastCenter.show(message, style: .success)
    }

    private func gitService() async throws -> GitService {
        let session = try await dependencies.connectionManager.session(for: host)
        return GitService(session: session)
    }

    private func createBranch(_ name: String) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let service = try await gitService()
            try await service.createBranch(
                name: name,
                at: repoRoot,
                checkout: false,
                from: commit.hash
            )
            toastCenter.show(L("已创建分支"), style: .success)
        } catch {
            toastCenter.show(error.friendlyDiagnosis, style: .error)
        }
    }

    private func createTag(_ name: String) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let service = try await gitService()
            try await service.createTag(name: name, at: repoRoot, commit: commit.hash)
            toastCenter.show(L("已创建标签"), style: .success)
        } catch {
            toastCenter.show(error.friendlyDiagnosis, style: .error)
        }
    }

    private func perform(_ action: CommitAction) async {
        pendingAction = nil
        do {
            let service = try await gitService()
            switch action {
            case .checkout:
                try await service.checkoutCommit(commit.hash, at: repoRoot)
            case .cherryPick:
                try await service.cherryPick(commit.hash, at: repoRoot)
            case .revert:
                try await service.revert(commit.hash, at: repoRoot)
            case .reset:
                try await service.resetHard(to: commit.hash, at: repoRoot)
            }
            toastCenter.show(action.successMessage, style: .success)
            if action == .checkout || action == .reset {
                dismiss()
            }
        } catch {
            toastCenter.show(error.friendlyDiagnosis, style: .error)
        }
    }

    private var commitHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.message)
                .font(.connHeadline)
                .foregroundStyle(.connInk)
                .lineLimit(4)

            Divider().background(Color.connLine)

            HStack(spacing: 10) {
                Text(String(commit.author.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.connAccent, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.author)
                        .font(.connSubheadline.weight(.semibold))
                        .foregroundStyle(.connInk)
                    if let email = commit.authorEmail, !email.isEmpty {
                        Text(email)
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(commit.relativeDate)
                        .font(.connFootnote.weight(.medium))
                        .foregroundStyle(.connInk)
                    Text(commit.date)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
            }

            Divider().background(Color.connLine)

            hashRow(L("提交"), hash: commit.hash)
            if let parent = commit.parentHash, !parent.isEmpty {
                hashRow(L("父提交"), hash: parent)
            }
        }
        .padding(ConnSpacing.sm)
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
        .overlay(RoundedRectangle(cornerRadius: ConnRadius.card).stroke(Color.connLine, lineWidth: 1))
        .padding(.horizontal, ConnSpacing.page)
    }

    private func hashRow(_ title: String, hash: String) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
                .frame(width: 42, alignment: .leading)
            Text(hash)
                .font(.connData(.caption2))
                .foregroundStyle(.connAccent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                copy(hash, message: L("已复制完整 Commit Hash"))
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.connAccent)
            }
            .buttonStyle(.plain)
        }
    }

    private var fileSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(format: L("%d 个文件有变动"), fileDiffs.count))
                    .font(.connSubheadline.weight(.semibold))
                    .foregroundStyle(.connInk)
                Spacer()
                Text("+\(fileDiffs.reduce(0) { $0 + $1.additions })")
                    .foregroundStyle(.connGood)
                Text("-\(fileDiffs.reduce(0) { $0 + $1.deletions })")
                    .foregroundStyle(.connCrit)
                Button(expandedFiles.isEmpty ? L("全部展开") : L("全部折叠")) {
                    if expandedFiles.isEmpty {
                        expandedFiles = Set(fileDiffs.map(\.filePath))
                    } else {
                        expandedFiles.removeAll()
                    }
                }
                .font(.connFootnote.weight(.semibold))
                .foregroundStyle(.connAccent)
                .buttonStyle(.plain)
            }
            .font(.connData(.caption))
            .padding(ConnSpacing.sm)
        }
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
        .overlay(RoundedRectangle(cornerRadius: ConnRadius.card).stroke(Color.connLine, lineWidth: 0.5))
        .padding(.horizontal, ConnSpacing.page)
    }

    private func fileDiffSection(_ fileDiff: GitFileDiff) -> some View {
        let isExpanded = expandedFiles.contains(fileDiff.filePath)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded {
                    expandedFiles.remove(fileDiff.filePath)
                } else {
                    expandedFiles.insert(fileDiff.filePath)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.connMuted)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 2) {
                        Text((fileDiff.filePath as NSString).lastPathComponent)
                            .font(.connData(.subheadline).weight(.semibold))
                            .foregroundStyle(.connInk)
                            .lineLimit(1)
                        Text((fileDiff.filePath as NSString).deletingLastPathComponent)
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text("+\(fileDiff.additions)").foregroundStyle(.connGood)
                        Text("-\(fileDiff.deletions)").foregroundStyle(.connCrit)
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, ConnSpacing.cardPadding)
                .padding(.vertical, 8)
                .background(Color.connSurface)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Rectangle().fill(Color.connLine).frame(height: 0.5)

                if fileDiff.hunks.isEmpty {
                    Text(L("无文本差异（二进制文件或模式变更）"))
                        .font(.connCaption)
                        .foregroundStyle(.connMuted)
                        .padding(.horizontal, ConnSpacing.cardPadding)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.connBg)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(fileDiff.hunks) { hunk in
                            Text(hunk.header)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.connDim)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.connLine.opacity(0.5))

                            ForEach(hunk.lines) { line in
                                GitDiffLineRow(line: line)
                            }
                        }
                    }
                    .background(Color.connBg)
                    .padding(.bottom, 6)
                }
            }
        }
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.control))
        .clipShape(RoundedRectangle(cornerRadius: ConnRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.control)
                .strokeBorder(Color.connLine, lineWidth: 1)
        )
        .padding(.horizontal, ConnSpacing.page)
    }

    private func loadCommitDiff() async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await dependencies.connectionManager.session(for: host)
            let service = GitService(session: session)
            let diffs = try await service.showCommitDiff(hash: commit.hash, at: repoRoot)
            self.fileDiffs = diffs
            // 默认展开前 3 个文件
            self.expandedFiles = Set(diffs.prefix(3).map(\.filePath))
            self.isLoading = false
        } catch {
            self.errorMessage = error.friendlyDiagnosis
            self.isLoading = false
        }
    }
}
