import Foundation
import Testing
@testable import ConnPrivateNetwork

@Suite("私有网络节点健康")
struct PrivateNetworkNodeHealthTests {
    @Test("Running 且有 Tailscale 地址才可复用")
    func runningWithAddressesIsUsable() {
        let json = #"{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}"#
        #expect(PrivateNetworkNodeHealth.isUsable(statusJSON: Data(json.utf8)))
    }

    @Test("Stopped 不可复用")
    func stoppedIsUnhealthy() {
        let json = #"{"BackendState":"Stopped","TailscaleIPs":["100.64.0.1"]}"#
        #expect(!PrivateNetworkNodeHealth.isUsable(statusJSON: Data(json.utf8)))
    }

    @Test("Running 但没有地址不可复用")
    func runningWithoutAddressesIsUnhealthy() {
        let json = #"{"BackendState":"Running","TailscaleIPs":[]}"#
        #expect(!PrivateNetworkNodeHealth.isUsable(statusJSON: Data(json.utf8)))
    }

    @Test("非法 JSON 不可复用")
    func invalidJSONIsUnhealthy() {
        #expect(!PrivateNetworkNodeHealth.isUsable(statusJSON: Data("not-json".utf8)))
    }
}
