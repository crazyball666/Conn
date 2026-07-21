import Testing
@testable import ConnSSH

@Suite("HostKeyStore — TOFU 指纹库")
struct HostKeyStoreTests {
    private let endpoint = SSHEndpoint(host: "10.0.0.1", port: 22)
    private let fingerprint = "SHA256:abcdef123456"

    @Test("首次见到某主机 → trustedFirstUse 并自动入库")
    func firstUseIsTrustedAndRemembered() {
        let store = InMemoryHostKeyStore()
        let verdict = store.evaluate(fingerprint, for: endpoint)
        #expect(verdict == .trustedFirstUse)
        #expect(store.knownFingerprint(for: endpoint) == fingerprint)
    }

    @Test("再次见到相同指纹 → matches")
    func sameFingerprintMatches() {
        let store = InMemoryHostKeyStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        let verdict = store.evaluate(fingerprint, for: endpoint)
        #expect(verdict == .matches)
    }

    @Test("指纹变更 → mismatch，并带出已记录的旧指纹（防降级攻击）")
    func changedFingerprintMismatches() {
        let store = InMemoryHostKeyStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        let verdict = store.evaluate("SHA256:evil999", for: endpoint)
        #expect(verdict == .mismatch(known: fingerprint))
    }

    @Test("mismatch 不覆盖已记录指纹（不能被攻击者悄悄改写）")
    func mismatchDoesNotOverwrite() {
        let store = InMemoryHostKeyStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        _ = store.evaluate("SHA256:evil999", for: endpoint)
        #expect(store.knownFingerprint(for: endpoint) == fingerprint)
    }

    @Test("不同端口视为不同主机")
    func differentPortIsDifferentHost() {
        let store = InMemoryHostKeyStore()
        _ = store.evaluate(fingerprint, for: SSHEndpoint(host: "10.0.0.1", port: 22))
        let verdict = store.evaluate("SHA256:other", for: SSHEndpoint(host: "10.0.0.1", port: 2222))
        #expect(verdict == .trustedFirstUse)
    }

    @Test("remember 可手动信任新指纹（用户在告警里确认覆盖）")
    func manualRememberOverwrites() {
        let store = InMemoryHostKeyStore()
        _ = store.evaluate(fingerprint, for: endpoint)
        store.remember("SHA256:newtrusted", for: endpoint)
        #expect(store.evaluate("SHA256:newtrusted", for: endpoint) == .matches)
    }
}
