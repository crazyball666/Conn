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

        public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
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
final class MockSSHSession: SSHSession {
    private let endpoint: SSHEndpoint
    private let behavior: MockSSHTransport.Behavior
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>

    init(endpoint: SSHEndpoint, behavior: MockSSHTransport.Behavior) {
        self.endpoint = endpoint
        self.behavior = behavior
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

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

    func openShell(term: TermSize) async throws -> any ShellChannel {
        _ = term
        return MockShellChannel()
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        _ = target
        return MockTunnel()
    }

    func close() async {
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }

    /// 命令 → 响应。测试显式覆盖 > 动态响应器 > 内置脚本 > command not found。
    private func resolve(_ command: String) -> MockSSHTransport.CommandResponse {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom = behavior.commandResponses[trimmed] {
            return custom
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
