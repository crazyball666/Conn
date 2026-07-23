import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// 日志流 ViewModel（Phase 8）。journalctl / 文件 tail -F / docker logs 通用。
///
/// 复用终端的合帧思路但走独立轻量管线（非 PTY）。本地 ring 5000 行；
/// 关键词过滤为客户端 grep（不改远端命令，保证只读安全，方案 §4.4）。
@Observable
@MainActor
final class LogStreamViewModel {
    let source: LogSource
    private(set) var lines: [LogLine] = []
    private(set) var isConnecting = true
    private(set) var errorText: String?
    /// 跟随（自动滚到底）。暂停只停滚动，不停接收（缓冲仍在增长，上限 5000）。
    var isFollowing = true
    var filterText = ""

    private let host: Host
    private let connectionManager: ConnectionManager
    private let sudo: Bool
    private let cap = 5000
    private var task: Task<Void, Never>?
    private var nextID = 0
    private var partial = ""

    init(host: Host, dependencies: AppDependencies, source: LogSource, sudo: Bool = false) {
        self.host = host
        connectionManager = dependencies.connectionManager
        self.source = source
        self.sudo = sudo
    }

    /// 过滤后可见行（客户端 grep，大小写不敏感）。
    var visibleLines: [LogLine] {
        guard !filterText.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(filterText) }
    }

    func start() {
        guard task == nil else { return }
        task = Task { await stream() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear() {
        lines.removeAll()
    }

    private func stream() async {
        isConnecting = true
        errorText = nil
        do {
            let session = try await connectionManager.session(for: host)
            let output = try await session.execStream(source.followCommand(sudo: sudo))
            isConnecting = false
            for try await chunk in output {
                appendChunk(chunk)
            }
        } catch is CancellationError {
            // 正常停止
        } catch {
            isConnecting = false
            errorText = friendly(error)
        }
    }

    /// 把 Data 块按行切分，跨块的半行留在 `partial`。
    private func appendChunk(_ data: Data) {
        // 日志可能含被截断的多字节序列，用无损 decoding 把坏字节替换为占位符，
        // 而非整块丢弃（与 ExecResult 同策略）。
        // swiftlint:disable:next optional_data_string_conversion
        partial += String(decoding: data, as: UTF8.self)
        var segments = partial.components(separatedBy: "\n")
        partial = segments.removeLast() // 末尾可能是不完整行，留待下块
        for text in segments where !text.isEmpty {
            lines.append(LogLine(id: nextID, text: text))
            nextID += 1
        }
        if lines.count > cap {
            lines.removeFirst(lines.count - cap)
        }
    }

    private func friendly(_ error: Error) -> String {
        if let sshError = error as? SSHError {
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? sshError.diagnosis
        }
        return error.localizedDescription
    }
}
