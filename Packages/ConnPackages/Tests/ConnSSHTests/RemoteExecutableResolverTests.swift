import ConnKit
import Foundation
import Testing
@testable import ConnSSH

@Suite("Remote executable resolver")
struct RemoteExecutableResolverTests {
    @Test("通过远端默认登录 Shell 发现用户 PATH 中的多个可执行文件")
    func resolvesExecutablesFromLoginShellEnvironment() async throws {
        let commands = ResolverCommandRecorder()
        let resolver = RemoteExecutableResolver(nonceGenerator: { "LOGIN" })
        let session = try await makeSession(recorder: commands) { command in
            guard command.contains("-i -l -c") else { return nil }
            return .init(stdout: resolverProbeOutput(
                nonce: "LOGIN",
                path: "/custom tools/bin:/usr/bin",
                executables: ["/custom tools/bin/zellij", "/usr/bin/tmux"],
                prefix: "startup banner\n",
                suffix: "\nprompt noise"
            ))
        }

        let resolved = try await resolver.resolve(["zellij", "tmux"], on: session)

        #expect(resolved == [
            "zellij": "/custom tools/bin/zellij",
            "tmux": "/usr/bin/tmux"
        ])
        let command = try #require(commands.values.first)
        #expect(command.contains("conn_login_shell=${SHELL:-}"))
        #expect(command.contains("\"$conn_login_shell\" -i -l -c"))
        #expect(command.contains("__CONN_EXECUTABLES_v1_BEGIN_LOGIN__"))
        #expect(command.contains("${conn_dir}/zellij"))
        #expect(!command.contains("/opt/homebrew"))
        #expect(!command.contains("/usr/local/bin"))
    }

    @Test("同一 SSH Session 复用已捕获的 PATH 而不重复启动登录 Shell")
    func reusesCapturedPathForSameSession() async throws {
        let commands = ResolverCommandRecorder()
        let resolver = RemoteExecutableResolver(nonceGenerator: { "CACHE" })
        let session = try await makeSession(recorder: commands) { command in
            if command.contains("-i -l -c") {
                return .init(stdout: resolverProbeOutput(
                    nonce: "CACHE",
                    path: "/custom tools/bin:/usr/bin",
                    executables: ["/custom tools/bin/zellij"]
                ))
            }
            if command.contains("${conn_dir}/tmux") {
                return .init(stdout: resolverProbeOutput(
                    nonce: "CACHE",
                    path: "/custom tools/bin:/usr/bin",
                    executables: ["/usr/bin/tmux"]
                ))
            }
            return nil
        }

        #expect(try await resolver.resolve("zellij", on: session) == "/custom tools/bin/zellij")
        #expect(try await resolver.resolve("tmux", on: session) == "/usr/bin/tmux")

        #expect(commands.values.count == 2)
        #expect(commands.values.filter { $0.contains("-i -l -c") }.count == 1)
        let cachedProbe = try #require(commands.values.last)
        #expect(cachedProbe.contains("PATH='/custom tools/bin:/usr/bin'; export PATH"))
    }

    @Test("登录 Shell 探测失败时回退当前 SSH exec 环境")
    func fallsBackToCurrentExecEnvironment() async throws {
        let commands = ResolverCommandRecorder()
        let resolver = RemoteExecutableResolver(nonceGenerator: { "FALLBACK" })
        let session = try await makeSession(recorder: commands) { command in
            if command.contains("-i -l -c") {
                return .init(stderr: "profile failed", exitCode: 1)
            }
            return .init(stdout: resolverProbeOutput(
                nonce: "FALLBACK",
                path: "/usr/bin:/bin",
                executables: ["/usr/bin/tmux"]
            ))
        }

        let resolved = try await resolver.resolve("tmux", on: session)

        #expect(resolved == "/usr/bin/tmux")
        #expect(commands.values.count == 2)
        #expect(commands.values[0].contains("-i -l -c"))
        #expect(!commands.values[1].contains("-i -l -c"))
    }

    @Test("未安装的可执行文件返回 nil 并缓存有效 PATH")
    func missingExecutableReturnsNil() async throws {
        let commands = ResolverCommandRecorder()
        let resolver = RemoteExecutableResolver(nonceGenerator: { "MISSING" })
        let session = try await makeSession(recorder: commands) { _ in
            .init(stdout: resolverProbeOutput(
                nonce: "MISSING",
                path: "/usr/bin:/bin",
                executables: [nil]
            ))
        }

        #expect(try await resolver.resolve("zellij", on: session) == nil)
        #expect(commands.values.count == 1)
    }

    @Test("拒绝路径、选项和控制字符形式的可执行文件名且不发远端命令")
    func rejectsUnsafeExecutableNames() async throws {
        let commands = ResolverCommandRecorder()
        let resolver = RemoteExecutableResolver(nonceGenerator: { "INVALID" })
        let session = try await makeSession(recorder: commands) { _ in .init() }

        for name in ["", "../zellij", "/bin/zellij", "-zellij", "zellij\nother"] {
            await #expect(throws: RemoteExecutableResolutionError.invalidExecutableName) {
                try await resolver.resolve(name, on: session)
            }
        }
        #expect(commands.values.isEmpty)
    }
}

private func makeSession(
    recorder: ResolverCommandRecorder,
    responder: @escaping @Sendable (String) -> MockSSHTransport.CommandResponse?
) async throws -> any SSHSession {
    var behavior = MockSSHTransport.Behavior()
    behavior.dynamicResponder = { command, _ in
        recorder.record(command)
        return responder(command)
    }
    return try await MockSSHTransport(behavior: behavior).connect(
        .init(host: "resolver.test"),
        username: "tester",
        auth: .password("secret"),
        hostKeyPolicy: .tofu
    )
}

private func resolverProbeOutput(
    nonce: String,
    path: String,
    executables: [String?],
    prefix: String = "",
    suffix: String = ""
) -> String {
    var lines = [
        "__CONN_EXECUTABLES_v1_BEGIN_\(nonce)__",
        path
    ]
    for (index, executable) in executables.enumerated() {
        lines.append("__CONN_EXECUTABLES_v1_ITEM_\(index)_\(nonce)__")
        lines.append(executable ?? "")
    }
    lines.append("__CONN_EXECUTABLES_v1_END_\(nonce)__")
    return prefix + lines.joined(separator: "\n") + suffix
}

private final class ResolverCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ command: String) {
        lock.lock()
        storage.append(command)
        lock.unlock()
    }
}
