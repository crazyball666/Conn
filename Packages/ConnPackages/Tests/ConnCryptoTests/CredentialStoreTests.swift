import Foundation
import Testing
@testable import ConnCrypto

/// 凭据存储的契约测试。
///
/// 针对 `InMemoryCredentialStore` 验证语义——Keychain 实现在 host 端跑会因
/// entitlements/弹窗不稳定，其正确性由 Phase 3b 的真机冒烟覆盖。两者共享同一
/// 协议契约，此处锁定的行为对二者都成立。
@Suite("CredentialStore 契约")
struct CredentialStoreTests {
    private let hostID = "host-uuid-1"

    @Test("存密码后可读回")
    func storesAndReadsPassword() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("s3cr3t", forHost: hostID)
        #expect(try store.password(forHost: hostID) == "s3cr3t")
    }

    @Test("未存过的主机返回 nil")
    func unknownHostReturnsNil() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.password(forHost: "nope") == nil)
    }

    @Test("传 nil 删除密码")
    func nilDeletesPassword() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("x", forHost: hostID)
        try store.setPassword(nil, forHost: hostID)
        #expect(try store.password(forHost: hostID) == nil)
    }

    @Test("密码与 passphrase 互不干扰")
    func passwordAndPassphraseSeparate() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("pw", forHost: hostID)
        try store.setPassphrase("pp", forHost: hostID)
        #expect(try store.password(forHost: hostID) == "pw")
        #expect(try store.passphrase(forHost: hostID) == "pp")
    }

    @Test("deleteAll 清除该主机全部凭据")
    func deleteAllClearsBoth() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("pw", forHost: hostID)
        try store.setPassphrase("pp", forHost: hostID)
        try store.deleteAll(forHost: hostID)
        #expect(try store.password(forHost: hostID) == nil)
        #expect(try store.passphrase(forHost: hostID) == nil)
    }

    @Test("覆盖写入替换旧值")
    func overwriteReplaces() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("old", forHost: hostID)
        try store.setPassword("new", forHost: hostID)
        #expect(try store.password(forHost: hostID) == "new")
    }
}
