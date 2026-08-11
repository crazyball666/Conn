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
            for interpreter in ShellInterpreter.allCases {
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

    @Test("POSIX 解释器探测保留发现路径的标准输出")
    func posixInterpreterProbePreservesDiscoveredPath() throws {
        let provider = POSIXScriptExecutionProvider()

        for interpreter in ShellInterpreter.allCases {
            let command = provider.interpreterProbeCommand(for: interpreter)
            #expect(command.contains("command -v \(interpreter.rawValue)"))
            #expect(!command.contains("/dev/null"))
        }

        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", provider.interpreterProbeCommand(for: .sh)]
        process.standardOutput = standardOutput
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0)
        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("POSIX invocation 将含单引号的完整多行脚本作为一个参数转义")
    func posixInvocationQuotesCompleteScript() throws {
        let provider = POSIXScriptExecutionProvider()
        let script = "printf '%s\\n' \"$HOME\"\necho 'done'"
        let expected = "bash -c 'printf '\\''%s\\n'\\'' \"$HOME\"\necho '\\''done'\\'''"

        #expect(try provider.invocation(for: script, interpreter: .bash) == expected)
    }

    @Test("直接调用 POSIX provider 时拒绝未声明支持的解释器")
    func posixInvocationRejectsUnsupportedInterpreter() {
        let provider = POSIXScriptExecutionProvider(supportedInterpreters: [.sh])

        #expect(throws: RemoteScriptExecutionError.unsupportedInterpreter(.bash)) {
            try provider.invocation(for: "echo test", interpreter: .bash)
        }
    }
}

private struct TestScriptExecutionProvider: RemoteScriptExecutionProvider {
    let family = RemoteScriptFamily.posix
    let supportedPlatforms: Set<RemotePlatformKind>
    let supportedInterpreters: Set<ShellInterpreter>

    func interpreterProbeCommand(for interpreter: ShellInterpreter) -> String {
        "probe \(interpreter.rawValue)"
    }

    func invocation(for script: String, interpreter: ShellInterpreter) throws -> String {
        "\(interpreter.rawValue):\(script)"
    }
}
