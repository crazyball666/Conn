import Testing
@testable import ConnCrypto

@Suite("私有网络凭据")
struct PrivateNetworkCredentialStoreTests {
    @Test("auth key 只通过凭据存储读写")
    func storesAndDeletesAuthKey() throws {
        let store = InMemoryCredentialStore()
        try store.setPrivateNetworkAuthKey("tskey-auth-example", forProfile: "profile-1")
        #expect(try store.privateNetworkAuthKey(forProfile: "profile-1") == "tskey-auth-example")
        try store.deletePrivateNetworkAuthKey(forProfile: "profile-1")
        #expect(try store.privateNetworkAuthKey(forProfile: "profile-1") == nil)
    }

    @Test("代理密码只通过凭据存储读写")
    func storesAndDeletesProxyPassword() throws {
        let store = InMemoryCredentialStore()
        try store.setProxyPassword("proxy-secret", forHost: "host-1")
        #expect(try store.proxyPassword(forHost: "host-1") == "proxy-secret")
        try store.deleteProxyPassword(forHost: "host-1")
        #expect(try store.proxyPassword(forHost: "host-1") == nil)
    }
}
