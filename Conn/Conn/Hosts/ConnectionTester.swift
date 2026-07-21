import ConnKit
import ConnSSH
import Foundation

/// 连接诊断的分步结果（原型 S16 的四步）。
struct DiagnosticStep: Identifiable, Sendable {
    enum State: Sendable {
        case pending, running, ok, failed
    }

    let id = UUID()
    let title: String
    var state: State
    /// 失败时的可执行说明（来自 SSHError.diagnosis）。
    var detail: String?
}

/// 连接测试器：尝试建立连接，把结果映射为诊断步骤。
///
/// 本 Phase 用「尝试连接 + 错误分类」的实用版：`SSHError` 已按 DNS/端口/认证/
/// 指纹细分，据此点亮对应步骤。更细的独立探测（单独 TCP 拨测）留待 Phase 7 拨测。
@MainActor
@Observable
final class ConnectionTester {
    private(set) var steps: [DiagnosticStep]
    private(set) var isRunning = false
    private(set) var succeeded = false

    private let transport: any SSHTransport

    init(transport: any SSHTransport) {
        self.transport = transport
        steps = Self.freshSteps()
    }

    private static func freshSteps() -> [DiagnosticStep] {
        [
            DiagnosticStep(title: "解析主机地址", state: .pending),
            DiagnosticStep(title: "连接端口", state: .pending),
            DiagnosticStep(title: "身份认证", state: .pending),
            DiagnosticStep(title: "校验主机指纹", state: .pending)
        ]
    }

    /// 对给定主机与认证材料跑一次诊断。
    func run(host: Host, username: String, auth: SSHAuth) async {
        isRunning = true
        succeeded = false
        steps = Self.freshSteps()

        // 全部标记为 running 前，先点亮第一步
        setState(.running, at: 0)

        do {
            let endpoint = SSHEndpoint(host: host.address, port: host.port)
            let session = try await transport.connect(
                endpoint, username: username, auth: auth, hostKeyPolicy: .tofu
            )
            // 连接成功 = 四步全过
            markAllOK()
            await session.close()
            succeeded = true
        } catch let error as SSHError {
            applyFailure(error)
        } catch {
            // 非 SSHError 的兜底
            fail(at: 1, detail: "连接失败：\(error.localizedDescription)")
        }

        isRunning = false
    }

    /// 把 SSHError 归位到具体失败步骤，之前的步骤标记为通过。
    private func applyFailure(_ error: SSHError) {
        switch error {
        case .dnsFailed:
            fail(at: 0, detail: error.diagnosis)
        case .connectionRefused, .timeout:
            passUpTo(0)
            fail(at: 1, detail: error.diagnosis)
        case .authFailed, .unsupportedByEngine:
            passUpTo(1)
            fail(at: 2, detail: error.diagnosis)
        case .hostKeyMismatch:
            passUpTo(2)
            fail(at: 3, detail: error.diagnosis)
        case .jumpChainFailed, .channelClosed:
            passUpTo(0)
            fail(at: 1, detail: error.diagnosis)
        }
    }

    private func setState(_ state: DiagnosticStep.State, at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = state
    }

    private func passUpTo(_ index: Int) {
        for step in 0 ... index where steps.indices.contains(step) {
            steps[step].state = .ok
        }
    }

    private func fail(at index: Int, detail: String) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = .failed
        steps[index].detail = detail
    }

    private func markAllOK() {
        for step in steps.indices {
            steps[step].state = .ok
        }
    }
}
