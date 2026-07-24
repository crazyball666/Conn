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
    /// 未成行的**字节**（不是字符串）——见 appendChunk 的多字节修复。
    private var partialBytes = Data()

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

    /// 把 Data 块按**字节**累积，只在换行(0x0A)处切出**完整行**再解码。
    ///
    /// #7：不能对每个 Data 块单独 `String(decoding:)`——多字节 UTF-8 字符被切在
    /// 块边界时两半各自解码成 �，中日文日志会乱码。按字节缓冲、按 \n 切行,
    /// 保证每次解码的都是完整字符序列。
    private func appendChunk(_ data: Data) {
        partialBytes.append(data)
        while let newline = partialBytes.firstIndex(of: 0x0A) {
            let lineBytes = partialBytes.subdata(in: partialBytes.startIndex ..< newline)
            partialBytes.removeSubrange(partialBytes.startIndex ... newline)
            // swiftlint:disable:next optional_data_string_conversion
            var text = String(decoding: lineBytes, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            if !text.isEmpty {
                lines.append(LogLine(id: nextID, text: text))
                nextID += 1
            }
        }
        // 安全阀：某行长时间没有换行时不让缓冲无限增长。
        if partialBytes.count > 256 * 1024 {
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: partialBytes, as: UTF8.self)
            partialBytes.removeAll(keepingCapacity: true)
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
