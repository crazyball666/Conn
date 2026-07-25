import ConnKit
import ConnSSH
import Foundation
import Observation

/// 文件传输状态（下载/上传进度）。
struct FileTransferState: Equatable {
    enum Direction { case download, upload }
    let name: String
    let direction: Direction
    var progress: Double
}

/// SFTP 文件浏览 ViewModel（Phase 6）。
///
/// 复用连接池会话，惰性打开一个 SFTP 子通道并缓存；操作失败时清缓存以便下次重连。
@Observable
@MainActor
final class FileBrowserViewModel {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var currentPath = "/"
    private(set) var entries: [FileEntry] = []
    var showHidden = false
    /// 首次加载后置真——切换分段/从编辑器返回时不再自动重拉（改下拉刷新）。
    private(set) var hasLoaded = false

    // 操作确认/表单状态
    var pendingDeletion: FileEntry?
    var actionMessage: String?

    // 传输状态（下载/上传进度）
    var transfer: FileTransferState?
    /// 下载完成待分享的本地文件。
    var downloadedURL: URL?

    let host: Host
    private let connectionManager: ConnectionManager
    private var fileSystem: (any RemoteFileSystem)?

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
    }

    var canGoUp: Bool { currentPath != "/" }

    // MARK: - 导航 / 列表

    /// 仅首次加载（分段出现时调用）。已加载则跳过，避免每次切换重拉。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load(path: String? = nil) async {
        let target = path ?? currentPath
        hasLoaded = true
        loadState = .loading
        do {
            let list = try await filesystem().list(target)
            currentPath = target
            entries = list
            loadState = .ready
        } catch {
            loadState = .failed(friendly(error))
            fileSystem = nil // 通道可能已坏，下次重开
        }
    }

    func enter(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        await load(path: entry.path)
    }

    func goUp() async {
        guard canGoUp else { return }
        await load(path: RemotePath.parent(currentPath))
    }

    /// 下拉刷新：静默重拉当前目录，不切 `.loading`——保留列表可见、避免闪烁。
    /// 失败时保留上次结果，仅弹提示（不把列表替换成错误页）。
    func refresh() async {
        do {
            entries = try await filesystem().list(currentPath)
        } catch {
            actionMessage = String(format: L("%@ 失败：%@"), L("刷新"), friendly(error))
            fileSystem = nil
        }
    }

    // MARK: - 目录操作

    func createDirectory(named name: String) async {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        await run(L("新建文件夹")) {
            try await self.filesystem().createDirectory(RemotePath.join(self.currentPath, clean))
        }
    }

    func rename(_ entry: FileEntry, to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != entry.name else { return }
        await run(L("重命名")) {
            try await self.filesystem().rename(entry.path, to: RemotePath.join(RemotePath.parent(entry.path), clean))
        }
    }

    func confirmDeletion() async {
        guard let entry = pendingDeletion else { return }
        pendingDeletion = nil
        await run(L("删除")) {
            let fileSystem = try await self.filesystem()
            if entry.isDirectory {
                try await fileSystem.removeDirectory(entry.path)
            } else {
                try await fileSystem.remove(entry.path)
            }
        }
    }

    func chmod(_ entry: FileEntry, octal: String) async {
        guard let mode = FilePermissions.mode(fromOctal: octal) else {
            actionMessage = L("权限格式应为八进制，如 644")
            return
        }
        await run(L("修改权限")) {
            try await self.filesystem().setPermissions(mode, path: entry.path)
        }
    }

    /// 统一执行 + 刷新 + 错误提示。
    private func run(_ label: String, _ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            await load()
        } catch {
            actionMessage = String(format: L("%@失败：%@"), label, friendly(error))
            fileSystem = nil // #10：丢弃可能已死的 SFTP 通道，下次操作重开（与 load() 一致）
        }
    }

    // MARK: - 会话

    func filesystem() async throws -> any RemoteFileSystem {
        if let fileSystem { return fileSystem }
        let session = try await connectionManager.session(for: host)
        let opened = try await session.sftp()
        fileSystem = opened
        return opened
    }

    func friendly(_ error: Error) -> String {
        if let sshError = error as? SSHError {
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? sshError.diagnosis
        }
        return error.localizedDescription
    }
}
