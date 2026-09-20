import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

/// 移动端 Unified Diff 行视图
struct GitDiffLineRow: View {
    let line: GitDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 行号列
            HStack(spacing: 2) {
                Text(line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 24, alignment: .trailing)
                Text(line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 24, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.connDim)

            // 增减标识
            Text(prefixSymbol)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 10, alignment: .center)

            // 代码文本（支持软换行）
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(backgroundColor)
    }

    private var prefixSymbol: String {
        switch line.type {
        case .addition: return "+"
        case .deletion: return "-"
        case .context, .header: return " "
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .addition: return .connGood
        case .deletion: return .connCrit
        case .context, .header: return .connDim
        }
    }

    private var textColor: Color {
        switch line.type {
        case .addition: return .connInk
        case .deletion: return .connCrit
        case .context, .header: return .connInk
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .addition: return Color.connGood.opacity(0.12)
        case .deletion: return Color.connCrit.opacity(0.12)
        case .context, .header: return Color.clear
        }
    }
}

/// 单个文件的完整 Unified Diff 视图
struct GitDiffSheetView: View {
    let host: Host
    let repoRoot: String
    let file: GitFileChange
    let dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @State private var diff: GitFileDiff?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(host: Host, repoRoot: String, file: GitFileChange, dependencies: AppDependencies) {
        self.host = host
        self.repoRoot = repoRoot
        self.file = file
        self.dependencies = dependencies
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L("读取差异…"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ConnRetryState(errorMessage, retryTitle: L("重试")) {
                        Task { await loadDiff() }
                    }
                } else if let diff, diff.hunks.isEmpty {
                    Text(L("无差异"))
                        .font(.connSubheadline)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.hunks) { hunk in
                                // 分块标题
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
                    }
                    .background(Color.connBg)
                }
            }
            .navigationTitle(file.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let diff {
                        HStack(spacing: 4) {
                            Text("+\(diff.additions)").foregroundStyle(.connGood)
                            Text("-\(diff.deletions)").foregroundStyle(.connCrit)
                        }
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
            .task { await loadDiff() }
        }
    }

    private func loadDiff() async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await dependencies.connectionManager.session(for: host)
            let gitService = GitService(session: session)
            diff = try await gitService.diff(for: file, at: repoRoot)
            isLoading = false
        } catch {
            errorMessage = error.friendlyDiagnosis
            isLoading = false
        }
    }
}
