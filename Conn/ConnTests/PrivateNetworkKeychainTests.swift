import ConnCrypto
import Foundation
import Testing

@Suite("私有网络节点 Keychain")
struct PrivateNetworkKeychainTests {
    @Test("真实 Keychain 可保存、覆盖、隔离和删除节点身份快照")
    func persistsNodeState() throws {
        let store = KeychainCredentialStore(service: "com.crazyball.Conn.tests.node-state.\(UUID().uuidString)")
        defer { try? store.setPrivateNetworkNodeState(nil, forProfile: "fixture") }
        #expect(try store.privateNetworkNodeState(forProfile: "fixture") == nil)
        try store.setPrivateNetworkNodeState("fixture-state-1", forProfile: "fixture")
        #expect(try store.privateNetworkNodeState(forProfile: "fixture") == "fixture-state-1")
        #expect(try store.privateNetworkNodeState(forProfile: "other") == nil)
        try store.setPrivateNetworkNodeState("fixture-state-2", forProfile: "fixture")
        #expect(try store.privateNetworkNodeState(forProfile: "fixture") == "fixture-state-2")
        try store.setPrivateNetworkNodeState(nil, forProfile: "fixture")
        #expect(try store.privateNetworkNodeState(forProfile: "fixture") == nil)
    }
}
