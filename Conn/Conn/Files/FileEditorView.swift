import ConnEditor
import ConnKit
import ConnSSH
import ConnUI
import Observation
import SwiftUI

/// 文本文件在线编辑 ViewModel（Phase 6）。
@Observable
@MainActor
final class FileEditorViewModel {
    enum LoadState: Equatable {
        case loading
        case editing
        case readOnly(String)
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    var content = ""
    private(set) var isSaving = false
    var saveMessage: String?

    private let host: Host
    private let connectionManager: ConnectionManager
    let entry: FileEntry
    private let maxEditBytes: UInt64 = 1024 * 1024
    // #16：缓存 SFTP 通道，load + save 复用一条，不每次开新通道泄漏。
    private var cachedFileSystem: (any RemoteFileSystem)?

    init(host: Host, dependencies: AppDependencies, entry: FileEntry) {
        self.host = host
        connectionManager = dependencies.connectionManager
        self.entry = entry
    }

    func load() async {
        loadState = .loading
        if entry.size > maxEditBytes {
            loadState = .readOnly(L("文件超过 1MB，暂不支持在线编辑。请下载后查看。"))
            return
        }
        do {
            let data = try await filesystem().readAll(entry.path)
            if data.contains(0) {
                loadState = .readOnly(L("二进制文件，无法以文本方式编辑。"))
                return
            }
            guard let text = String(bytes: data, encoding: .utf8) else {
                loadState = .readOnly(L("非 UTF-8 编码，暂不支持在线编辑。"))
                return
            }
            content = text
            loadState = .editing
        } catch {
            cachedFileSystem = nil
            loadState = .failed(error.friendlyDiagnosis)
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            // #4：写临时文件 → 保留原权限 → 原子改名替换。避免「先截断原文件再写」——
            // 半途掉线会把正在用的配置文件（如 nginx.conf）清空/写坏。临时文件失败时原文件不动。
            let fileSystem = try await filesystem()
            let tempPath = entry.path + ".conntmp"
            try await fileSystem.writeAll(Data(content.utf8), to: tempPath)
            let mode = (try? await fileSystem.stat(entry.path).permissions) ?? entry.permissions
            if let mode { try? await fileSystem.setPermissions(mode & 0o7777, path: tempPath) }
            // SFTP rename 不覆盖已存在目标：先删原文件再改名（窗口毫秒级，失败时 .conntmp 仍在可恢复）。
            try? await fileSystem.remove(entry.path)
            try await fileSystem.rename(tempPath, to: entry.path)
            saveMessage = L("已保存")
        } catch {
            cachedFileSystem = nil // 出错丢弃可能已死的通道
            saveMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    private func filesystem() async throws -> any RemoteFileSystem {
        if let cachedFileSystem { return cachedFileSystem }
        let opened = try await connectionManager.session(for: host).sftp()
        cachedFileSystem = opened
        return opened
    }

}

/// 文本文件编辑器（Phase 6）。行号 + 语法高亮（Highlightr），主题跟随设置页。
struct FileEditorView: View {
    @State private var viewModel: FileEditorViewModel
    @Environment(SettingsStore.self) private var settings

    init(host: Host, dependencies: AppDependencies, entry: FileEntry) {
        _viewModel = State(initialValue: FileEditorViewModel(host: host, dependencies: dependencies, entry: entry))
    }

    var body: some View {
        content
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(viewModel.entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            .toolbar {
                if case .editing = viewModel.loadState {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("保存")) { Task { await viewModel.save() } }
                            .fontWeight(.semibold)
                            .disabled(viewModel.isSaving)
                    }
                }
            }
            .alert(L("保存"), isPresented: saveBinding) {
                Button(L("好"), role: .cancel) { viewModel.saveMessage = nil }
            } message: {
                Text(viewModel.saveMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(L("读取文件…")).font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editing:
            CodeEditor(
                text: $viewModel.content,
                language: CodeEditorCatalog.language(forFileName: viewModel.entry.name),
                configuration: settings.codeEditorConfiguration
            )
            .ignoresSafeArea(.container, edges: .bottom)
        case let .readOnly(message):
            infoState(icon: "doc.plaintext", message: message)
        case let .failed(message):
            ConnRetryState(message, retryTitle: L("重试")) {
                Task { await viewModel.load() }
            }
            .padding(.horizontal, ConnSpacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func infoState(icon: String, message: String) -> some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            Text(message).font(.connSubheadline).foregroundStyle(.connMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ConnSpacing.page)
    }

    private var saveBinding: Binding<Bool> {
        Binding(get: { viewModel.saveMessage != nil }, set: { if !$0 { viewModel.saveMessage = nil } })
    }
}
