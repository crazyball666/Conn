import Citadel
import ConnCrypto
import ConnSSH
import NIOSSH
import Testing
@testable import ConnSSHCitadel

@Suite("Citadel 主机密钥校验")
struct CitadelHostKeyVerifierTests {
    private let endpoint = SSHEndpoint(host: "example.test", port: 22)

    @Test("TOFU 首次信任并记录指纹")
    func tofuFirstUseTrustsAndRemembers() throws {
        let store = InMemoryHostKeyStore()
        let key = try publicKey(seed: 1)
        let verifier = CitadelHostKeyVerifier(endpoint: endpoint, hostKeyStore: store, policy: .tofu)

        #expect(verifier.evaluate(key) == .success(CitadelHostKeyVerifier.fingerprint(for: key)))

        #expect(store.knownFingerprint(for: endpoint) == CitadelHostKeyVerifier.fingerprint(for: key))
    }

    @Test("TOFU 已记录相同指纹时放行")
    func tofuMatchingFingerprintIsAccepted() throws {
        let store = InMemoryHostKeyStore()
        let key = try publicKey(seed: 1)
        let fingerprint = CitadelHostKeyVerifier.fingerprint(for: key)
        store.remember(fingerprint, for: endpoint)
        let verifier = CitadelHostKeyVerifier(endpoint: endpoint, hostKeyStore: store, policy: .tofu)

        #expect(verifier.evaluate(key) == .success(fingerprint))
    }

    @Test("TOFU 指纹变更时阻断并保留旧指纹")
    func tofuChangedFingerprintIsRejected() throws {
        let store = InMemoryHostKeyStore()
        let original = try publicKey(seed: 1)
        let changed = try publicKey(seed: 2)
        let originalFingerprint = CitadelHostKeyVerifier.fingerprint(for: original)
        store.remember(originalFingerprint, for: endpoint)
        let verifier = CitadelHostKeyVerifier(endpoint: endpoint, hostKeyStore: store, policy: .tofu)

        let result = verifier.evaluate(changed)
        if case let .failure(error) = result {
            #expect(error == .hostKeyMismatch(
                expected: originalFingerprint,
                actual: CitadelHostKeyVerifier.fingerprint(for: changed)
            ))
        } else {
            Issue.record("主机密钥变更应被阻断")
        }

        #expect(store.knownFingerprint(for: endpoint) == originalFingerprint)
    }

    @Test("strict 只接受预期指纹")
    func strictPolicyRequiresExpectedFingerprint() throws {
        let store = InMemoryHostKeyStore()
        let key = try publicKey(seed: 1)
        let fingerprint = CitadelHostKeyVerifier.fingerprint(for: key)
        let verifier = CitadelHostKeyVerifier(
            endpoint: endpoint,
            hostKeyStore: store,
            policy: .strict(expectedFingerprint: fingerprint)
        )

        #expect(verifier.evaluate(key) == .success(fingerprint))
        #expect(store.knownFingerprint(for: endpoint) == nil)
    }

    @Test("acceptOnce 只放行本次，不写入 TOFU 库")
    func acceptOnceDoesNotPersist() throws {
        let store = InMemoryHostKeyStore()
        let key = try publicKey(seed: 1)
        let verifier = CitadelHostKeyVerifier(endpoint: endpoint, hostKeyStore: store, policy: .acceptOnce)

        #expect(verifier.evaluate(key) == .success(CitadelHostKeyVerifier.fingerprint(for: key)))
        #expect(store.knownFingerprint(for: endpoint) == nil)
    }

    @Test("TOFU 指纹库不可用时阻断连接")
    func unavailableStoreFailsClosed() throws {
        let key = try publicKey(seed: 1)
        let verifier = CitadelHostKeyVerifier(
            endpoint: endpoint,
            hostKeyStore: UnavailableHostKeyStore(),
            policy: .tofu
        )

        #expect(verifier.evaluate(key) == .failure(.hostKeyStoreUnavailable))
    }

    private func publicKey(seed: UInt8) throws -> NIOSSHPublicKey {
        let generated = SSHKeyGenerator.generateEd25519(comment: "verifier-\(seed)")
        return try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyOpenSSH)
    }
}

private struct UnavailableHostKeyStore: HostKeyStore {
    func knownFingerprint(for endpoint: SSHEndpoint) -> String? { nil }
    func remember(_ fingerprint: String, for endpoint: SSHEndpoint) {}
    func evaluate(_ presented: String, for endpoint: SSHEndpoint) -> HostKeyVerdict { .unavailable }
}
