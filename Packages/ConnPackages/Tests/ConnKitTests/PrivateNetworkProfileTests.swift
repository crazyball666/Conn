import Testing
@testable import ConnKit

@Suite("私有网络配置")
struct PrivateNetworkProfileTests {
    @Test("Tailscale 和 Headscale 使用统一配置模型")
    func providersHaveStableIdentity() {
        let tailscale = PrivateNetworkProfile(
            id: "tailnet",
            name: "公司 Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let headscale = PrivateNetworkProfile(
            id: "headscale",
            name: "自建 Tailnet",
            provider: .headscale,
            controlURL: "https://hs.example.com"
        )

        #expect(tailscale.provider == .tailscale)
        #expect(headscale.provider == .headscale)
        #expect(tailscale.controlURL == "https://controlplane.tailscale.com")
        #expect(headscale.controlURL == "https://hs.example.com")
        #expect(tailscale.authKeyRef == "conn.private-network.tailnet.auth-key")
    }

    @Test("配置拒绝非 HTTPS 控制端点")
    func validatesControlURL() {
        let profile = PrivateNetworkProfile(
            name: "bad",
            provider: .headscale,
            controlURL: "http://headscale.local"
        )
        #expect(profile.validationError == .insecureControlURL)
    }
}
