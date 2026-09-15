import ConnKit
import Testing

@Suite("SSH 代理配置")
struct SSHProxyConfigurationTests {
    @Test("有效的 SOCKS5 配置可通过校验")
    func validConfiguration() {
        let configuration = SSHProxyConfiguration(
            kind: .socks5,
            host: "proxy.example.com",
            port: 1080,
            authentication: .password,
            username: "proxy-user"
        )

        #expect(configuration.validationError == nil)
    }

    @Test("代理配置拒绝无效端口和缺失认证用户名")
    func invalidConfiguration() {
        let invalidPort = SSHProxyConfiguration(
            kind: .httpConnect,
            host: "proxy.example.com",
            port: 0
        )
        #expect(invalidPort.validationError == .invalidPort)

        let missingUsername = SSHProxyConfiguration(
            kind: .socks5,
            host: "proxy.example.com",
            port: 1080,
            authentication: .password
        )
        #expect(missingUsername.validationError == .missingUsername)
    }

    @Test("主机草稿保留代理配置")
    func hostDraftRoundTrip() {
        let proxy = SSHProxyConfiguration(
            kind: .httpConnect,
            host: "proxy.example.com",
            port: 8080
        )
        let draft = HostDraft(
            address: "10.0.0.8",
            username: "root",
            proxyConfiguration: proxy
        )

        let host = draft.toHost(existingID: "host-1")
        #expect(host.proxyConfiguration == proxy)
        #expect(HostDraft(from: host).proxyConfiguration == proxy)
    }

    @Test("私有网络和普通代理不能同时配置")
    func privateNetworkAndProxyAreMutuallyExclusive() {
        let draft = HostDraft(
            address: "100.64.0.8",
            username: "root",
            privateNetworkProfileID: "tailnet-1",
            proxyConfiguration: SSHProxyConfiguration(
                kind: .socks5,
                host: "proxy.example.com",
                port: 1080
            )
        )

        #expect(draft.validate()[.proxy] != nil)
    }
}
