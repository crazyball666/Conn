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
            .commandTimeout(endpoint: SSHEndpoint(host: "10.0.0.1", port: 22), seconds: 30),
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

    @Test("RSA 连现代服务器失败，诊断建议改用 Ed25519（S1 结论）")
    func rsaModernServerDiagnosis() {
        let error = SSHError.authFailed(reason: .rsaSha2Unsupported)
        #expect(error.diagnosis.localizedCaseInsensitiveContains("Ed25519"))
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

    @Test("命令超时的诊断区别于连接超时：说清仍在运行、不再让用户查防火墙")
    func commandTimeoutDiagnosisDiffersFromConnectionTimeout() {
        let endpoint = SSHEndpoint(host: "10.0.0.1", port: 22)
        let commandTimeout = SSHError.commandTimeout(endpoint: endpoint, seconds: 600)
        let connectTimeout = SSHError.timeout(endpoint: endpoint)

        #expect(commandTimeout.diagnosis != connectTimeout.diagnosis)
        // 连接超时才该提防火墙；命令超时时连接本来就是通的，提防火墙是误导
        #expect(connectTimeout.diagnosis.contains("防火墙"))
        #expect(!commandTimeout.diagnosis.contains("防火墙"))
        // 必须告诉用户超时不终止远端命令（见 CitadelSession.exec）
        #expect(commandTimeout.diagnosis.contains("仍在远程主机上运行"))
        // 带上主机与实际用的秒数，用户才知道是哪台、卡了多久
        #expect(commandTimeout.diagnosis.contains("10.0.0.1"))
        #expect(commandTimeout.diagnosis.contains("600"))
    }

    @Test("连接被拒诊断含端口与 sshd 提示")
    func connectionRefusedDiagnosis() {
        let error = SSHError.connectionRefused(endpoint: SSHEndpoint(host: "10.0.0.1", port: 2222))
        #expect(error.diagnosis.contains("2222"))
        #expect(error.diagnosis.contains("sshd"))
    }
}
