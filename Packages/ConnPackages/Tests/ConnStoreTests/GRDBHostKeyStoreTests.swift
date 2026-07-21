import ConnSSH
import Foundation
import Testing
@testable import ConnStore

@Suite("GRDBHostKeyStore — 持久化 TOFU")
struct GRDBHostKeyStoreTests {
    private let endpoint = SSHEndpoint(host: "10.0.0.1", port: 22)
    private let fingerprint = "SHA256:abcdef"

    private func makeStore() throws -> GRDBHostKeyStore {
        try GRDBHostKeyStore(database: AppDatabase.inMemory())
    }

    @Test("首次入库 → trustedFirstUse，并可读回")
    func firstUsePersists() throws {
        let store = try makeStore()
        #expect(store.evaluate(fingerprint, for: endpoint) == .trustedFirstUse)
        #expect(store.knownFingerprint(for: endpoint) == fingerprint)
    }

    @Test("相同指纹 → matches")
    func sameMatches() throws {
        let store = try makeStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        #expect(store.evaluate(fingerprint, for: endpoint) == .matches)
    }

    @Test("变更 → mismatch，且不自动覆盖")
    func changeMismatchesWithoutOverwrite() throws {
        let store = try makeStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        #expect(store.evaluate("SHA256:evil", for: endpoint) == .mismatch(known: fingerprint))
        #expect(store.knownFingerprint(for: endpoint) == fingerprint)
    }

    @Test("remember 覆盖（用户确认信任新指纹）")
    func rememberOverwrites() throws {
        let store = try makeStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        store.remember("SHA256:newtrust", for: endpoint)
        #expect(store.knownFingerprint(for: endpoint) == "SHA256:newtrust")
    }

    @Test("指纹跨 store 实例留存（同一数据库）")
    func persistsAcrossInstances() throws {
        let database = try AppDatabase.inMemory()
        GRDBHostKeyStore(database: database).remember(fingerprint, for: endpoint)
        let reopened = GRDBHostKeyStore(database: database)
        #expect(reopened.knownFingerprint(for: endpoint) == fingerprint)
    }
}
