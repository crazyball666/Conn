import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

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

    var body: some View {
        NavigationStack {
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

                            // 变更文件数量与改动统计
                            HStack {
                                Text(String(format: L("变更文件 (%d)"), fileDiffs.count))
                                    .font(.connSubheadline.weight(.semibold))
                                    .foregroundStyle(.connInk)
                                Spacer()
                                let totalAdditions = fileDiffs.reduce(0) { $0 + $1.additions }
                                let totalDeletions = fileDiffs.reduce(0) { $0 + $1.deletions }
                                HStack(spacing: 6) {
                                    Text("+\(totalAdditions)").foregroundStyle(.connGood)
                                    Text("-\(totalDeletions)").foregroundStyle(.connCrit)
                                }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, ConnSpacing.page)

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
                    Button(L("完成")) { dismiss() }
                }
            }
            .task { await loadCommitDiff() }
        }
    }

    private var commitHeaderCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(commit.message)
                .font(.connHeadline)
                .foregroundStyle(.connInk)
                .lineLimit(4)

            Divider()
                .background(Color.connLine)

            HStack(spacing: ConnSpacing.md) {
                Label(commit.author, systemImage: "person.fill")
                    .font(.connCaption)
                    .foregroundStyle(.connDim)

                Label(commit.relativeDate, systemImage: "clock")
                    .font(.connCaption)
                    .foregroundStyle(.connDim)
            }

            HStack {
                Text(commit.hash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    UIPasteboard.general.string = commit.hash
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    toastCenter.show(L("已复制完整 Commit Hash"), style: .success)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.connAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(ConnSpacing.sm)
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
        .overlay(RoundedRectangle(cornerRadius: ConnRadius.card).stroke(Color.connLine, lineWidth: 1))
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

                    Text(fileDiff.filePath)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                        .truncationMode(.middle)

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
