import Testing
@testable import ConnSSH

@Suite("ReconnectPolicy — 指数退避")
struct ReconnectPolicyTests {
    @Test("默认策略：1s / 2s / 4s 共 3 次（技术方案 §4.1）")
    func defaultBackoff() {
        let delays = ReconnectPolicy().delays()
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("自定义次数与基数")
    func customPolicy() {
        let delays = ReconnectPolicy(maxAttempts: 4, baseDelay: .milliseconds(500)).delays()
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("零次尝试返回空序列")
    func zeroAttempts() {
        #expect(ReconnectPolicy(maxAttempts: 0).delays().isEmpty)
    }
}
