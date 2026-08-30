import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import Conn

/// ConnectionTester 的诊断步骤映射逻辑。
///
/// 用 MockSSHTransport 注入各类失败，验证 SSHError → 步骤点亮的映射正确。
/// 真实网络路径由包级 CitadelIntegrationTests（连 Docker）覆盖，此处只测映射。
@MainActor
struct ConnectionTesterTests {
    private func host() -> Host {
        Host(name: "h", address: "10.0.0.1", username: "root")
    }

    @Test("连接成功 → 四步全绿，succeeded")
    func successAllStepsOK() async {
        let tester = ConnectionTester(transport: MockSSHTransport())
        await tester.run(host: host(), username: "root", auth: .password("x"))
        #expect(tester.succeeded)
        #expect(tester.steps.allSatisfy { $0.state == .ok })
    }

    @Test("DNS 失败 → 第 1 步（解析地址）失败")
    func dnsFailureAtStep0() async {
        let transport = MockSSHTransport(behavior: .init(failConnect: .dnsFailed(host: "bad")))
        let tester = ConnectionTester(transport: transport)
        await tester.run(host: host(), username: "root", auth: .password("x"))
        #expect(tester.steps[0].state == .failed)
        #expect(tester.steps[0].detail != nil)
        #expect(!tester.succeeded)
    }

    @Test("连接被拒 → 地址步过、端口步失败")
    func refusedAtStep1() async {
        let transport = MockSSHTransport(behavior: .init(
            failConnect: .connectionRefused(endpoint: SSHEndpoint(host: "10.0.0.1", port: 22))
        ))
        let tester = ConnectionTester(transport: transport)
        await tester.run(host: host(), username: "root", auth: .password("x"))
        #expect(tester.steps[0].state == .ok)
        #expect(tester.steps[1].state == .failed)
    }

    @Test("认证失败 → 地址/端口过、认证步失败，诊断含 ed25519（RSA 场景）")
    func authFailureAtStep2() async {
        let transport = MockSSHTransport(behavior: .init(
            failConnect: .authFailed(reason: .rsaSha2Unsupported)
        ))
        let tester = ConnectionTester(transport: transport)
        await tester.run(host: host(), username: "root", auth: .password("x"))
        #expect(tester.steps[0].state == .ok)
        #expect(tester.steps[1].state == .ok)
        #expect(tester.steps[2].state == .failed)
        #expect(tester.steps[2].detail?.localizedCaseInsensitiveContains("ed25519") == true)
    }

    @Test("指纹不符 → 前三步过、指纹步失败")
    func hostKeyMismatchAtStep3() async {
        let transport = MockSSHTransport(behavior: .init(
            failConnect: .hostKeyMismatch(expected: "SHA256:a", actual: "SHA256:b")
        ))
        let tester = ConnectionTester(transport: transport)
        await tester.run(host: host(), username: "root", auth: .password("x"))
        #expect(tester.steps[0].state == .ok)
        #expect(tester.steps[2].state == .ok)
        #expect(tester.steps[3].state == .failed)
    }
}
