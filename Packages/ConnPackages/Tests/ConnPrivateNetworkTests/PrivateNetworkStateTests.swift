import ConnCrypto
import ConnKit
import Foundation
import Testing
@testable import ConnPrivateNetwork

@Suite("私有网络节点身份")
struct PrivateNetworkStateTests {
    @Test("损坏的 Keychain 快照报错而不是丢弃身份重新注册")
    func rejectsCorruptSnapshot() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkNodeState("invalid-snapshot", forProfile: "p")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = PrivateNetworkProfile(id: "p", name: "Test", provider: .tailscale)
        let state = PrivateNetworkNodeState(profile: profile, credentialStore: credentials, root: root)
        #expect(throws: DecodingError.self) { try state.prepare() }
        #expect(try credentials.privateNetworkNodeState(forProfile: "p") == "invalid-snapshot")
    }

    @Test("关闭后清理临时文件，重建客户端仍恢复同一身份")
    func restoresIdentityAcrossRuntimeRecreation() throws {
        let credentials = InMemoryCredentialStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = PrivateNetworkProfile(id: "p", name: "Test", provider: .headscale, controlURL: "https://headscale.example")
        let first = PrivateNetworkNodeState(profile: profile, credentialStore: credentials, root: root)
        try first.prepare()
        let identity = Data(#"{"_machinekey":"test-machine-identity","_current-profile":"test-profile"}"#.utf8)
        try identity.write(to: first.directory.appendingPathComponent("tailscaled.state"))
        try first.checkpoint()
        try first.removeWorkingDirectory()
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))

        let next = PrivateNetworkNodeState(profile: profile, credentialStore: credentials, root: root)
        try next.prepare()
        #expect(try Data(contentsOf: next.directory.appendingPathComponent("tailscaled.state")) == identity)
    }

    @Test("更换控制面不会带入另一个网络的节点身份")
    func isolatesControlServers() throws {
        let credentials = InMemoryCredentialStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = PrivateNetworkProfile(id: "p", name: "Test", provider: .headscale, controlURL: "https://one.example")
        let first = PrivateNetworkNodeState(profile: profile, credentialStore: credentials, root: root)
        try first.prepare()
        try Data("first-identity".utf8).write(to: first.directory.appendingPathComponent("tailscaled.state"))
        try first.checkpoint()
        profile.controlURL = "https://two.example"
        let second = PrivateNetworkNodeState(profile: profile, credentialStore: credentials, root: root)
        try second.prepare()
        #expect(first.directory != second.directory)
        #expect(!FileManager.default.fileExists(atPath: second.directory.appendingPathComponent("tailscaled.state").path))
    }

    @Test("中断后保留较新的工作状态，不被旧快照覆盖")
    func preservesStateAfterInterruptedProcess() throws {
        let credentials = InMemoryCredentialStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = PrivateNetworkProfile(id: "p", name: "Test", provider: .tailscale)
        let state = PrivateNetworkNodeState(profile: profile, credentialStore: credentials, root: root)
        try state.prepare()
        let file = state.directory.appendingPathComponent("tailscaled.state")
        try Data("old".utf8).write(to: file)
        try state.checkpoint()
        try Data("new".utf8).write(to: file)
        try state.prepare()
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }
}
