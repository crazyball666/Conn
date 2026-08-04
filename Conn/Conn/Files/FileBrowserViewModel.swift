import ConnKit
import ConnSSH
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// 文件传输状态（下载/上传进度）。
struct FileTransferState: Equatable {
    enum Direction { case download, upload }
    let name: String
    let direction: Direction
    var progress: Double
}

/// 文件操作超时。
private struct OperationTimedOut: LocalizedError {
    var errorDescription: String? { L("操作超时") }
}

/// 文件操作失败（携带远端 stderr / 说明）。
private struct FileOpError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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
    /// 默认显示隐藏文件（移动运维场景经常翻 .env / .ssh / .config/…）。
    /// 跨详情页重建时回到默认；设置页持久化下一版做。
    var showHidden = true
    /// 首次加载后置真——切换分段/从编辑器返回时不再自动重拉（改下拉刷新）。
    private(set) var hasLoaded = false

    // 操作确认/表单状态
    var pendingDeletion: FileEntry?
    var actionMessage: String?
    /// 正在进行的文件操作标签（删除/移动/重命名…）——非 nil 时视图盖 loading 蒙层。
    private(set) var busyLabel: String?

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
            loadState = .failed(error.friendlyDiagnosis)
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
            actionMessage = String(format: L("%@ 失败：%@"), L("刷新"), error.friendlyDiagnosis)
            fileSystem = nil
        }
    }

    // MARK: - 目录操作

    func createDirectory(named name: String) async {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let path = RemotePath.join(currentPath, clean) // 在主 actor 上先取路径，供 @Sendable 闭包用
        await run(L("新建文件夹")) {
            try await self.filesystem().createDirectory(path)
        }
    }

    /// 新建空文件：SFTP `open(O_CREAT|O_TRUNC)` 后立即 close，等价 `touch`。
    /// 不主动打开编辑器（与「新建文件夹」一致——留在目录里由用户点入）。
    func createFile(named name: String) async {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let path = RemotePath.join(currentPath, clean) // 在主 actor 上先取路径，供 @Sendable 闭包用
        await run(L("新建文件")) {
            let file = try await self.filesystem().open(path, mode: .writeCreate)
            try? await file.close()
        }
    }

    /// 复制当前目录绝对路径到系统剪贴板。失败/不支持时不弹错——剪贴板是 iOS 上
    /// 静默操作，弹 alert 反而干扰。给一个轻量 `actionMessage` 反馈。
    func copyCurrentPath() {
        #if canImport(UIKit)
        UIPasteboard.general.string = currentPath
        actionMessage = String(format: L("已复制：%@"), currentPath)
        #endif
    }

    /// 跳转到用户输入的绝对路径。
    ///
    /// 与 `load(path:)` 的关键差异：**失败时不动 `loadState` / `entries` / `currentPath`**——
    /// 当前列表原样保留，仅弹 alert 提示。否则跳转错误路径会把用户的当前目录直接
    /// 清空换成错误页，体验上像「被刷新了」。
    /// 不强制校验绝对路径——多数 SFTP 客户端允许 `~` 相对，由远端决定。
    func jumpTo(path input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let list = try await filesystem().list(trimmed)
            currentPath = trimmed
            entries = list
            loadState = .ready
        } catch {
            // 通道可能已坏——丢缓存，下次重开（与 `load` 失败行为对齐）
            fileSystem = nil
            actionMessage = String(format: L("跳转失败：%@"), error.friendlyDiagnosis)
        }
    }

    func rename(_ entry: FileEntry, to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != entry.name else { return }
        await run(L("重命名")) {
            try await self.filesystem().rename(entry.path, to: RemotePath.join(RemotePath.parent(entry.path), clean))
        }
    }

    /// 删除。**直接接收 entry**——不能在异步 Task 里读 `pendingDeletion`：alert 关闭时
    /// 绑定 setter 已把它清 nil，读到会是空 → 之前「删除没反应」的根因。
    /// 目录走 `rm -rf` 递归删除（含内容，与提示一致；SFTP `rmdir` 只能删空目录）；文件走 SFTP remove。
    func delete(_ entry: FileEntry) async {
        pendingDeletion = nil
        if entry.isDirectory {
            let fallbackFailureMessage = L("删除失败")
            await run(L("删除")) {
                let session = try await self.connectionManager.session(for: self.host)
                let result = try await session.exec("rm -rf \(Self.shellQuote(entry.path))", timeout: .seconds(30))
                guard result.isSuccess else {
                    throw FileOpError(result.stderrText.isEmpty ? fallbackFailureMessage : result.stderrText)
                }
            }
        } else {
            await run(L("删除")) {
                try await self.filesystem().remove(entry.path)
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

    // MARK: - 移动 / 复制（同主机）

    /// 移动到目标目录（`SFTP rename` 在 SFTP 协议里是原子的、秒级完成，无需中转）。
    /// 跨主机移动 = 复制 + 删除源，**不在本方法内**（避免一次误操作毁两份数据）。
    func move(_ entry: FileEntry, to destinationDir: String) async {
        let newPath = RemotePath.join(destinationDir, entry.name)
        guard newPath != entry.path else {
            actionMessage = L("源与目标相同")
            return
        }
        await run(L("移动")) {
            try await self.filesystem().rename(entry.path, to: newPath)
        }
    }

    /// 复制到目标目录（走 SSH `exec cp -r`：一次 exec 搞定，目录递归由 cp 处理）。
    /// 不走 SFTP 流式是因为目录递归 walk 麻烦，且 UI 进度条不优先——后续要进度
    /// 再升级到 SFTP 流式。
    /// 注：cp 行为对 `dst` 是否存在有差异——存在则塞进 dst 下、不存在则创建为 dst。
    /// 预检查目标是否同名存在，给出明确报错避免「默默嵌套」。
    func copy(_ entry: FileEntry, to destinationDir: String) async {
        let newPath = RemotePath.join(destinationDir, entry.name)
        guard newPath != entry.path else {
            actionMessage = L("源与目标相同")
            return
        }
        busyLabel = L("复制")
        defer { busyLabel = nil }
        do {
            if (try? await filesystem().stat(newPath)) != nil {
                actionMessage = String(format: L("目标已存在：%@"), newPath)
                return
            }
            let session = try await connectionManager.session(for: host)
            let src = Self.shellQuote(entry.path)
            let dst = Self.shellQuote(newPath)
            let cmd = entry.isDirectory ? "cp -r \(src) \(dst)" : "cp \(src) \(dst)"
            let result = try await session.exec(cmd, timeout: .seconds(120))
            if result.isSuccess {
                await refresh()
            } else {
                actionMessage = String(format: L("复制失败：%@"), result.stderrText)
            }
        } catch {
            actionMessage = String(format: L("复制失败：%@"), error.friendlyDiagnosis)
            fileSystem = nil
        }
    }

    /// POSIX shell 单引号包裹 + 转义路径中的单引号（`'` → `'\''`）。
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 压缩（仅目录）

    /// 压缩目录为 `<dirname>.tar.gz`，放到与目录同级。
    ///
    /// 走 SSH `exec tar`：用 `-C <parent>` 切到上级目录再 tar 目标名，**避免绝对
    /// 路径污染到归档里的路径前缀**（经典坑：`tar -czf /tmp/a.tar.gz /var/log`
    /// 解出来是 `var/log/...`，需要 strip 掉前导 `/`，但用 `-C` 直接规避）。
    /// 失败时常见原因：磁盘满（`No space left on device`）——保留 stderr 提示用户。
    func compress(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        let parent = RemotePath.parent(entry.path)
        let archiveName = entry.name + ".tar.gz"
        let archivePath = RemotePath.join(parent, archiveName)

        busyLabel = L("压缩")
        defer { busyLabel = nil }
        do {
            let session = try await connectionManager.session(for: host)
            let cmd = "tar -C \(Self.shellQuote(parent)) -czf \(Self.shellQuote(archivePath)) \(Self.shellQuote(entry.name))"
            let result = try await session.exec(cmd, timeout: .seconds(600))
            if result.isSuccess {
                actionMessage = String(format: L("已压缩到 %@"), archiveName)
                await refresh()
            } else {
                actionMessage = String(format: L("压缩失败：%@"), result.stderrText)
            }
        } catch {
            actionMessage = String(format: L("压缩失败：%@"), error.friendlyDiagnosis)
            fileSystem = nil
        }
    }

    /// 统一执行：置忙（loading 蒙层）→ 带超时执行 → 刷新 → 错误提示。
    /// 所有操作统一 30s 超时兜底——避免通道卡死时蒙层一直转（正常操作都是秒级完成）。
    private func run(
        _ label: String,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async {
        busyLabel = label
        defer { busyLabel = nil }
        do {
            try await Self.withTimeout(.seconds(30), operation)
            await refresh() // 静默重列，不切 .loading——否则蒙层下内容会闪成「读取目录…」并跳动
        } catch {
            actionMessage = String(format: L("%@失败：%@"), label, error.friendlyDiagnosis)
            fileSystem = nil // #10：丢弃可能已死的 SFTP 通道，下次操作重开（与 load() 一致）
        }
    }

    /// 给任意异步操作加超时：操作与计时器竞速，任一先完成即返回；超时抛 `OperationTimedOut`，
    /// 任务组自动取消未完成任务。（SFTP 操作非协作式取消，取消未必立即停，但控制权已交还，蒙层不再卡。）
    private static func withTimeout(
        _ duration: Duration, _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw OperationTimedOut()
            }
            _ = try await group.next() // 先完成者：成功→返回；超时→抛错（组自动取消其余任务）
            group.cancelAll()          // 成功时取消计时器
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

}
