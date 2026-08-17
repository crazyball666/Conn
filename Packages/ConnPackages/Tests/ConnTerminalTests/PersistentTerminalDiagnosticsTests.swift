import ConnMultiplexer
import Testing
@testable import ConnTerminal

@Suite("Persistent terminal diagnostics")
struct PersistentTerminalDiagnosticsTests {
    @Test("常见不可用原因提供产品文案而不是 Swift 错误类型")
    func commonAvailabilityFailuresAreUserFacing() {
        let errors: [PersistentTerminalError] = [
            .unsupportedPlatform,
            .executableMissing,
            .invalidConfiguration,
            .socketPermissionDenied,
            .serverUnavailable,
        ]

        for error in errors {
            #expect(!error.userFacingDiagnosis.isEmpty)
            #expect(!error.userFacingDiagnosis.contains("PersistentTerminalError"))
            #expect(!error.userFacingDiagnosis.contains("operation couldn’t be completed"))
        }
    }

    @Test("带上下文的错误保留 provider 与远端拒绝原因")
    func contextualFailuresKeepUsefulDetails() {
        #expect(
            PersistentTerminalError.providerNotRegistered("zellij").userFacingDiagnosis
                .contains("zellij")
        )
        #expect(
            PersistentTerminalError.commandRejected("duplicate session").userFacingDiagnosis
                .contains("duplicate session")
        )
    }

    @Test("运行时持久终端和 tmux 握手错误使用同一诊断入口")
    func runtimeFailuresUseTerminalDiagnostics() {
        #expect(
            terminalUserFacingDiagnosis(PersistentTerminalError.transportClosed)
                == PersistentTerminalError.transportClosed.userFacingDiagnosis
        )
        #expect(
            terminalUserFacingDiagnosis(TmuxProviderError.attachmentHandshakeFailed)
                .contains("握手")
        )
    }
}
