import ConnKit
import ConnSSH
import ConnUI
import SwiftUI

/// 目录选择器（弹窗）：用户在一台主机的目录树里选一个目标位置。
///
/// 设计目标（替代 alert TextField 输绝对路径）：
/// - 复用 `FileBrowserView` 的导航体感（面包屑 + 子目录列表）
/// - 只能选目录，不能进文件/编辑/删除——比 FileBrowserView 精简
/// - 路径定位：从 `initialPath` 进入（默认传当前浏览目录），用户逐层下钻
/// - 底部「保存」回调当前路径；「取消」直接关闭
///
/// 复用场景：移动 / 复制（v1）；未来压缩的输出位置、跨主机复制的目标目录（v2）。
struct DirectoryPickerView: View {
    let title: String
    let initialPath: String
    /// **同步**回调所选目录——只把路径交回父视图，实际操作由父视图另起 Task 执行。
    /// 不在本弹窗里 `await` 执行操作：弹窗随即 dismiss，异步闭包跨越 dismiss 会用到已释放
    /// 的上下文（移动保存后 EXC_BAD_ACCESS 崩溃的根因）。
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath: String
    @State private var entries: [FileEntry] = []
    @State private var loadState: LoadState = .loading
    @State private var errorText: String?
    @State private var fileSystem: (any RemoteFileSystem)?

    private let connectionManager: ConnectionManager
    private let host: Host

    init(
        title: String,
        host: Host,
        connectionManager: ConnectionManager,
        initialPath: String,
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.host = host
        self.connectionManager = connectionManager
        self.initialPath = initialPath
        self.onConfirm = onConfirm
        _currentPath = State(initialValue: initialPath)
    }

    enum LoadState { case loading, ready, failed }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                breadcrumb
                content
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存")) { confirm() }
                        .disabled(loadState != .ready)
                }
            }
        }
        .task { await load(path: initialPath) }
    }

    // MARK: - 顶部：面包屑

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(breadcrumbs) { crumb in
                    if !crumb.isRoot {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.connDim)
                    }
                    Button {
                        if !crumb.isCurrent { Task { await load(path: crumb.path) } }
                    } label: {
                        crumb.isRoot
                            ? AnyView(Image(systemName: "externaldrive").font(.system(size: 15)))
                            : AnyView(Text(crumb.label).font(.connData(.subheadline)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(crumb.isCurrent ? Color.connInk : .connAccent)
                    .fontWeight(crumb.isCurrent ? .semibold : .regular)
                    .disabled(crumb.isCurrent)
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.sm)
        }
        .background(Color.connSurface)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView(L("读取目录…"))
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: ConnSpacing.sm) {
                if let errorText {
                    ConnBanner(errorText, systemImage: "exclamationmark.triangle")
                }
                Button(L("重试")) { Task { await load(path: currentPath) } }
                    .font(.connBody)
                    .foregroundStyle(.connAccent)
            }
            .padding(ConnSpacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if entries.isEmpty {
                Text(L("空目录"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Rectangle().fill(Color.connLine).frame(height: 0.5)
                                    .padding(.leading, 52)
                            }
                            row(entry)
                        }
                    }
                    .connSurface(cornerRadius: ConnRadius.card)
                    .padding(.horizontal, ConnSpacing.page)
                    .padding(.bottom, ConnSpacing.lg)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        Button {
            Task { await load(path: entry.path) }
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.connAccent)
                    .frame(width: 28)
                Text(entry.name)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                    .lineLimit(1)
                Spacer(minLength: ConnSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.connDim)
            }
            .padding(.horizontal, ConnSpacing.cardPadding)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 操作

    private func load(path: String) async {
        loadState = .loading
        errorText = nil
        do {
            let all = try await filesystem().list(path)
            // 仅目录——picker 只能选目录
            entries = all.filter(\.isDirectory)
            currentPath = path
            loadState = .ready
        } catch {
            errorText = error.friendlyDiagnosis
            loadState = .failed
        }
    }

    private func confirm() {
        guard loadState == .ready else { return }
        // 同步把路径交回父视图（父视图会另起 Task 执行 + 显示蒙层），然后关弹窗。
        onConfirm(currentPath)
        dismiss()
    }

    private func filesystem() async throws -> any RemoteFileSystem {
        if let fileSystem { return fileSystem } // 缓存复用——避免每次进目录都新开一个 SFTP 通道
        let session = try await connectionManager.session(for: host)
        let opened = try await session.sftp()
        fileSystem = opened
        return opened
    }

    // MARK: - 派生

    private struct Crumb: Identifiable {
        let label: String
        let path: String
        let isRoot: Bool
        let isCurrent: Bool
        var id: String { path }
    }

    private var breadcrumbs: [Crumb] {
        let comps = currentPath.split(separator: "/").map(String.init)
        var result = [Crumb(label: "/", path: "/", isRoot: true, isCurrent: currentPath == "/")]
        var accumulated = ""
        for (index, component) in comps.enumerated() {
            accumulated += "/" + component
            result.append(Crumb(
                label: component, path: accumulated,
                isRoot: false, isCurrent: index == comps.count - 1
            ))
        }
        return result
    }
}
