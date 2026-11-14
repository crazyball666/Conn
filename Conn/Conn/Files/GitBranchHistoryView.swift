import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

/// 单个分支的提交历史。
struct GitBranchHistoryView: View {
    let host: Host
    let repoRoot: String
    let branch: GitBranch
    let dependencies: AppDependencies

    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var inspectingCommit: GitCommit?

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("读取提交记录…"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ConnRetryState(errorMessage, retryTitle: L("重试")) {
                    Task { await load() }
                }
            } else if commits.isEmpty {
                Text(L("暂无提交记录"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ConnSpacing.sm) {
                        ForEach(commits) { commit in
                            Button {
                                inspectingCommit = commit
                            } label: {
                                commitRow(commit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, ConnSpacing.page)
                    .padding(.vertical, ConnSpacing.sm)
                }
                .background(Color.connBg)
            }
        }
        .navigationTitle(branch.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $inspectingCommit) { commit in
            GitCommitDetailSheetView(
                host: host,
                repoRoot: repoRoot,
                commit: commit,
                dependencies: dependencies
            )
        }
        .task { await load() }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(commit.shortHash)
                    .font(.connData(.caption2).weight(.bold))
                    .foregroundStyle(.connAccent)
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
                Text(commit.author)
                Spacer()
                Text(commit.date.prefix(10))
                    .font(.connData(.caption2))
            }
            .font(.connFootnote)
            .foregroundStyle(.connDim)
        }
        .padding(ConnSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await dependencies.connectionManager.session(for: host)
            let service = GitService(session: session)
            commits = try await service.log(at: repoRoot, branch: branch.name)
            isLoading = false
        } catch {
            errorMessage = error.friendlyDiagnosis
            isLoading = false
        }
    }
}
