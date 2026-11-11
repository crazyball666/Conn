import Testing
@testable import ConnSSH

@Suite("连接重试策略")
struct ConnectionRetryPolicyTests {
    private let endpoint = SSHEndpoint(host: "100.64.0.1", port: 22)

    @Test("网络类错误允许重试")
    func transientNetworkErrorsRetry() {
        #expect(ConnectionRetryPolicy.isTransient(SSHError.connectionRefused(endpoint: endpoint)))
        #expect(ConnectionRetryPolicy.isTransient(SSHError.timeout(endpoint: endpoint)))
        #expect(ConnectionRetryPolicy.isTransient(SSHError.channelClosed))
    }

    @Test("认证、指纹和配置错误不重试")
    func nonTransientErrorsFailImmediately() {
        #expect(!ConnectionRetryPolicy.isTransient(SSHError.authFailed(reason: .badCredentials)))
        #expect(!ConnectionRetryPolicy.isTransient(
            SSHError.hostKeyMismatch(endpoint: endpoint, expected: "a", actual: "b")
        ))
        #expect(!ConnectionRetryPolicy.isTransient(SSHError.privateNetworkUnavailable(
            profileID: "p",
            reason: "down"
        )))
        #expect(!ConnectionRetryPolicy.isTransient(PrivateNetworkTestError.unexpected))
    }

    @Test("最多三次尝试，退避为 300ms / 800ms")
    func boundedAttemptsAndBackoff() {
        #expect(ConnectionRetryPolicy.maximumAttempts == 3)
        #expect(ConnectionRetryPolicy.delay(afterFailedAttempt: 1) == .milliseconds(300))
        #expect(ConnectionRetryPolicy.delay(afterFailedAttempt: 2) == .milliseconds(800))
        #expect(ConnectionRetryPolicy.delay(afterFailedAttempt: 3) == .zero)
    }
}

private enum PrivateNetworkTestError: Error {
    case unexpected
}
