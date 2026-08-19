import ConnCrypto
import ConnKit
import ConnStore
import Testing
@testable import Conn

@Suite("KeyManagerViewModel")
@MainActor
struct KeyManagerViewModelTests {
    @Test("删除使用中的密钥会清理凭据、删除密钥并解除主机引用")
    func deletingReferencedKeyCompletesEndToEnd() throws {
        let database = try AppDatabase.inMemory()
        let keyStore = SSHKeyStore(database: database)
        let hostStore = HostStore(database: database)
        let credentials = InMemoryCredentialStore()
        let key = SSHKey(
            id: "key-in-use",
            name: "部署密钥",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA conn@test",
            privateRef: "conn.key.key-in-use.private"
        )
        let host = Host(
            id: "host-using-key",
            name: "生产主机",
            address: "203.0.113.10",
            username: "root",
            authKind: .key,
            keyUUID: key.id
        )
        try keyStore.save(key)
        try hostStore.save(host)
        try credentials.setPrivateKey("private-material", forKey: key.id)
        try credentials.setKeyMetadata(key, forKey: key.id)

        let viewModel = KeyManagerViewModel(
            keyStore: keyStore,
            credentialStore: credentials,
            hostStore: hostStore
        )
        viewModel.load()

        #expect(viewModel.hostCount(using: key) == 1)
        #expect(viewModel.delete(key))
        #expect(viewModel.keys.isEmpty)
        #expect(viewModel.lastError == nil)
        #expect(try keyStore.key(id: key.id) == nil)
        #expect(try credentials.privateKey(forKey: key.id) == nil)
        #expect(try credentials.allKeyMetadata().isEmpty)

        let detachedHost = try #require(try hostStore.host(id: host.id))
        #expect(detachedHost.authKind == .key)
        #expect(detachedHost.keyUUID == nil)
        #expect(detachedHost.syncDirty)
    }
}
