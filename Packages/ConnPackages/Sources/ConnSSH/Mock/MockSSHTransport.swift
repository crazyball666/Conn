import Foundation

/// 脚本化的假 SSH 引擎。
///
/// 同一实现供**演示模式**（技术方案 §4.10）与 **UI/集成测试**复用——没有服务器
/// 也能完整体验，App Store 审核也靠它。假指标发生器（正弦+噪声、故障机）在
/// Phase 7/10 补，本类型只做命令层与失败注入。
public final class MockSSHTransport: SSHTransport {
    /// 一条命令的预置响应。
    public struct CommandResponse: Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        /// `execCommandStream` 专用的块边界；nil 时使用 `stdout` 的旧按行边界。
        public var streamChunks: [Data]?
        /// 块写完后让 `execCommandStream` 失败，用于模拟传输中断。
        public var streamFailure: SSHError?
        /// 专用块之间的延迟；nil 时回落到 Behavior 的旧全局设置。
        public var streamChunkDelay: Duration?

        public init(
            stdout: String = "",
            stderr: String = "",
            exitCode: Int32 = 0
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            streamChunks = nil
            streamFailure = nil
            streamChunkDelay = nil
        }

        public init(
            streamChunks: [Data]?,
            streamFailure: SSHError? = nil,
            streamChunkDelay: Duration? = nil,
            stdout: String = "",
            stderr: String = "",
            exitCode: Int32 = 0
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.streamChunks = streamChunks
            self.streamFailure = streamFailure
            self.streamChunkDelay = streamChunkDelay
        }
    }

    /// 行为配置：失败注入 + 命令响应覆盖。
    public struct Behavior: Sendable {
        /// 非 nil 则 `connect` 抛此错误（测试诊断树用）。
        public var failConnect: SSHError?
        /// 覆盖或新增命令响应，优先于内置脚本。
        public var commandResponses: [String: CommandResponse]
        /// 动态响应器：按（原始命令, 目标端点）现算响应，返回 nil 则回落内置脚本。
        /// 演示模式（Phase 10）用它生成随时间演化的假指标/容器/日志——数据生成逻辑
        /// 放在 App/Feature 层（可 import ConnMonitor/ConnOps），此处只留一个闭包插槽，
        /// 保持 ConnSSH 与上层解耦。
        public var dynamicResponder: (@Sendable (String, SSHEndpoint) -> CommandResponse?)?
        /// 每块流式输出之间的延迟（execStream 用；测试通常设 0）。
        public var streamChunkDelay: Duration

        public init(
            failConnect: SSHError? = nil,
            commandResponses: [String: CommandResponse] = [:],
            dynamicResponder: (@Sendable (String, SSHEndpoint) -> CommandResponse?)? = nil,
            streamChunkDelay: Duration = .zero
        ) {
            self.failConnect = failConnect
            self.commandResponses = commandResponses
            self.dynamicResponder = dynamicResponder
            self.streamChunkDelay = streamChunkDelay
        }
    }

    private let behavior: Behavior

    public init(behavior: Behavior = Behavior()) {
        self.behavior = behavior
    }

    public func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        if let failure = behavior.failConnect {
            throw failure
        }
        _ = (username, auth, hostKeyPolicy)
        return MockSSHSession(endpoint: endpoint, behavior: behavior)
    }
}

/// Mock 会话：把命令映射到确定性输出。
///
/// `@unchecked Sendable`：存活标志是可变的，由 `livenessLock` 保护（同 `CitadelSession`）。
final class MockSSHSession: SSHSession, @unchecked Sendable {
    private let endpoint: SSHEndpoint
    private let behavior: MockSSHTransport.Behavior
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>

    /// 存活标志。测试要从外部翻它来模拟「后台期间 socket 被回收」，
    /// 而 `SSHSession` 是 `Sendable`，故加锁保护（同 `HostKeyStore` 的做法）。
    private let livenessLock = NSLock()
    private var alive = true

    var isConnected: Bool {
        livenessLock.withLock { alive }
    }

    init(endpoint: SSHEndpoint, behavior: MockSSHTransport.Behavior) {
        self.endpoint = endpoint
        self.behavior = behavior
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    /// 模拟底层通道死亡（App 退后台被系统回收 socket）：会话对象还在，但已不可用。
    func simulateDisconnect() {
        livenessLock.withLock { alive = false }
    }

    /// 等到会话被关闭。连接池的关闭是 fire-and-forget 的 `Task`，不能同步读。
    func waitUntilClosed(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if livenessLock.withLock({ closed }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private var closed = false

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        _ = timeout
        let response = resolve(command)
        return ExecResult(
            exitCode: response.exitCode,
            stdout: Data(response.stdout.utf8),
            stderr: Data(response.stderr.utf8)
        )
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        let response = resolve(command)
        let delay = behavior.streamChunkDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for line in response.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                    if delay > .zero {
                        try? await Task.sleep(for: delay)
                    }
                    continuation.yield(Data((line + "\n").utf8))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        let response = resolve(command)
        let delay = response.streamChunkDelay ?? behavior.streamChunkDelay
        let timeoutError = SSHError.commandTimeout(
            endpoint: endpoint,
            seconds: Self.roundedUpSeconds(timeout)
        )
        let (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let cancellation = SSHCommandStreamCancellation()
        let resultTask = Task { [cancellation, response, delay, timeout, timeoutError] in
            defer { cancellation.finish() }
            do {
                let result = try await withThrowingTaskGroup(of: ExecResult.self) { group in
                    group.addTask {
                        let chunks = response.streamChunks ?? Self.lineChunks(response.stdout)
                        var stdout = Data()
                        for (index, chunk) in chunks.enumerated() {
                            if index > 0, delay > .zero {
                                try await Task.sleep(for: delay)
                            }
                            stdout.append(chunk)
                            continuation.yield(chunk)
                        }
                        if let failure = response.streamFailure {
                            throw failure
                        }
                        return ExecResult(
                            exitCode: response.exitCode,
                            stdout: stdout,
                            stderr: Data(response.stderr.utf8)
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw timeoutError
                    }
                    defer { group.cancelAll() }
                    for try await result in group {
                        return result
                    }
                    throw timeoutError
                }
                continuation.finish()
                return result
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        cancellation.install(resultTask)
        continuation.onTermination = { [cancellation] _ in
            cancellation.cancel()
        }
        return SSHCommandStream(output: output) {
            try await resultTask.value
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        _ = term
        return MockShellChannel()
    }

    /// 每会话一颗内存文件树，编辑/新建在会话内留存。
    private let fileSystem = MockRemoteFileSystem()

    func sftp() async throws -> any RemoteFileSystem {
        fileSystem
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        _ = target
        return MockTunnel()
    }

    func close() async {
        livenessLock.withLock {
            alive = false
            closed = true
        }
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }

    /// 命令 → 响应。测试显式覆盖 > 动态响应器 > 内置脚本 > command not found。
    private func resolve(_ command: String) -> MockSSHTransport.CommandResponse {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom = behavior.commandResponses[trimmed] {
            return custom
        }
        // `SSHSession.execScript` 会把脚本包装成 `sh/bash/zsh -c '…'`。
        // 演示模式仍应按脚本内容命中确定性假输出，而不是把解释器本身当成未知命令。
        if let script = unwrapInterpreterInvocation(trimmed) {
            return resolve(script)
        }
        if let dynamic = behavior.dynamicResponder?(command, endpoint) {
            return dynamic
        }
        return Self.builtinScript[trimmed] ?? Self.builtinScript[firstWord(trimmed)] ?? .init(
            stderr: "\(firstWord(trimmed)): command not found",
            exitCode: 127
        )
    }

    private func firstWord(_ command: String) -> String {
        String(command.split(separator: " ").first ?? "")
    }

    private func unwrapInterpreterInvocation(_ command: String) -> String? {
        let prefixes = ["sh -c '", "bash -c '", "zsh -c '"]
        guard let prefix = prefixes.first(where: { command.hasPrefix($0) }), command.last == "'" else {
            return nil
        }
        var script = String(command.dropFirst(prefix.count))
        script.removeLast()
        return script.replacingOccurrences(of: "'\\''", with: "'")
    }

    private static func lineChunks(_ output: String) -> [Data] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map {
            Data(($0 + "\n").utf8)
        }
    }

    private static func roundedUpSeconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = Int(components.seconds)
        return components.attoseconds > 0 ? max(1, seconds + 1) : max(1, seconds)
    }
}

// MARK: - 内置脚本

extension MockSSHSession {
    /// 20 个常见运维命令的确定性假输出。整键优先匹配，其次按首词。
    static let builtinScript: [String: MockSSHTransport.CommandResponse] = [
        "uname -s": .init(stdout: "Linux"),
        "uname -a": .init(stdout: "Linux demo 6.1.0-demo #1 SMP x86_64 GNU/Linux"),
        "hostname": .init(stdout: "demo-host"),
        "whoami": .init(stdout: "root"),
        "pwd": .init(stdout: "/root"),
        "uptime": .init(stdout: " 14:32:01 up 12 days,  3:14,  1 user,  load average: 0.18, 0.24, 0.21"),
        "cat /etc/os-release": .init(stdout: """
        NAME="Ubuntu"
        VERSION="24.04 LTS (Noble Numbat)"
        ID=ubuntu
        PRETTY_NAME="Ubuntu 24.04 LTS"
        """),
        "df -h": .init(stdout: """
        Filesystem      Size  Used Avail Use% Mounted on
        /dev/vda1        40G   18G   21G  48% /
        tmpfs           2.0G     0  2.0G   0% /dev/shm
        """),
        "free -m": .init(stdout: """
                       total        used        free      shared  buff/cache   available
        Mem:            3936        2401         412          52        1123         1234
        Swap:              0           0           0
        """),
        "ls": .init(stdout: "app.log  config.yml  data  scripts"),
        "ls -la": .init(stdout: """
        total 24
        drwxr-xr-x 4 root root 4096 Jul 21 14:00 .
        drwxr-xr-x 6 root root 4096 Jul 20 09:12 ..
        -rw-r--r-- 1 root root 2048 Jul 21 13:58 app.log
        -rw-r--r-- 1 root root  512 Jul 19 10:00 config.yml
        """),
        "docker ps": .init(stdout: """
        CONTAINER ID   IMAGE               STATUS         PORTS                  NAMES
        a1b2c3d4e5f6   nginx:1.25-alpine   Up 3 days      0.0.0.0:80->80/tcp     nginx-proxy
        f6e5d4c3b2a1   redis:7             Up 12 days     6379/tcp               redis-cache
        """)
    ]
}

// MARK: - 通道占位

final class MockShellChannel: ShellChannel {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
        continuation.yield(Data("demo-host:~$ ".utf8))
    }

    func write(_ bytes: Data) async throws {
        // 真实 PTY 中 Ctrl+U 由 shell 行编辑器处理：清空当前输入并重绘提示符。
        // Mock Shell 也模拟这一语义，避免演示/UI 验收时把控制码原样回显成“无反应”。
        if bytes == Data([0x15]) {
            continuation.yield(Data("\r\u{1B}[2Kdemo-host:~$ ".utf8))
            return
        }
        // 回显演示：把输入原样吐回
        continuation.yield(bytes)
    }

    func resize(_ size: TermSize) async throws {
        _ = size
    }

    func close() async {
        continuation.finish()
    }
}

final class MockTunnel: SSHTunnel {
    func close() async {}
}
