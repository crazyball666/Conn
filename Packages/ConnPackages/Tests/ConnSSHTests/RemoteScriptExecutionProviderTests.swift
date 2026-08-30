import ConnKit
import Foundation
import Testing
@testable import ConnSSH

@Suite("Remote script execution providers")
struct RemoteScriptExecutionProviderTests {
    @Test("默认 registry 为 Linux 和 macOS 的全部 POSIX 解释器选择 provider")
    func defaultRegistrySelectsPOSIXProviders() throws {
        let registry = RemoteScriptExecutionProviderRegistry.default

        for platform in [RemotePlatformKind.linux, .macOS] {
            for interpreter in POSIXScriptExecutionProvider.supportedInterpreterWhitelist {
                let provider = try #require(registry.provider(
                    for: platform,
                    interpreter: interpreter
                ))

                #expect(provider.family == .posix)
            }
        }
    }

    @Test("默认 registry 不为 Windows 或 Unknown 回退到 POSIX provider")
    func defaultRegistryDoesNotFallbackForUnsupportedPlatforms() {
        let registry = RemoteScriptExecutionProviderRegistry.default

        for platform in [RemotePlatformKind.windows, .unknown] {
            for interpreter in ShellInterpreter.allCases {
                #expect(registry.provider(for: platform, interpreter: interpreter) == nil)
            }
        }
    }

    @Test("POSIX provider 使用固定解释器白名单并限制注入集合")
    func posixInterpreterSupportIsPinned() {
        let whitelist: Set<ShellInterpreter> = [.sh, .bash, .zsh]
        let provider = POSIXScriptExecutionProvider(
            supportedInterpreters: Set(ShellInterpreter.allCases)
        )

        #expect(POSIXScriptExecutionProvider.supportedInterpreterWhitelist == whitelist)
        #expect(POSIXScriptExecutionProvider().supportedInterpreters == whitelist)
        #expect(provider.supportedInterpreters == whitelist)
        #expect(provider.supportedInterpreters.isSubset(of: whitelist))
    }

    @Test("注入 registry 时同时按平台和解释器选择 provider")
    func injectedRegistryMatchesPlatformAndInterpreter() throws {
        let provider = TestScriptExecutionProvider(
            supportedPlatforms: [.macOS],
            supportedInterpreters: [.bash]
        )
        let registry = RemoteScriptExecutionProviderRegistry(providers: [provider])

        #expect(try #require(registry.provider(for: .macOS, interpreter: .bash)).family == .posix)
        #expect(registry.provider(for: .linux, interpreter: .bash) == nil)
        #expect(registry.provider(for: .macOS, interpreter: .sh) == nil)
    }

    @Test("POSIX 解释器通过共享登录 Shell 环境解析绝对路径")
    func posixInterpreterUsesSharedExecutableResolver() async throws {
        let commands = ScriptProviderCommandRecorder()
        let resolver = RemoteExecutableResolver(nonceGenerator: { "SCRIPT" })
        var behavior = MockSSHTransport.Behavior()
        behavior.dynamicResponder = { command, _ in
            commands.record(command)
            return .init(stdout: [
                "__CONN_EXECUTABLES_v1_BEGIN_SCRIPT__",
                "/custom/bin:/usr/bin:/bin",
                "__CONN_EXECUTABLES_v1_ITEM_0_SCRIPT__",
                "/custom/bin/bash",
                "__CONN_EXECUTABLES_v1_END_SCRIPT__",
            ].joined(separator: "\n"))
        }
        let session = try await MockSSHTransport(behavior: behavior).connect(
            .init(host: "script.test"),
            username: "tester",
            auth: .password("secret"),
            hostKeyPolicy: .tofu
        )
        let provider = POSIXScriptExecutionProvider(executableResolver: resolver)

        let path = try await provider.resolveExecutable(for: .bash, on: session)

        #expect(path == "/custom/bin/bash")
        let command = try #require(commands.values.first)
        #expect(command.contains("-i -l -c"))
        #expect(!command.contains("command -v"))
    }

    @Test("POSIX invocation 将含单引号的完整多行脚本作为一个参数转义")
    func posixInvocationQuotesCompleteScript() throws {
        let provider = POSIXScriptExecutionProvider()
        let script = "printf '%s\\n' \"$HOME\"\necho 'done'"
        let expected = "/bin/bash -c 'printf '\\''%s\\n'\\'' \"$HOME\"\necho '\\''done'\\'''"

        #expect(try provider.invocation(
            for: script,
            interpreter: .bash,
            resolvedExecutablePath: "/bin/bash"
        ) == expected)
    }

    @Test("直接调用 POSIX provider 时拒绝未声明支持的解释器")
    func posixInvocationRejectsUnsupportedInterpreter() {
        let provider = POSIXScriptExecutionProvider(supportedInterpreters: [.sh])

        #expect(throws: RemoteScriptExecutionError.unsupportedInterpreter(.bash)) {
            try provider.invocation(
                for: "echo test",
                interpreter: .bash,
                resolvedExecutablePath: "/bin/bash"
            )
        }
    }

    @Test("prepared runtime 固定已验证的绝对解释器路径并安全转义")
    func preparedRuntimePinsResolvedExecutable() throws {
        let provider = POSIXScriptExecutionProvider()
        let runtime = try provider.prepareRuntime(
            resolvedExecutablePath: "/opt/Ops Tools/owner's sh",
            interpreter: .sh
        )

        #expect(runtime.family == .posix)
        #expect(runtime.interpreter == .sh)
        #expect(runtime.resolvedExecutablePath == "/opt/Ops Tools/owner's sh")
        #expect(
            try runtime.invocation(for: "printf '%s\\n' ok")
                == "'/opt/Ops Tools/owner'\\''s sh' -c 'printf '\\''%s\\n'\\'' ok'"
        )
    }

    @Test("prepared runtime 拒绝不可信或非绝对解释器路径", arguments: [
        "", "sh", "./sh", "/bin/sh\nmalicious", "/bin/sh\0malicious", "/bin/\tsh",
    ])
    func preparedRuntimeRejectsInvalidPath(path: String) {
        let provider = POSIXScriptExecutionProvider()

        #expect(throws: RemoteScriptExecutionError.invalidResolvedExecutablePath) {
            try provider.prepareRuntime(resolvedExecutablePath: path, interpreter: .sh)
        }
    }

    @Test("prepared runtime 仍受 provider 的解释器白名单约束")
    func preparedRuntimeRejectsUnsupportedInterpreter() {
        let provider = POSIXScriptExecutionProvider(supportedInterpreters: [.sh])

        #expect(throws: RemoteScriptExecutionError.unsupportedInterpreter(.bash)) {
            try provider.prepareRuntime(resolvedExecutablePath: "/bin/bash", interpreter: .bash)
        }
    }
}

private final class ScriptProviderCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ command: String) {
        lock.withLock { storage.append(command) }
    }
}

private struct TestScriptExecutionProvider: RemoteScriptExecutionProvider {
    let family = RemoteScriptFamily.posix
    let supportedPlatforms: Set<RemotePlatformKind>
    let supportedInterpreters: Set<ShellInterpreter>

    func resolveExecutable(
        for interpreter: ShellInterpreter,
        on session: any SSHSession
    ) async throws -> String? {
        let result = try await session.exec("probe \(interpreter.rawValue)")
        guard result.isSuccess else { return nil }
        return result.stdoutText
    }

    func invocation(
        for script: String,
        interpreter: ShellInterpreter,
        resolvedExecutablePath: String
    ) throws -> String {
        _ = resolvedExecutablePath
        return "\(interpreter.rawValue):\(script)"
    }
}
