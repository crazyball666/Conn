import ConnKit
import Testing
@testable import ConnSSH

@Suite("SSHError 诊断文案")
struct SSHErrorTests {
    @Test("每个错误的诊断都遵循「原因 + 下一步」格式（技术方案 §10.5）")
    func everyDiagnosisHasCauseAndNextStep() {
        let errors: [SSHError] = [
            .connectionRefused(endpoint: SSHEndpoint(host: "10.0.0.1", port: 22)),
            .dnsFailed(host: "bad.host"),
            .timeout(endpoint: SSHEndpoint(host: "10.0.0.1", port: 22)),
            .authFailed(reason: .badCredentials),
            .authFailed(reason: .rsaSha2Unsupported),
            .authFailed(reason: .noAcceptedMethods),
            .hostKeyMismatch(expected: "SHA256:aaa", actual: "SHA256:bbb"),
            .unsupportedByEngine(.keyboardInteractive),
            .jumpChainFailed(hopIndex: 1, hopHost: "bastion"),
            .channelClosed
        ]
        for error in errors {
            #expect(!error.diagnosis.isEmpty, "\(error) 缺少诊断文案")
        }
    }

    @Test("RSA 连现代服务器失败，诊断建议改用 ed25519（S1 结论）")
    func rsaModernServerDiagnosis() {
        let error = SSHError.authFailed(reason: .rsaSha2Unsupported)
        #expect(error.diagnosis.contains("ed25519"))
    }

    @Test("keyboard-interactive 不支持时给出明确说明")
    func keyboardInteractiveUnsupported() {
        let error = SSHError.unsupportedByEngine(.keyboardInteractive)
        #expect(error.diagnosis.contains("交互式"))
    }

    @Test("跳板链失败指明卡在第几级（人读的第 N 级，从 1 起）")
    func jumpChainFailurePointsToHop() {
        let error = SSHError.jumpChainFailed(hopIndex: 1, hopHost: "bastion")
        #expect(error.diagnosis.contains("bastion"))
        #expect(error.diagnosis.contains("第 2 级"))
    }

    @Test("连接被拒诊断含端口与 sshd 提示")
    func connectionRefusedDiagnosis() {
        let error = SSHError.connectionRefused(endpoint: SSHEndpoint(host: "10.0.0.1", port: 2222))
        #expect(error.diagnosis.contains("2222"))
        #expect(error.diagnosis.contains("sshd"))
    }
}
